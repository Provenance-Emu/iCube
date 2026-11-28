// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Turns loose replacement files into a Riivolution pack, so Dolphin's own patcher applies them
/// when the game boots. Nothing on the disc image is rewritten.
///
/// Each folder of the download becomes one option the user can switch in "Play with Mods". A
/// folder whose file names an earlier folder already replaces starts switched off: mods ship
/// alternatives side by side ("Over Mario", "Over Luigi", "Optional").
enum ModGameFilePackBuilder {
  struct Option: Equatable {
    var name: String
    var isOnByDefault: Bool
    /// The XML elements of the option's patch, one per line.
    var patchLines: [String]
  }

  struct Plan: Equatable {
    /// Names the pack's XML, its folder on the virtual SD card and its patch ids.
    var packID: String
    var options: [Option]
    /// Files to stage, with their path below the virtual SD root.
    var copies: [Copy]
    var xml: String

    /// `riivolution/<packID>.xml`, below the virtual SD root.
    var xmlRelativePath: String { "\(RiivolutionLocation.xmlFolderName)/\(packID).xml" }
  }

  struct Copy: Equatable {
    var source: URL
    var destination: String
  }

  enum BuildError: LocalizedError, Equatable {
    case unknownGame
    case nothingToInstall
    /// The user's disc has no file named like any of the download's.
    case nothingOnDisc(fileCount: Int, gameTitle: String)

    var errorDescription: String? {
      switch self {
      case .nothingOnDisc(let count, let title):
        return String(format: L("None of the %d files in this download has the same name as a file on your %@ disc, so they would replace nothing. The mod may be for another game or region, or need a PC tool to install."),
                      count, title)
      case .unknownGame: return L("Open the Mod Browser from the game these files are for, so iCube knows which disc they replace files on.")
      case .nothingToInstall: return L("None of the files in this download can replace a file on the game disc.")
      }
    }
  }

  /// Folder on the virtual SD card that holds every generated pack's files.
  static let filesFolderName = "icube-mods"
  private static let titleCodeLength = 3
  private static let maxOptionNameLength = 60

  /// `titleCode` is the first three characters of the game id (`SMN`): the pack is offered for every
  /// region and revision of that title. `packID` must be safe as a file name.
  static func plan(pack: ModGameFilePack, modName: String, packID: String, titleCode: String?) throws -> Plan {
    guard let titleCode, titleCode.count >= titleCodeLength else { throw BuildError.unknownGame }
    let code = String(titleCode.uppercased().prefix(titleCodeLength))
    guard code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw BuildError.unknownGame }

    var options: [Option] = []
    var copies: [Copy] = []
    var claimed: Set<String> = []
    let base = "\(filesFolderName)/\(packID)"

    for (index, group) in pack.groups.enumerated() where !group.files.isEmpty {
      // The group's index keeps two folders with one name, or a name unsafe on disk, apart.
      let folder = "\(base)/\(index)"
      let keys: Set<String>
      let line: String
      var isOn: Bool
      switch group.mapping {
      case .byName:
        keys = Set(group.files.map { $0.lowercased() })
        line = #"<folder external="/\#(escaped(folder))" />"#
        isOn = keys.isDisjoint(with: claimed)
      case .discTree:
        keys = Set(group.files.map { "/" + $0.lowercased() })
        line = #"<folder disc="/" external="/\#(escaped(folder))" recursive="true" create="true" />"#
        isOn = keys.isDisjoint(with: claimed)
      case .mainExecutable:
        keys = []
        line = #"<file disc="main.dol" external="/\#(escaped(folder + "/" + group.files[0]))" />"#
        // A program is built for one region and revision of a game and nothing here can tell which,
        // so it is never on by itself: the user switches it on under Play with Mods.
        isOn = false
      }
      if isOn { claimed.formUnion(keys) }
      copies += group.files.map { Copy(source: relative($0, to: group.directory), destination: "\(folder)/\($0)") }
      options.append(Option(name: optionName(for: group, modName: modName), isOnByDefault: isOn, patchLines: [line]))
    }
    guard !options.isEmpty else { throw BuildError.nothingToInstall }

    let named = uniqued(options)
    return Plan(packID: packID, options: named, copies: copies,
                xml: xml(options: named, modName: modName, packID: packID, titleCode: code))
  }

  /// Writes the plan as a pack under `directory` (`riivolution/<id>.xml` plus the files), ready for
  /// `RiivolutionPackInstaller`. Files are copied, so the download stays whole.
  static func stage(_ plan: Plan, in directory: URL) throws {
    let fileManager = FileManager.default
    for copy in plan.copies {
      let target = relative(copy.destination, to: directory)
      try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fileManager.removeItem(at: target)
      try fileManager.copyItem(at: copy.source, to: target)
    }
    let xmlURL = relative(plan.xmlRelativePath, to: directory)
    try fileManager.createDirectory(at: xmlURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(plan.xml.utf8).write(to: xmlURL, options: .atomic)
  }

  /// A name safe for a file and an XML id, from a GameBanana file id.
  static func packID(forFileID id: Int) -> String { "gamebanana-\(id)" }

  // MARK: - XML

  private static func xml(options: [Option], modName: String, packID: String, titleCode: String) -> String {
    var lines = [
      #"<?xml version="1.0" encoding="UTF-8"?>"#,
      "<!-- Written by iCube for loose game files downloaded from the Mod Browser. -->",
      #"<wiidisc version="1">"#,
      #"  <id game="\#(titleCode)" />"#,
      "  <options>",
      #"    <section name="\#(escaped(modName))">"#,
    ]
    for (index, option) in options.enumerated() {
      let patch = "\(packID)-\(index)"
      lines.append(#"      <option name="\#(escaped(option.name))" id="\#(patch)" default="\#(option.isOnByDefault ? 1 : 0)">"#)
      lines.append(#"        <choice name="\#(escaped(L("On")))"><patch id="\#(patch)" /></choice>"#)
      lines.append("      </option>")
    }
    lines += ["    </section>", "  </options>"]
    for (index, option) in options.enumerated() {
      lines.append(#"  <patch id="\#(packID)-\#(index)">"#)
      lines += option.patchLines.map { "    " + $0 }
      lines.append("  </patch>")
    }
    lines.append("</wiidisc>")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func optionName(for group: ModGameFilePack.Group, modName: String) -> String {
    let base = group.name.isEmpty ? modName : group.name
    let name = group.mapping == .mainExecutable ? String(format: L("Game program (%@)"), group.files[0]) : base
    return name.count > maxOptionNameLength ? "…" + String(name.suffix(maxOptionNameLength - 1)) : name
  }

  /// Riivolution saves a choice under the option's name, so two options must not share one.
  private static func uniqued(_ options: [Option]) -> [Option] {
    var seen: [String: Int] = [:]
    return options.map { option in
      var option = option
      let count = (seen[option.name] ?? 0) + 1
      seen[option.name] = count
      if count > 1 { option.name += " (\(count))" }
      return option
    }
  }

  private static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func relative(_ path: String, to directory: URL) -> URL {
    path.split(separator: "/").reduce(directory) { $0.appendingPathComponent(String($1)) }
  }
}
