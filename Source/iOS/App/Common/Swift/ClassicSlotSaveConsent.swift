// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct QuickSaveSurfaceSession: Equatable, Sendable {
  let gameID: String
  let identifier: UInt64
}

struct QuickSaveSlotSaveRequest: Equatable, Sendable {
  let session: QuickSaveSurfaceSession
  let slot: Int
  let path: URL
}

/// A UI replacement decision, preserved through queueing and checked again under the core guard.
struct ClassicSlotSaveConsent: Equatable, Sendable {
  let request: QuickSaveSlotSaveRequest
  let allowsOverwrite: Bool
}

enum QuickSaveDestinationOccupancy: Equatable, Sendable {
  case empty, occupied, unknown

  static func read(_ url: URL) -> Self {
    do {
      _ = try FileManager.default.attributesOfItem(atPath: url.path)
      return .occupied
    } catch {
      let error = error as NSError
      if error.domain == NSCocoaErrorDomain &&
          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return .empty }
      return .unknown
    }
  }
}

/// Shares SaveStateService's existing queue with every other save. Admission runs when this request
/// reaches the writer, after any pending save has committed its payload and metadata.
final class ClassicSlotSaveExecutor: @unchecked Sendable {
  private let queue: DispatchQueue
  init(queue: DispatchQueue) { self.queue = queue }

  func enqueue<Result: Sendable>(_ consent: ClassicSlotSaveConsent,
    currentSession: @escaping @Sendable () -> QuickSaveSurfaceSession,
    destination: @escaping @Sendable (Int) -> URL?,
    occupancy: @escaping @Sendable (URL) -> QuickSaveDestinationOccupancy = { QuickSaveDestinationOccupancy.read($0) },
    write: @escaping @Sendable (ClassicSlotSaveConsent) -> Result?,
    completion: @escaping @Sendable (Result?) -> Void) {
    queue.async {
      let request = consent.request
      guard request.slot > 0, !request.session.gameID.isEmpty, request.path.isFileURL,
            currentSession() == request.session, destination(request.slot) == request.path else {
        completion(nil); return
      }
      let status = occupancy(request.path)
      guard status != .unknown, consent.allowsOverwrite || status == .empty else {
        completion(nil); return
      }
      completion(write(consent))
    }
  }
}
