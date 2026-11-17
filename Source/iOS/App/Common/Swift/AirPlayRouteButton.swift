// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import AVKit
import SwiftUI

/// The system AirPlay route picker as a round pause-menu header button, drawn like the Close button beside it.
///
/// `AVRoutePickerView` owns the presentation (a popover or menu of nearby AirPlay devices), so it cannot be a
/// `MenuModel` tile action; the pause menu places it in the header. iPhone and iPad only: tvOS has no route
/// picker, and its own output is the television.
struct AirPlayRouteButton: View {
  /// The Close button's diameter, so the two sit as a pair.
  static let diameter: CGFloat = 36

  var body: some View {
    RoutePicker()
      .frame(width: Self.diameter, height: Self.diameter)
      .background(Circle().fill(ICubeDesign.Card.surface.opacity(ICubeDesign.Card.restFillOpacity)))
      .overlay(Circle().strokeBorder(ICubeDesign.color(.accent).opacity(ICubeDesign.Card.restBorderOpacity),
                                     lineWidth: ICubeDesign.Line.hairline.rawValue))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(L("AirPlay"))
      .accessibilityAddTraits(.isButton)
  }

  private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
      let picker = AVRoutePickerView()
      picker.backgroundColor = .clear
      picker.tintColor = ICubeDesign.uiColor(.textPrimary)
      // Highlighted while a route other than the device speaker is in use.
      picker.activeTintColor = ICubeDesign.uiColor(.accent)
      // Apple TVs and other video-capable receivers first, speakers after.
      picker.prioritizesVideoDevices = true
      return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
  }
}
#endif
