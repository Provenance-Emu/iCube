import SwiftUI

struct TVSoftwarePropertiesView: View, Identifiable {
    let id = UUID()
    let item: TVGameItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Background composed as a single view and applied via .background to avoid ZStack ordering issues
        let backgroundView = Image(uiImage: item.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: 25)
            .opacity(0.8)
            .ignoresSafeArea()
            .allowsHitTesting(false)

        ScrollView {
            HStack(spacing: 80) {
                // Left: Game cover with shadow (mirroring PauseMenuView)
                VStack(alignment: .leading, spacing: 16) {
                    Image(uiImage: item.coverImage)
                        .resizable()
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .frame(width: 220, height: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

                    // Optional: small ID under the cover (like Pause)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                        Text(item.gameID)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .frame(width: 220)

                // Right: Title + rounded container with property grid
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(combinedId)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        // Prepare formatted values
                        let fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 16) {
                            // Core identifiers
                            PropertyCard(title: "Internal Name", value: internalName)
                            PropertyCard(title: "Game ID", value: item.gameID)

                            // Disc/Revision
                            PropertyCard(title: "Disc", value: String(item.discNumber + 1))
                            PropertyCard(title: "Revision", value: String(item.revision))

                            // Publisher/Manufacturer and Region
                            PropertyCard(title: "Manufacturer", value: item.makerLong)
                            PropertyCard(title: "Region", value: item.countryName)

                            // IDs
                            PropertyCard(title: "Title ID (Hex)", value: item.titleIDHex ?? "-")
                            PropertyCard(title: "GameTDB ID", value: item.gametdbID)

                            // Other
                            PropertyCard(title: "Apploader Date", value: item.apploaderDateString ?? "-")
                            PropertyCard(title: "File Size", value: fileSizeText)
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 50)
        }
        .background(backgroundView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(24)
        }
      #if os(tvOS)
        .onExitCommand {
            dismiss()
        }
      #endif
    }

    private var internalName: String {
        let name = item.title
        let disc = item.discNumber
        let rev = item.revision
        if disc > 0 {
            return "\(name) (Disc \(disc + 1), Revision \(rev))"
        } else {
            return "\(name) (Revision \(rev))"
        }
    }

    private var combinedId: String {
        if let titleHex = item.titleIDHex, !titleHex.isEmpty {
            return "\(item.gameID) (\(titleHex))"
        }
        return item.gameID
    }
}

// MARK: - Property Card Component

private struct PropertyCard: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .textCase(.uppercase)
                
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}
