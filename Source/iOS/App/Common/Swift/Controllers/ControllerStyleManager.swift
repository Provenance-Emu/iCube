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
      NotificationCenter.default.post(name: Notification.Name("DOLControllerGlyphSetDidChange"), object: nil, userInfo: ["glyphSet": detected.rawValue])
    }
  }
}
