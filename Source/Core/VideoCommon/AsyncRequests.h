// Copyright 2015 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <condition_variable>
#include <functional>
#include <future>
#include <mutex>
#include <queue>

#include "Common/Flag.h"
#include "Common/Functional.h"

#include "VideoCommon/StallMetrics.h"

struct EfbPokeData;
class PointerWrap;

class AsyncRequests
{
public:
  AsyncRequests();

  void PullEvents()
  {
    if (!m_empty.IsSet())
      PullEventsInternal();
  }
  void WaitForEmptyQueue();
  void SetEnable(bool enable);
  void SetPassthrough(bool enable);

  template <typename F>
  void PushEvent(F&& callback)
  {
    std::unique_lock<std::mutex> lock(m_mutex);

    if (m_passthrough)
    {
      std::invoke(callback);
      return;
    }

    QueueEvent(Event{std::forward<F>(callback)});
  }

  template <typename F>
  auto PushBlockingEvent(F&& callback) -> std::invoke_result_t<F>
  {
    std::unique_lock<std::mutex> lock(m_mutex);

    if (m_passthrough)
      return std::invoke(callback);

    std::packaged_task task{std::forward<F>(callback)};
    QueueEvent(Event{[&] { task(); }});

    lock.unlock();
    // The dual-core EFB-peek / bbox / perfquery path: the CPU thread blocks here until the GPU
    // thread runs the queued event. The single most important new stall site — this is where
    // synchronous readback serializes the two threads.
    ICUBE_SCOPED_STALL(StallMetrics::Site::BlockingEvent, "video.blocking.event");
    return task.get_future().get();
  }

  static AsyncRequests* GetInstance() { return &s_singleton; }

private:
  using Event = Common::MoveOnlyFunction<void()>;

  void QueueEvent(Event&& event);

  void PullEventsInternal();

  static AsyncRequests s_singleton;

  Common::Flag m_empty;
  std::queue<Event> m_queue;
  std::mutex m_mutex;
  std::condition_variable m_cond;

  bool m_enable = false;
  bool m_passthrough = true;
};
