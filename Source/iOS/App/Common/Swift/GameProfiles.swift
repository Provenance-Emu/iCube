import Foundation

struct GameProfile: Codable {
    var shaderPresetPath: String?
    var irMode: Int?
    var widescreenHack: Bool?
    var touchOpacity: Float?
    /// Overrides
    var touchControllerOverride: TouchControllerOverride?
    var wiimoteIRSensitivity: Int?
    var wiimoteTouchIRMode: Int?
    var shaderPreviewName: String?
}

enum TouchControllerOverride: String, Codable {
    case systemAuto
    case forceGameCube
    case forceWii
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

    func hasSavedProfile(for gameID: String) -> Bool {
        return profiles[gameID] != nil
    }

    func profile(for gameID: String) -> GameProfile? {
        if let p = profiles[gameID] { return p }
        return recommendedProfile(for: gameID)
    }

    func setProfile(_ profile: GameProfile, for gameID: String) {
        profiles[gameID] = profile
        save()
    }

    func clearProfile(for gameID: String) {
        profiles.removeValue(forKey: gameID)
        save()
        // Also clear any per-game overrides and revert to sane defaults at runtime
        // Touch overrides are in UserDefaults
        UserDefaults.standard.removeObject(forKey: "current_profile_touch_override")
        UserDefaults.standard.removeObject(forKey: "current_profile_ir_override")
        // Reset runtime-affecting settings to defaults that won’t surprise the user
        // Do not change global user prefs except those we might have overridden
        DOLConfigBridge.setGfxWidescreenHack(false)
        // Clear shader preset to None and notify so UI/backend can refresh
        UserDefaults.standard.removeObject(forKey: "shader_preset_path")
        NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
    }

    /// Builds a profile from the current global settings the user has configured
    func buildProfileFromCurrentSettings() -> GameProfile {
        let widescreen = DOLConfigBridge.gfxWidescreenHack()
        let ir = DOLConfigBridge.mainTouchPadIRMode()
        #if os(iOS)
        let opacity = DOLConfigBridge.mainTouchPadOpacity()
        #else
        let opacity: Float? = nil
        #endif
        let preset = UserDefaults.standard.string(forKey: "shader_preset_path")
        // Attempt to capture current Wii IR sensitivity if available
        let wiimoteSens = DOLConfigBridge.sysconfSensorBarSensitivity()
        return GameProfile(
            shaderPresetPath: preset,
            irMode: ir,
            widescreenHack: widescreen,
            touchOpacity: opacity,
            touchControllerOverride: nil,
            wiimoteIRSensitivity: wiimoteSens,
            wiimoteTouchIRMode: ir,
            shaderPreviewName: preset?.split(separator: "/").last.map(String.init)
        )
    }

    /// Saves the current settings snapshot as this game's profile
    func saveCurrentSettings(asProfileFor gameID: String) {
        let snap = buildProfileFromCurrentSettings()
        setProfile(snap, for: gameID)
    }

    func applyProfileIfAvailable(for item: TVGameItem) {
        if UserDefaults.standard.object(forKey: "profiles_enabled") as? Bool == false { return }
        let gameID = item.gameID
        guard let profile = profile(for: gameID) else {
            // Clear any previous override if no profile
            UserDefaults.standard.removeObject(forKey: "current_profile_touch_override")
            return
        }
        // Widescreen hack
        if let ws = profile.widescreenHack {
            if ws != DOLConfigBridge.gfxWidescreenHack() {
                DOLConfigBridge.setGfxWidescreenHack(ws)
            }
        }
        // Per-game Wii Touch IR mode override (decoupled from global when set)
        if let mode = profile.wiimoteTouchIRMode, mode >= 0 {
            if mode != DOLConfigBridge.mainTouchPadIRMode() {
                DOLConfigBridge.setMainTouchPadIRMode(mode)
            }
        }
        // IR mode legacy field
        if let mode = profile.irMode, profile.wiimoteTouchIRMode == nil, mode >= 0 {
            if mode != DOLConfigBridge.mainTouchPadIRMode() {
                DOLConfigBridge.setMainTouchPadIRMode(mode)
            }
        }
        // IR sensitivity (Wii)
        if let sens = profile.wiimoteIRSensitivity {
            if sens != DOLConfigBridge.sysconfSensorBarSensitivity() {
                DOLConfigBridge.setSysconfSensorBarSensitivity(sens)
            }
        }
        // Touch opacity
        if let opacity = profile.touchOpacity {
            if fabsf(opacity - DOLConfigBridge.mainTouchPadOpacity()) > 0.001 {
                DOLConfigBridge.setMainTouchPadOpacity(opacity)
            }
        }
        // Shader preset intent
        if let preset = profile.shaderPresetPath {
            let current = UserDefaults.standard.string(forKey: "shader_preset_path")
            if current != preset {
                UserDefaults.standard.set(preset, forKey: "shader_preset_path")
                NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
            }
        }
        // Touch controller visibility preference: stash in defaults for runtime UI
        if let overridePref = profile.touchControllerOverride {
            UserDefaults.standard.set(overridePref.rawValue, forKey: "current_profile_touch_override")
        } else {
            UserDefaults.standard.removeObject(forKey: "current_profile_touch_override")
        }
    }

    // Optional: derive a simple diff
    func diffCurrentSettings(from profile: GameProfile) -> [(String, String, String)] {
        var rows: [(String, String, String)] = []
        // widescreen
        let wsNow = DOLConfigBridge.gfxWidescreenHack()
        if let ws = profile.widescreenHack, ws != wsNow { rows.append(("Widescreen", ws ? "On" : "Off", wsNow ? "On" : "Off")) }
        // touch IR mode
        let irNow = DOLConfigBridge.mainTouchPadIRMode()
        if let ir = profile.wiimoteTouchIRMode ?? profile.irMode, ir != irNow { rows.append(("Touch IR Mode", String(ir), String(irNow))) }
        // IR sensitivity
        let sensNow = DOLConfigBridge.sysconfSensorBarSensitivity()
        if let s = profile.wiimoteIRSensitivity, s != sensNow { rows.append(("IR Sensitivity", String(s), String(sensNow))) }
        // opacity
        #if os(iOS)
        let opNow = DOLConfigBridge.mainTouchPadOpacity()
        if let op = profile.touchOpacity, fabsf(op - opNow) > 0.001 { rows.append(("Touch Opacity", String(format: "%.2f", op), String(format: "%.2f", opNow))) }
        #endif
        // shader
        let presetNow = UserDefaults.standard.string(forKey: "shader_preset_path") ?? "-"
        if let pr = profile.shaderPresetPath, pr != presetNow { rows.append(("Shader Preset", (pr as NSString).lastPathComponent, (presetNow as NSString).lastPathComponent)) }
        return rows
    }

    // Stub for curated recommendations; currently unused.
    private func recommendedProfile(for gameID: String) -> GameProfile? {
        // If we add curated per-title presets, return them here. Returning nil hides any effect.
        return nil
    }
}
