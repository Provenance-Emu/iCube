// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The games a Delta/Manic skin can target that iCube runs. A skin declares its game type as a
/// reverse-DNS identifier (`public.aoshuang.game.ngc`, `com.rileytestut.delta.game.wii`); only the
/// last component matters, so both Delta and Manic spellings resolve to the same case.
enum SkinGameType: Equatable {
  case gameCube
  case wii

  private static let gameCubeSuffixes: Set<String> = ["ngc", "gc", "gamecube"]
  private static let wiiSuffixes: Set<String> = ["wii"]

  init?(identifier: String) {
    let suffix = identifier.lowercased().split(separator: ".").last.map(String.init) ?? ""
    if Self.gameCubeSuffixes.contains(suffix) {
      self = .gameCube
    } else if Self.wiiSuffixes.contains(suffix) {
      self = .wii
    } else {
      return nil
    }
  }

  /// The touch overlay pad kinds a skin of this game type can replace.
  var padKinds: [TouchOverlayPadKind] {
    switch self {
    case .gameCube: return [.gameCube]
    case .wii: return [.wiiRemote, .wiiRemoteSideways, .wiiClassic]
    }
  }
}
#endif
