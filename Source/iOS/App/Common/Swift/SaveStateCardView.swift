import SwiftUI
import UIKit

struct SaveStateCardView: View {
  let state: SaveStateInfo
  let thumbnail: UIImage?

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Thumbnail or placeholder
      Group {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.gray.opacity(0.25))
            .overlay(
              Image(systemName: "photo")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
            )
        }
      }
      .frame(width: 300, height: 170)
      .clipped()
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
      )
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.white.opacity(0.04))
      )
      .cornerRadius(12)

      // Vignette + metadata
      LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.7)],
        startPoint: .center, endPoint: .bottom
      )
      .cornerRadius(12)

      VStack(alignment: .leading, spacing: 4) {
        Text(state.displayName)
          .font(.headline)
          .foregroundColor(.white)
          .lineLimit(1)
        HStack(spacing: 8) {
          if state.isAuto {
            Badge(text: "Continue", color: .green)
          }
          if let slot = state.slot {
            Badge(text: "Slot \(slot)")
          }
          if !state.isCompatible {
            Badge(text: "Incompatible", color: .red)
          }
          Text(timestampString)
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.85))
        }
      }
      .padding(12)
    }
  }

  private var timestampString: String {
    let date = state.modifiedAt ?? state.createdAt
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct Badge: View {
  let text: String
  var color: Color = .blue
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.75), in: Capsule())
      .foregroundColor(.white)
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
      isAuto: false
    )
    SaveStateCardView(state: sample, thumbnail: nil)
      .preferredColorScheme(.dark)
      .padding()
      .background(Color.black)
  }
}
