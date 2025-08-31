import Foundation

final class ControllerStyleManager {
    static let shared = ControllerStyleManager()

    private let key = "controller_glyph_set"

    func current() -> ControllerGlyphSet {
        if let raw = UserDefaults.standard.string(forKey: key), let set = ControllerGlyphSet(rawValue: raw) {
            return set
        }
        return .generic
    }

    func refreshDetection() {
        let detected = ControllerGlyphs.detectGlyphSet()
        let previous = current()
        if detected != previous {
            UserDefaults.standard.set(detected.rawValue, forKey: key)
            // Persist default mapping for UI hints
            applyPresetDefaults()
            NotificationCenter.default.post(name: Notification.Name("DOLControllerGlyphSetDidChange"), object: nil, userInfo: ["glyphSet": detected.rawValue])
        }
    }

    func applyPresetDefaults() {
        let preset = ControllerPresetLibrary.resolve()
        for (action, control) in preset.mapping {
            UserDefaults.standard.set(control, forKey: "controller_action_\(action.rawValue)")
        }
    }
}
