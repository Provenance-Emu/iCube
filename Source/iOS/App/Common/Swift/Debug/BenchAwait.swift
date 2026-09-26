// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Bridges a completion-callback API into `async` with a deadline, resuming exactly once.
///
/// Returns the callback's value, or `nil` if `seconds` elapse first. A late callback after the
/// timeout is ignored (never a double resume). Pure Swift concurrency, unit-tested without a
/// device; the bench uses it to await host-queue work from the main actor without blocking the
/// main thread.
enum BenchAwait {
  static func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ start: @escaping @Sendable (_ finish: @escaping @Sendable (T) -> Void) -> Void
  ) async -> T? {
    let gate = ResumeOnce<T>()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      gate.arm(continuation)
      start { value in gate.resume(with: value) }
      Task {
        try? await Task.sleep(for: .seconds(seconds))
        gate.resume(with: nil)
      }
    }
  }

  /// Thread-safe single-shot continuation holder.
  final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func arm(_ c: CheckedContinuation<T?, Never>) {
      lock.lock(); continuation = c; lock.unlock()
    }

    func resume(with value: T?) {
      lock.lock()
      let c = continuation
      continuation = nil
      lock.unlock()
      c?.resume(returning: value)
    }
  }
}
