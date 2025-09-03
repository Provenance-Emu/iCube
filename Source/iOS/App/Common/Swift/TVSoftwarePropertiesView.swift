import SwiftUI

struct TVSoftwarePropertiesView: View, Identifiable {
    let id = UUID()
    let item: TVGameItem
    @Environment(\.dismiss) private var dismiss
    @State private var profilesVersion: Int = 0

    var body: some View {
        #if os(iOS)
        iosBody
        #else
        tvBody
        #endif
    }

    #if os(iOS)
    /// iOS layout: compact header + adaptive property grid inside a NavigationStack
    private var iosBody: some View {
        NavigationStack {
            GeometryReader { proxy in
                let isCompact = proxy.size.width < 600
                let coverWidth: CGFloat = isCompact ? 140 : 220
                let columns: [GridItem] = isCompact
                    ? [GridItem(.flexible(), spacing: 16)]
                    : [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(uiImage: item.coverImage)
                                .resizable()
                                .aspectRatio(2.0/3.0, contentMode: .fit)
                                .frame(width: coverWidth)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 6)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: isCompact ? 22 : 28, weight: .bold))
                                    .lineLimit(3)
                                Text(combinedId)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                                Toggle("Favorite", isOn: Binding(get: { item.isFavorite }, set: { item.isFavorite = $0 }))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        LazyVGrid(columns: columns, spacing: 12) {
                            let fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

                            PropertyCard(title: "Internal Name", value: internalName)
                            PropertyCard(title: "Game ID", value: item.gameID)

                            PropertyCard(title: "Disc", value: String(item.discNumber + 1))
                            PropertyCard(title: "Revision", value: String(item.revision))

                            PropertyCard(title: "Manufacturer", value: item.makerLong)
                            PropertyCard(title: "Region", value: item.countryName)

                            PropertyCard(title: "Title ID (Hex)", value: item.titleIDHex ?? "-")
                            PropertyCard(title: "GameTDB ID", value: item.gametdbID)

                            PropertyCard(title: "Apploader Date", value: item.apploaderDateString ?? "-")
                            PropertyCard(title: "File Size", value: fileSizeText)
                        }

                        // Profiles (MVP)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Profiles").font(.headline)
                            HStack(spacing: 12) {
                                if GameProfiles.shared.profile(for: item.gameID) != nil {
                                    Button("Apply Recommended") {
                                        if let rec = GameProfiles.shared.profile(for: item.gameID) {
                                            GameProfiles.shared.setProfile(rec, for: item.gameID)
                                            GameProfiles.shared.applyProfileIfAvailable(for: item)
                                            if let override = rec.touchControllerOverride {
                                                UserDefaults.standard.set(override.rawValue, forKey: "current_profile_touch_override")
                                            } else {
                                                UserDefaults.standard.removeObject(forKey: "current_profile_touch_override")
                                            }
                                            if let irOverride = rec.wiimoteTouchIRMode {
                                                UserDefaults.standard.set(irOverride, forKey: "current_profile_ir_override")
                                            } else {
                                                UserDefaults.standard.removeObject(forKey: "current_profile_ir_override")
                                            }
                                            profilesVersion &+= 1
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Toggle("Widescreen Hack", isOn: Binding(get: { DOLConfigBridge.gfxWidescreenHack() }, set: { DOLConfigBridge.setGfxWidescreenHack($0) }))
                            }
                            HStack(spacing: 12) {
                                Picker("IR Mode", selection: Binding(get: { DOLConfigBridge.mainTouchPadIRMode() }, set: { DOLConfigBridge.setMainTouchPadIRMode($0) })) {
                                    Text("None").tag(0)
                                    Text("Absolute").tag(1)
                                    Text("Drag").tag(2)
                                }
                                .pickerStyle(.segmented)
                            }
                            // Per-game IR Mode override (Wii Touch)
                            HStack(spacing: 12) {
                                Picker("Per-Game IR Mode", selection: Binding(get: {
                                    (UserDefaults.standard.object(forKey: "current_profile_ir_override") as? Int) ?? -1
                                }, set: { newVal in
                                    if newVal < 0 { UserDefaults.standard.removeObject(forKey: "current_profile_ir_override") }
                                    else { UserDefaults.standard.set(newVal, forKey: "current_profile_ir_override") }
                                    profilesVersion &+= 1
                                })) {
                                    Text("Use Global").tag(-1)
                                    Text("None").tag(0)
                                    Text("Absolute").tag(1)
                                    Text("Drag").tag(2)
                                }
                                .pickerStyle(.segmented)
                            }
                            // Per-game Touch Controller override
                            HStack(spacing: 12) {
                                Picker("On-Screen Controller", selection: Binding(get: {
                                    if let raw = UserDefaults.standard.string(forKey: "current_profile_touch_override"), let v = TouchControllerOverride(rawValue: raw) { return v }
                                    return .systemAuto
                                }, set: { newVal in
                                    if newVal == .systemAuto { UserDefaults.standard.removeObject(forKey: "current_profile_touch_override") }
                                    else { UserDefaults.standard.set(newVal.rawValue, forKey: "current_profile_touch_override") }
                                    profilesVersion &+= 1
                                })) {
                                    Text("Auto (by System)").tag(TouchControllerOverride.systemAuto)
                                    Text("Force GameCube").tag(TouchControllerOverride.forceGameCube)
                                    Text("Force Wii").tag(TouchControllerOverride.forceWii)
                                }
                            }
                            // Per-game Wii IR Sensitivity
                            VStack(alignment: .leading) {
                                HStack { Text("Wii IR Sensitivity"); Spacer(); Text("\(DOLConfigBridge.sysconfSensorBarSensitivity())").foregroundStyle(.secondary) }
                                Slider(value: Binding(get: { Double(DOLConfigBridge.sysconfSensorBarSensitivity()) }, set: { DOLConfigBridge.setSysconfSensorBarSensitivity(Int($0.rounded())) }), in: 1...5, step: 1)
                            }
                            // Shader preset chooser with preview
                            HStack {
                                NavigationLink(destination: ShaderPickerView(selectedPresetPath: Binding(get: { UserDefaults.standard.string(forKey: "shader_preset_path") }, set: { UserDefaults.standard.set($0, forKey: "shader_preset_path"); NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil) }))) {
                                    Text("Shader Preset")
                                    Spacer()
                                    Text(UserDefaults.standard.string(forKey: "shader_preset_path")?.split(separator: "/").last.map(String.init) ?? L("None")).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            HStack(spacing: 12) {
                                Button("Save Current as Profile") {
                                    var snap = GameProfiles.shared.buildProfileFromCurrentSettings()
                                    if let raw = UserDefaults.standard.string(forKey: "current_profile_touch_override"), let v = TouchControllerOverride(rawValue: raw) {
                                        snap.touchControllerOverride = v
                                    }
                                    if let ir = UserDefaults.standard.object(forKey: "current_profile_ir_override") as? Int {
                                        snap.wiimoteTouchIRMode = ir
                                    }
                                    GameProfiles.shared.setProfile(snap, for: item.gameID)
                                    GameProfiles.shared.applyProfileIfAvailable(for: item)
                                    profilesVersion &+= 1
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Clear Profile") {
                                    GameProfiles.shared.clearProfile(for: item.gameID)
                                    UserDefaults.standard.removeObject(forKey: "current_profile_touch_override")
                                    UserDefaults.standard.removeObject(forKey: "current_profile_ir_override")
                                    // Force update for the toggles and pickers to reflect cleared state
                                    DOLConfigBridge.setGfxWidescreenHack(false)
                                    profilesVersion &+= 1
                                }
                                    .buttonStyle(.bordered)
                                if GameProfiles.shared.hasSavedProfile(for: item.gameID) {
                                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            // Optional diff view
                            if let prof = GameProfiles.shared.profile(for: item.gameID) {
                                let diff = GameProfiles.shared.diffCurrentSettings(from: prof)
                                if !diff.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Profile Differences").font(.subheadline).foregroundStyle(.secondary)
                                        ForEach(Array(diff.enumerated()), id: \.offset) { pair in
                                            let row = pair.element
                                            HStack { Text(row.0); Spacer(); Text(row.1).foregroundStyle(.secondary); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(row.2).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .id(profilesVersion)
                    }
                    .padding(16)
                }
                .background(
                    Image(uiImage: item.coverImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 20)
                        .opacity(0.35)
                        .ignoresSafeArea()
                )
            }
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
    #endif

    /// tvOS layout preserved from previous implementation
    private var tvBody: some View {
        // Background composed as a single view and applied via .background to avoid ZStack ordering issues
        let backgroundView = Image(uiImage: item.coverImage)
            .resizable()
            .scaledToFill()
            .blur(radius: 25)
            .opacity(0.8)
            .ignoresSafeArea()
            .allowsHitTesting(false)

        return ScrollView {
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
