import Foundation

enum ControllerAction: String { case confirm, cancel, start, menu, pause }

struct ControllerPreset {
    let glyphSet: ControllerGlyphSet
    let mapping: [ControllerAction: String] // logical action -> Dolphin control key
}

struct ControllerPresetLibrary {
    static let playstation = ControllerPreset(
        glyphSet: .playstation,
        mapping: [
            .confirm: "gcPadA",
            .cancel: "gcPadB",
            .start: "gcPadStart",
            .menu: "menu",
            .pause: "pause"
        ]
    )
    static let xbox = ControllerPreset(
        glyphSet: .xbox,
        mapping: [
            .confirm: "gcPadA",
            .cancel: "gcPadB",
            .start: "gcPadStart",
            .menu: "menu",
            .pause: "pause"
        ]
    )
    static let nintendo = ControllerPreset(
        glyphSet: .nintendo,
        mapping: [
            .confirm: "gcPadA",
            .cancel: "gcPadB",
            .start: "gcPadStart",
            .menu: "menu",
            .pause: "pause"
        ]
    )
    static let generic = ControllerPreset(
        glyphSet: .generic,
        mapping: [
            .confirm: "gcPadA",
            .cancel: "gcPadB",
            .start: "gcPadStart",
            .menu: "menu",
            .pause: "pause"
        ]
    )

    static func resolve() -> ControllerPreset {
        switch ControllerGlyphs.detectGlyphSet() {
        case .playstation: return playstation
        case .xbox: return xbox
        case .nintendo: return nintendo
        case .generic: return generic
        }
    }
}
