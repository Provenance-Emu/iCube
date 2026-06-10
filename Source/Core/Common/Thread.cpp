// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/Thread.h"

#ifdef _WIN32
#include <Windows.h>
#include <processthreadsapi.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#ifdef __APPLE__
#include <mach/mach.h>
#include <cstring>
#include <pthread/qos.h>
#elif defined BSD4_4 || defined __FreeBSD__ || defined __OpenBSD__
#include <pthread_np.h>
#elif defined __NetBSD__
#include <sched.h>
#elif defined __HAIKU__
#include <OS.h>
#endif

#ifdef USE_VTUNE
#include <ittnotify.h>
#pragma comment(lib, "libittnotify.lib")
#endif

#include "Common/CommonFuncs.h"
#include "Common/CommonTypes.h"
#include "Common/StallSignpost.h"
#include "Common/StringUtil.h"

namespace Common
{
int CurrentThreadId()
{
#ifdef _WIN32
  return GetCurrentThreadId();
#elif defined __APPLE__
  return mach_thread_self();
#else
  return 0;
#endif
}

#ifdef _WIN32

void SetThreadAffinity(std::thread::native_handle_type thread, u32 mask)
{
  SetThreadAffinityMask(thread, mask);
}

void SetCurrentThreadAffinity(u32 mask)
{
  SetThreadAffinityMask(GetCurrentThread(), mask);
}

// Supporting functions
void SleepCurrentThread(int ms)
{
  // Signpost only: Thread.cpp lives in Common and must not depend on VideoCommon/StallMetrics, and
  // every caller here is a peripheral/IO thread (Wiimote/EXI/SI/USB/GCAdapter/Hotkey) — not the CPU
  // thread — so a CPU-thread-blocked accumulator would be near-worthless. The interval still shows
  // up in Instruments for cross-thread correlation.
  ICUBE_STALL_INTERVAL("thread.sleep");
  Sleep(ms);
}

// Sets the debugger-visible name of the current thread.
// Uses trick documented in:
// https://docs.microsoft.com/en-us/visualstudio/debugger/how-to-set-a-thread-name-in-native-code
static void SetCurrentThreadNameViaException(const char* name)
{
  static const DWORD MS_VC_EXCEPTION = 0x406D1388;

#pragma pack(push, 8)
  struct THREADNAME_INFO
  {
    DWORD dwType;      // must be 0x1000
    LPCSTR szName;     // pointer to name (in user addr space)
    DWORD dwThreadID;  // thread ID (-1=caller thread)
    DWORD dwFlags;     // reserved for future use, must be zero
  } info;
#pragma pack(pop)

  info.dwType = 0x1000;
  info.szName = name;
  info.dwThreadID = static_cast<DWORD>(-1);
  info.dwFlags = 0;

  __try
  {
    RaiseException(MS_VC_EXCEPTION, 0, sizeof(info) / sizeof(ULONG_PTR), (ULONG_PTR*)&info);
  }
  __except (EXCEPTION_CONTINUE_EXECUTION)
  {
  }
}

static void SetCurrentThreadNameViaApi(const char* name)
{
  // If possible, also set via the newer API. On some versions of Server it needs to be manually
  // resolved. This API allows being able to observe the thread name even if a debugger wasn't
  // attached when the name was set (see above link for more info).
  static auto pSetThreadDescription = (decltype(&SetThreadDescription))GetProcAddress(
      GetModuleHandleA("kernel32"), "SetThreadDescription");
  if (pSetThreadDescription)
  {
    pSetThreadDescription(GetCurrentThread(), UTF8ToWString(name).c_str());
  }
}

void SetCurrentThreadName(const char* name)
{
  SetCurrentThreadNameViaException(name);
  SetCurrentThreadNameViaApi(name);
}

#else  // !WIN32, so must be POSIX threads

void SetThreadAffinity(std::thread::native_handle_type thread, u32 mask)
{
#ifdef __APPLE__
  thread_policy_set(pthread_mach_thread_np(thread), THREAD_AFFINITY_POLICY, (integer_t*)&mask, 1);
#elif (defined __linux__ || defined BSD4_4 || defined __FreeBSD__ || defined __NetBSD__) &&        \
    !(defined ANDROID)
#ifndef __NetBSD__
#ifdef __FreeBSD__
  cpuset_t cpu_set;
#else
  cpu_set_t cpu_set;
#endif
  CPU_ZERO(&cpu_set);

  for (int i = 0; i != sizeof(mask) * 8; ++i)
    if ((mask >> i) & 1)
      CPU_SET(i, &cpu_set);

  pthread_setaffinity_np(thread, sizeof(cpu_set), &cpu_set);
#else
  cpuset_t* cpu_set = cpuset_create();

  for (int i = 0; i != sizeof(mask) * 8; ++i)
    if ((mask >> i) & 1)
      cpuset_set(i, cpu_set);

  pthread_setaffinity_np(thread, cpuset_size(cpu_set), cpu_set);
  cpuset_destroy(cpu_set);
#endif
#endif
}

void SetCurrentThreadAffinity(u32 mask)
{
  SetThreadAffinity(pthread_self(), mask);
}

void SleepCurrentThread(int ms)
{
  // Signpost only — see the Win32 SleepCurrentThread above for why this is not a StallMetrics site.
  ICUBE_STALL_INTERVAL("thread.sleep");
  usleep(1000 * ms);
}

#ifdef __APPLE__
// iCube: tag emulation threads with a QoS class so Apple Silicon biases the hot
// threads onto P-cores — QoS is the only P/E-core steering knob on AS, and the
// std::thread CPU/GPU/DSP threads otherwise run at QOS_CLASS_DEFAULT (can be
// parked on E-cores). Recovered from the pre-2509 fork; hints only, so a name
// mismatch is a harmless no-op. Lives in the core, so iCube + Provenance share it.
static void SetCurrentThreadQoS_Apple(const char* name)
{
  if (!name)
    return;
  qos_class_t qos = QOS_CLASS_DEFAULT;
  // AsyncShaderCompiler rides USER_INTERACTIVE with the CPU thread: the hot thread gates on its
  // output (pipeline-cache misses / ubershader replacement), so one tier down = E-core eligible =
  // priority inversion on the thread the emulated core is waiting for (2026-06-06 QoS audit).
  //
  // iCube B1: the dual-core "Video thread" (the GPU/FIFO worker) must also ride USER_INTERACTIVE.
  // On the dual-core path the CPU thread (USER_INTERACTIVE) blocks in FifoManager::FlushGpu()
  // waiting on this GPU thread to drain the FIFO. If the GPU thread sits one tier lower
  // (USER_INITIATED) it is E-core eligible, so the interactive CPU thread waits on a
  // lower-priority worker — a QoS priority inversion that stretches the flush wait. Promote
  // Video/GPU/FIFO-GPU to match the waiter's tier. Note: the single-core "CPU-GPU thread" still
  // matches "CPU" first (short-circuit) and stays USER_INTERACTIVE exactly as before — unchanged.
  if (std::strstr(name, "CPU") || std::strstr(name, "AsyncShaderCompiler") ||
      std::strstr(name, "Video") || std::strstr(name, "GPU") || std::strstr(name, "FIFO-GPU"))
    qos = QOS_CLASS_USER_INTERACTIVE;
  else if (std::strstr(name, "DSP") || std::strstr(name, "Audio"))
    qos = QOS_CLASS_USER_INITIATED;
  else if (std::strstr(name, "DVD") || std::strstr(name, "Memcard") || std::strstr(name, "Asset") ||
           std::strstr(name, "Analytics") || std::strstr(name, "FrameDumping") ||
           std::strstr(name, "USB") || std::strstr(name, "Wiimote"))
    qos = QOS_CLASS_UTILITY;
  pthread_set_qos_class_self_np(qos, 0);
}
#endif

void SetCurrentThreadName(const char* name)
{
#ifdef __APPLE__
  pthread_setname_np(name);
  SetCurrentThreadQoS_Apple(name);
#elif defined __FreeBSD__ || defined __OpenBSD__
  pthread_set_name_np(pthread_self(), name);
#elif defined(__NetBSD__)
  pthread_setname_np(pthread_self(), "%s", const_cast<char*>(name));
#elif defined __HAIKU__
  rename_thread(find_thread(nullptr), name);
#else
  // linux doesn't allow to set more than 16 bytes, including \0.
  pthread_setname_np(pthread_self(), std::string(name).substr(0, 15).c_str());
#endif
#ifdef USE_VTUNE
  // VTune uses OS thread names by default but probably supports longer names when set via its own
  // API.
  __itt_thread_set_name(name);
#endif
}

std::tuple<void*, size_t> GetCurrentThreadStack()
{
  void* stack_addr;
  size_t stack_size;

  pthread_t self = pthread_self();

#ifdef __APPLE__
  stack_size = pthread_get_stacksize_np(self);
  stack_addr = reinterpret_cast<u8*>(pthread_get_stackaddr_np(self)) - stack_size;
#elif defined __OpenBSD__
  stack_t stack;
  pthread_stackseg_np(self, &stack);

  stack_addr = reinterpret_cast<u8*>(stack.ss_sp) - stack.ss_size;
  stack_size = stack.ss_size;
#else
  pthread_attr_t attr;

#ifdef __FreeBSD__
  pthread_attr_init(&attr);
  pthread_attr_get_np(self, &attr);
#else
  // Linux and NetBSD
  pthread_getattr_np(self, &attr);
#endif

  pthread_attr_getstack(&attr, &stack_addr, &stack_size);

  pthread_attr_destroy(&attr);
#endif

  return std::make_tuple(stack_addr, stack_size);
}

#endif

}  // namespace Common
