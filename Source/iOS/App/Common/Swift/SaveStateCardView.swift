import SwiftUI
import UIKit
import PVHelp

/// A single save-state thumbnail card. Renders identically wherever it is
/// shown (the pause-menu grid in `SaveStateFilmstripView`, the cross-game
/// browser in `SaveStatesBrowserView`) but sizes and styles itself per
/// platform: tvOS gets a larger preview and the system "card" lift-on-focus
/// treatment, iOS stays compact for a scrolling grid.
///
/// tvOS focus note (see `icube-tvos-swiftui-focus`): this view must expose
/// AT MOST one focusable control, because a `List`/grid "row" that contains
/// more than one focusable element collapses to a single focus target and
/// strands the others. The only nested control this view used to add -- a
/// tappable "Incompatible" badge that pushed a help sheet -- is iOS-only for
/// that reason; on tvOS it renders as inert text and the compatibility
/// explanation is reachable from the card's own action menu instead (see
/// `SaveStateFilmstripView`'s confirmation dialog).
struct SaveStateCardView: View {
  let state: SaveStateInfo
  let thumbnail: UIImage?
  /// Explains why a save state is version-incompatible and can't be safely loaded, instead of
  /// leaving the red "Incompatible" badge as an unexplained dead end. iOS only; see the tvOS
  /// focus note above for why tvOS can't have a second tappable control inside this card.
  @State private var showIncompatibleHelp = false

  #if os(tvOS)
  private static let thumbnailSize = CGSize(width: 480, height: 270)
  private static let cornerRadius = ICubeDesign.Radius.large.rawValue
  #else
  private static let thumbnailSize = CGSize(width: 300, height: 170)
  private static let cornerRadius: CGFloat = 12
  #endif

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Thumbnail or placeholder. `.fit` (not `.fill`) keeps the saved frame's
      // real aspect ratio intact -- GameCube (4:3) and Wii (16:9) thumbnails
      // mixed in the same grid no longer get corner-cropped; the background
      // fill behind it letterboxes evenly so every card stays the same size
      // regardless of the thumbnail's native aspect ratio.
      Group {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFit()
        } else {
          RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(placeholderFill)
            .overlay(
              Image(systemName: "photo")
                .font(placeholderGlyphFont)
                .foregroundColor(placeholderGlyphColor)
            )
        }
      }
      .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
      .clipped()
      .overlay(
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .strokeBorder(borderColor, lineWidth: borderWidth)
      )
      .background(
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .fill(surfaceFill)
      )
      .cornerRadius(Self.cornerRadius)

      // Vignette + metadata
      LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.75)],
        startPoint: .center, endPoint: .bottom
      )
      .cornerRadius(Self.cornerRadius)

      VStack(alignment: .leading, spacing: 4) {
        titleText


        HStack(spacing: 8) {
          if state.isAuto {
            Badge(text: L("Continue"), color: .green)
          }
          #if !os(tvOS)
          if !state.isAuto, let slot = state.slot {
            Badge(text: String(format: L("Slot %d"), slot))
          }
          #endif
          if !state.isCompatible {
            #if os(tvOS)
            // No nested Button on tvOS -- see the type-level focus note. The
            // card's own action menu (SaveStateFilmstripView) surfaces the
            // same compatibility explanation.
            Badge(text: L("Incompatible"), color: .red)
            #else
            Button {
              showIncompatibleHelp = true
            } label: {
              Badge(text: L("Incompatible"), color: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Incompatible save state. Tap for details."))
            #endif
          }
        }

        HStack(spacing: 8) {
          detailText(timestampString)
          if let gameTimeString {
            Text("\u{00B7}")
              .foregroundColor(separatorColor)
            detailLabel(gameTimeString)
          }
        }
      }
      .padding(12)
    }
    #if os(tvOS)
    // The slot number sits top-right of the thumbnail as a tag capsule.
    .overlay(alignment: .topTrailing) {
      if !state.isAuto, let slot = state.slot {
        Text(String(format: L("Slot %d"), slot))
          .icubeText(.tag)
          .foregroundColor(ICubeDesign.color(.textPrimary))
          .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue)
          .padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
          .background(Capsule().fill(ICubeDesign.color(.rowSurface)))
          .padding(ICubeDesign.Spacing.s.rawValue)
      }
    }
    #endif
    #if !os(tvOS)
    .sheet(isPresented: $showIncompatibleHelp) {
      NavigationStack {
        WikiPageView(path: WikiConstants.Paths.saveStateCompatibility, title: L("Save State Compatibility"))
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(L("Close")) { showIncompatibleHelp = false }
            }
          }
      }
    }
    #endif
  }

  // MARK: Platform styling (tvOS reads tokens; iOS keeps its existing look)

  private var titleText: some View {
    #if os(tvOS)
    Text(state.displayName)
      .icubeText(.body)
      .fontWeight(.semibold)
      .foregroundColor(ICubeDesign.color(.textPrimary))
      .lineLimit(1)
    #else
    Text(state.displayName)
      .font(.headline)
      .foregroundColor(.white)
      .lineLimit(1)
    #endif
  }

  private func detailText(_ string: String) -> some View {
    #if os(tvOS)
    Text(string)
      .icubeText(.detail)
      .foregroundColor(ICubeDesign.color(.textSecondary))
    #else
    Text(string)
      .font(.subheadline)
      .foregroundColor(.white.opacity(0.85))
    #endif
  }

  private func detailLabel(_ string: String) -> some View {
    #if os(tvOS)
    Label(string, systemImage: "clock")
      .icubeText(.detail)
      .foregroundColor(ICubeDesign.color(.textSecondary))
      .labelStyle(.titleAndIcon)
    #else
    Label(string, systemImage: "clock")
      .font(.subheadline)
      .foregroundColor(.white.opacity(0.85))
      .labelStyle(.titleAndIcon)
    #endif
  }

  private var placeholderFill: Color {
    #if os(tvOS)
    ICubeDesign.color(.rowSurface)
    #else
    Color.gray.opacity(0.25)
    #endif
  }

  private var placeholderGlyphFont: Font {
    #if os(tvOS)
    ICubeDesign.symbolFont(.tile)
    #else
    .system(size: 28, weight: .regular)
    #endif
  }

  private var placeholderGlyphColor: Color {
    #if os(tvOS)
    ICubeDesign.color(.textSecondary)
    #else
    .white.opacity(0.7)
    #endif
  }

  private var borderColor: Color {
    #if os(tvOS)
    ICubeDesign.color(.hairline)
    #else
    Color.white.opacity(0.08)
    #endif
  }

  private var borderWidth: CGFloat {
    #if os(tvOS)
    ICubeDesign.Line.hairline.rawValue
    #else
    1
    #endif
  }

  private var surfaceFill: Color {
    #if os(tvOS)
    ICubeDesign.color(.rowSurface)
    #else
    Color.white.opacity(0.04)
    #endif
  }

  private var separatorColor: Color {
    #if os(tvOS)
    ICubeDesign.color(.textTertiary)
    #else
    .white.opacity(0.5)
    #endif
  }

  private var timestampString: String {
    let date = state.modifiedAt ?? state.createdAt
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  /// e.g. "01:24:07" or "12:03" for a state with recorded in-game play time.
  /// Nil (and hidden) for legacy saves with no sidecar, or one written before
  /// this field existed.
  private var gameTimeString: String? {
    SaveStateFormatting.gameTimeString(seconds: state.playTimeSeconds)
  }
}

/// Pure, testable formatting helpers shared by the save-state UI. Split out of
/// `SaveStateCardView` (a `View`, whose private computed properties are not
/// reachable from `@testable import` unit tests) so the slot-card duration
/// formatting has direct test coverage -- see `SaveStateFormattingTests`.
enum SaveStateFormatting {
  /// e.g. "01:24:07" for >= 1 hour, "12:03" under an hour. `DateComponentsFormatter`'s
  /// `.positional` style with `.pad` zero-pads every component, including the
  /// leading one (verified empirically, not just from docs) -- so this is
  /// "01:24:07", not "1:24:07". Nil for a missing, negative, or non-finite
  /// value (legacy saves have no recorded play time).
  static func gameTimeString(seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    formatter.unitsStyle = .positional
    return formatter.string(from: seconds)
  }
}

private struct Badge: View {
  let text: String
  var color: Color = .blue
  var body: some View {
    Text(text)
      .badgeFont()
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.75), in: Capsule())
      .foregroundColor(.white)
  }
}

private extension View {
  /// tvOS badges (Continue, Incompatible) use the tag role; iOS keeps caption2 semibold.
  @ViewBuilder func badgeFont() -> some View {
    #if os(tvOS)
    icubeText(.tag)
    #else
    font(.caption2.weight(.semibold))
    #endif
  }
}

struct SaveStateCardView_Previews: PreviewProvider {
  static var previews: some View {
    let sample = SaveStateInfo(
      gameID: "GALE01",
      displayName: "Quick Slot 1",
      slot: 1,
      createdAt: Date().addingTimeInterval(-3600),
      modifiedAt: Date(),
      sizeBytes: 1024,
      versionHash: nil,
      isCompatible: true,
      path: URL(fileURLWithPath: "/tmp/dummy"),
      thumbnailURL: nil,
      isAuto: false,
      playTimeSeconds: 5427
    )
    SaveStateCardView(state: sample, thumbnail: nil)
      .preferredColorScheme(.dark)
      .padding()
      .background(Color.black)
  }
}
