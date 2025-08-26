import SwiftUI

struct TVSoftwarePropertiesView: View, Identifiable {
    let id = UUID()
    let item: TVGameItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Info") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(internalName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .minimumScaleFactor(0.8)
                    }
                    HStack {
                        Text("Game ID")
                        Spacer()
                        Text(combinedId)
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.8)
                    }
                    HStack {
                        Text("Country")
                        Spacer()
                        Text(item.countryName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Maker")
                        Spacer()
                        Text(item.makerLong)
                            .foregroundStyle(.secondary)
                    }
                    if let apploader = item.apploaderDateString, !apploader.isEmpty {
                        HStack {
                            Text("Apploader Date")
                            Spacer()
                            Text(apploader)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
