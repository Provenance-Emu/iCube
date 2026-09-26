// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit

/// Mirrors `TCView`'s `willMove(toSuperview:)`/`deinit` clear-on-teardown pattern (that file's
/// "Defect #7" comment) for the programmatic overlay's hosting view (task item 2, DSU pass):
/// per-group SwiftUI teardown (`TouchOverlayCluster.releaseAll()` on `onDisappear`,
/// `TouchOverlayIRPadView.dismantleUIView`/`deinit`) already covers the overlay's OWN internal
/// transitions, but `TouchPadsContainer.syncProgrammaticOverlay` also removes the WHOLE hosting
/// view directly (`removeFromSuperview()` + dropping the coordinator's last strong reference) the
/// instant the overlay stops being the right pad to show at all (an external controller connects,
/// the flag flips off, the pad kind changes) — a path SwiftUI's own view-graph diffing isn't
/// guaranteed to observe, exactly the gap `TCView`'s own comment describes for the legacy pads.
///
/// Wrapping the `UIHostingController`'s view in one of these and clearing `deviceId`'s controller
/// state whenever THIS container leaves the hierarchy (or deallocates outright, e.g. the whole
/// screen being dismissed while a button was held) makes the release unconditional, the same
/// guarantee `TCView` gives the legacy path.
final class TouchOverlayHostContainer: UIView {
  /// The Touchscreen device id (§6.3) last synced into this container — set by
  /// `TouchPadsContainer.syncProgrammaticOverlay` on every mount/update, so a teardown triggered
  /// by that same container doesn't need to recompute it (the overlay may be disappearing EXACTLY
  /// because `ControllerManager`'s state changed underneath it).
  var deviceId: Int?

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview == nil { clearControllerState() }
  }

  deinit {
    clearControllerState()
  }

  private func clearControllerState() {
    guard let deviceId else { return }
    TCManagerInterface.clearAll(forController: deviceId)
  }
}
#endif
