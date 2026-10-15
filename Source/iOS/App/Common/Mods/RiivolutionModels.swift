// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where Riivolution packs live: Dolphin's virtual SD card, `File::GetUserPath(D_RIIVOLUTION_IDX)`.
enum RiivolutionLocation {
  /// Folder inside the SD root that holds the pack XMLs. Dolphin searches for it in lowercase.
  static let xmlFolderName = "riivolution"

  /// `<User>/Load/Riivolution`. The user folder is the one the core was given at launch.
  static func installRoot(userFolder: String = UserFolderUtil.getUserFolder()) -> URL {
    URL(fileURLWithPath: userFolder, isDirectory: true)
      .appendingPathComponent("Load", isDirectory: true)
      .appendingPathComponent("Riivolution", isDirectory: true)
  }
}

/// Which library games get the "Play with Mods" entry.
enum RiivolutionEligibility {
  /// A disc image on this device: a Riivolution patch rewrites what the game reads from its disc. Remote titles,
  /// channels (WADs), homebrew and mod descriptors themselves are left out.
  static func isEligible(filePath: String, platform: Int) -> Bool {
    guard filePath.hasPrefix("/"), !ModDescriptorStore.isDescriptor(path: filePath) else { return false }
    let disc = DiscIOPlatform(rawValue: platform)
    return disc == .gameCubeDisc || disc == .wiiDisc
  }
}

/// One option of a pack. `selectedChoice` 0 means off; n picks `choices[n - 1]`.
struct RiivolutionOption: Equatable {
  let sectionName: String
  let optionID: String
  let name: String
  let choices: [String]
  var selectedChoice: Int

  /// Row label for the current selection.
  var selectedChoiceName: String? {
    guard selectedChoice > 0, selectedChoice <= choices.count else { return nil }
    return choices[selectedChoice - 1]
  }
}

/// The options of one section, as indices into `RiivolutionPack.options`.
struct RiivolutionSection: Equatable {
  let name: String
  let optionIndices: [Int]
}

/// One Riivolution XML valid for a game.
struct RiivolutionPack: Equatable, Identifiable {
  let xmlPath: String
  let rootPath: String
  var options: [RiivolutionOption]

  var id: String { xmlPath }

  var title: String {
    URL(fileURLWithPath: xmlPath).deletingPathExtension().lastPathComponent
  }

  /// True when at least one option has a choice selected, i.e. the pack changes the game.
  var hasSelection: Bool {
    options.contains { $0.selectedChoice > 0 }
  }

  /// Options grouped by section, in XML order. Options of one section are adjacent in the XML.
  var sections: [RiivolutionSection] {
    var result: [RiivolutionSection] = []
    for (index, option) in options.enumerated() {
      if let last = result.last, last.name == option.sectionName {
        result[result.count - 1] = RiivolutionSection(name: last.name, optionIndices: last.optionIndices + [index])
      } else {
        result.append(RiivolutionSection(name: option.sectionName, optionIndices: [index]))
      }
    }
    return result
  }
}

extension RiivolutionPack {
  init(info: RiivolutionPackInfo) {
    self.init(
      xmlPath: info.xmlPath,
      rootPath: info.rootPath,
      options: info.options.map {
        RiivolutionOption(
          sectionName: $0.sectionName,
          optionID: $0.optionID,
          name: $0.name,
          choices: $0.choices,
          selectedChoice: Int($0.selectedChoice)
        )
      }
    )
  }

  var bridgeInfo: RiivolutionPackInfo {
    let info = RiivolutionPackInfo()
    info.xmlPath = xmlPath
    info.rootPath = rootPath
    info.options = options.map { option in
      let optionInfo = RiivolutionOptionInfo()
      optionInfo.sectionName = option.sectionName
      optionInfo.optionID = option.optionID
      optionInfo.name = option.name
      optionInfo.choices = option.choices
      optionInfo.selectedChoice = UInt(option.selectedChoice)
      return optionInfo
    }
    return info
  }
}
