// iCube PGO flush shim.
//
// Profile-Guided Optimization helpers for the jitless interpreter. The actual
// __llvm_profile_* runtime lives inside the PVlibDolphin dylib and is only present
// when that dylib was built with DOL_PGO=generate (see BuildiOSXCFramework.py). The
// declarations below are weak, so the app links and runs normally with a non-
// instrumented (shipping) core — the calls become no-ops in that case.
//
// Usage (app target):
//   * At launch, before booting a game: ICubePGOSetPath("<Documents>/Software/pgo/icube-%m.profraw")
//     so the profile lands in the folder the in-app web server already serves for download.
//   * On applicationDidEnterBackground / willTerminate, and from a Settings "Dump PGO
//     profile" action: call ICubePGOFlush(). Background is the reliable kill-safe flush
//     point — a long-running emulator force-killed by iOS never runs atexit().

#ifdef __cplusplus
extern "C" {
#endif

// Point the instrumented runtime at a writable path (use a %m pattern for cross-run merge).
// No-op when the core is not instrumented.
void ICubePGOSetPath(const char* path);

// Flush accumulated counters to disk. Returns 0 on success, negative when the core is not
// instrumented (i.e. a normal shipping build) or the write failed.
int ICubePGOFlush(void);

// True when the linked core was built with PGO instrumentation (the runtime symbols resolved).
int ICubePGOAvailable(void);

#ifdef __cplusplus
}
#endif
