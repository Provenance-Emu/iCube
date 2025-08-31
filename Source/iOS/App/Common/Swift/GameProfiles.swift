import Foundation

struct GameProfile: Codable {
    var shaderPresetPath: String?
    var irMode: Int?
    var widescreenHack: Bool?
    var touchOpacity: Float?
}

final class GameProfiles {
    static let shared = GameProfiles()

    private var profiles: [String: GameProfile] = [:] // GameID -> profile

    private init() {
        load()
    }

    private func profilesFileURL() -> URL? {
        let base = UserFolderUtil.getUserFolder()
        let dir = URL(fileURLWithPath: base).appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("game_profiles.json")
    }

    private func load() {
        guard let url = profilesFileURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            profiles = try JSONDecoder().decode([String: GameProfile].self, from: data)
        } catch {
            print("[Profiles] Failed to load: \(error)")
        }
    }

    func save() {
        guard let url = profilesFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: url)
        } catch {
            print("[Profiles] Failed to save: \(error)")
        }
    }

    func profile(for gameID: String) -> GameProfile? {
        if let p = profiles[gameID] { return p }
        return recommendedProfile(for: gameID)
    }

    func setProfile(_ profile: GameProfile, for gameID: String) {
        profiles[gameID] = profile
        save()
    }

    func applyProfileIfAvailable(for item: TVGameItem) {
        // Allow disabling via defaults if needed
        if UserDefaults.standard.object(forKey: "profiles_enabled") as? Bool == false {
            return
        }
        let gameID = item.gameID
        guard let profile = profile(for: gameID) else { return }
        // Widescreen hack
        if let ws = profile.widescreenHack {
            if ws != DOLConfigBridge.gfxWidescreenHack() {
                DOLConfigBridge.setGfxWidescreenHack(ws)
            }
        }
        // IR mode
        if let mode = profile.irMode, mode >= 0 {
            if mode != DOLConfigBridge.mainTouchPadIRMode() {
                DOLConfigBridge.setMainTouchPadIRMode(mode)
            }
        }
        // Touch opacity
        if let opacity = profile.touchOpacity {
            if fabsf(opacity - DOLConfigBridge.mainTouchPadOpacity()) > 0.001 {
                DOLConfigBridge.setMainTouchPadOpacity(opacity)
            }
        }
        // Shader preset: avoid heavy immediate reloads; set intent only
        if let preset = profile.shaderPresetPath {
            let current = UserDefaults.standard.string(forKey: "shader_preset_path")
            if current != preset {
                UserDefaults.standard.set(preset, forKey: "shader_preset_path")
                // Notify but do not force an immediate apply to avoid stutter
                NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
            }
        }
    }

    // Stub for curated recommendations; fill over time
    private func recommendedProfile(for gameID: String) -> GameProfile? {
        return nil
    }
}
