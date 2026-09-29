// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin

/// Keeps stdout/stderr writes from blocking the app (ICUBE-AC).
///
/// Launched from the home screen, both point at /dev/null. Launched by a debugger — which is how
/// sideload JIT is enabled — they are a pipe or pty the debugger reads. JIT enablers detach once
/// JIT is on, nobody drains the pipe after that, and when its buffer fills every NSLog/printf
/// blocks; on the main thread that is a watchdog kill (a sideload iPad hung in `writev` from
/// NSLog). Non-blocking descriptors turn a full pipe into dropped log lines instead. Under Xcode
/// the console keeps reading, so nothing changes there; /dev/null never blocks either way.
enum DebuggerStdio {
  static func makeStdioNonBlocking() {
    makeNonBlocking(STDOUT_FILENO)
    makeNonBlocking(STDERR_FILENO)
  }

  static func makeNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return }
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }
}
