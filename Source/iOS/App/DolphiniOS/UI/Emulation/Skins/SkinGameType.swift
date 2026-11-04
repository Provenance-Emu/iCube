// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The games a Delta/Manic skin can target that iCube runs. A skin declares its game type as a
/// reverse-DNS identifier (`public.aoshuang.game.ngc`, `com.rileytestut.delta.game.wii`); only the
/// last component matters, so both Delta and Manic spellings resolve to the same case.
///
/// NES and Super NES skins are for Virtual Console titles. They install as-is, unlike N64 skins (which
/// the store rewrites to GameCube): keeping the type is what keeps a NES skin off GameCube discs.
enum SkinGameType: Hashable {
  case gameCube
  case wii
  case nes
  case snes

  private static let gameCubeSuffixes: Set<String> = ["ngc", "gc", "gamecube"]
  private static let wiiSuffixes: Set<String> = ["wii"]
  /// The catalog files Famicom Disk System skins under `nes`.
  private static let nesSuffixes: Set<String> = ["nes", "fds"]
  private static let snesSuffixes: Set<String> = ["snes", "sfc"]

  init?(identifier: String) {
    let suffix = identifier.lowercased().split(separator: ".").last.map(String.init) ?? ""
    if Self.gameCubeSuffixes.contains(suffix) {
      self = .gameCube
    } else if Self.wiiSuffixes.contains(suffix) {
      self = .wii
    } else if Self.nesSuffixes.contains(suffix) {
      self = .nes
    } else if Self.snesSuffixes.contains(suffix) {
      self = .snes
    } else {
      return nil
    }
  }

  private static let manicPrefix = "public.aoshuang.game."

  /// The Manic EMU identifier for this game type, used when a skin is rewritten to it.
  var manicIdentifier: String {
    switch self {
    case .gameCube: return Self.manicPrefix + "ngc"
    case .wii: return Self.manicPrefix + "wii"
    case .nes: return Self.manicPrefix + "nes"
    case .snes: return Self.manicPrefix + "snes"
    }
  }

  /// Appended to a skin's identifier when it is rewritten to this type, so the rewritten copy never
  /// replaces an as-is import of the same skin. Nothing is rewritten to NES or SNES.
  var retargetSuffix: String {
    switch self {
    case .gameCube: return "-gamecube"
    case .wii: return "-wii"
    case .nes: return "-nes"
    case .snes: return "-snes"
    }
  }

  /// The touch overlay pad kinds a skin of this game type can replace. NES skins cover every pad a VC NES
  /// title accepts; SNES VC does not use the sideways remote.
  var padKinds: [TouchOverlayPadKind] {
    switch self {
    case .gameCube: return [.gameCube]
    case .wii: return [.wiiRemote, .wiiRemoteSideways, .wiiClassic]
    case .nes: return [.gameCube, .wiiClassic, .wiiRemoteSideways]
    case .snes: return [.gameCube, .wiiClassic]
    }
  }
}
#endif
