// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Gives a GameCube homebrew program the SD card it expects.
///
/// A Dolphin Depot package is the contents of an SD card: `apps/<name>/default.dol` with the
/// program's levels, music and settings beside it, and programs read those from the card while
/// they run. The emulator core has no folder-backed card for a GameCube, so each launch packs the
/// title's own folder (`Software/Homebrew/<slug>/`) into a FAT image, puts it in memory card slot
/// B for that run, and afterwards copies back what the program wrote. Files the user adds to the
/// folder (an emulator's ROMs, a player's music) are on the card at the next launch.
///
/// A loader on a console tells the program where it was started from, and the program looks for
/// its files relative to that (FruitY opens `data/levels.bin`). The emulator starts a program
/// without that, which leaves it at the card's root, so the card also shows the program's own
/// folder (`apps/<name>/`) at the root.
@objc(DOLHomebrewSDCard)
final class HomebrewSDCard: NSObject {
  /// The emulator core's side of the work. Tests pass their own.
  struct Core {
    var pack: (_ folder: URL, _ image: URL) -> Bool
    var unpack: (_ image: URL, _ folder: URL) -> Bool
    var insert: (_ image: URL) -> Void
    var remove: () -> Void

    static let live = Core(
      pack: { DOLSDCardPackFolder($0.path, $1.path) },
      unpack: { DOLSDCardUnpackImage($0.path, $1.path) },
      insert: { DOLSDCardInsertForThisRun($0.path) },
      remove: { DOLSDCardRemoveForThisRun() })
  }

  private struct Card {
    let folder: URL
    /// The program's folder inside `folder`, as path components; empty when it is the folder.
    let programDirectory: [String]
    let image: URL
    let packed: Date?
    var inserted = false
  }

  private let core: Core
  private let workDirectory: URL
  private let lock = NSLock()
  private var card: Card?

  init(core: Core = .live,
       workDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("HomebrewSD", isDirectory: true)) {
    self.core = core
    self.workDirectory = workDirectory
  }

  /// The folder that is the card of the program at `path`: its title's folder directly under the
  /// Homebrew folder. Nil for anything that is not an installed homebrew program.
  static func cardFolder(forProgram path: String, homebrewRoot: URL) -> URL? {
    let root = components(of: homebrewRoot.path)
    let program = components(of: path)
    // At least `<root>/<slug>/<program>`.
    guard program.count >= root.count + 2, program.starts(with: root) else { return nil }
    let slug = program[root.count]
    guard HomebrewName.isSafe(slug) else { return nil }
    return homebrewRoot.appendingPathComponent(slug, isDirectory: true)
  }

  /// Both sides spelled the same way: a path that does not resolve keeps `/private` while one
  /// that does loses it.
  private static func components(of path: String) -> [String] {
    var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    if resolved.hasPrefix(privatePrefix + "/") { resolved.removeFirst(privatePrefix.count) }
    return URL(fileURLWithPath: resolved).pathComponents
  }

  private static let privatePrefix = "/private"

  /// True from `prepare` until `finish`, when there is a card to deal with.
  var hasCard: Bool { lock.withLock { card != nil } }

  /// Packs the card for the program about to boot. Does nothing for other programs, and leaves
  /// the boot without a card if packing fails.
  func prepare(programPath: String?, homebrewRoot: URL?) {
    discard()
    guard let programPath, let homebrewRoot,
          let folder = Self.cardFolder(forProgram: programPath, homebrewRoot: homebrewRoot) else { return }
    let fm = FileManager.default
    let name = folder.lastPathComponent
    let image = workDirectory.appendingPathComponent(name + ".img")
    let staging = workDirectory.appendingPathComponent(name + ".card", isDirectory: true)
    try? fm.removeItem(at: image)
    try? fm.removeItem(at: staging)
    defer { try? fm.removeItem(at: staging) }
    let inside = Self.components(of: programPath).dropFirst(Self.components(of: folder.path).count)
    let programDirectory = Array(inside.dropLast())
    do {
      try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
      try Self.stage(folder, programDirectory: programDirectory, program: inside.last, at: staging)
    } catch {
      return
    }
    guard core.pack(staging, image) else {
      try? fm.removeItem(at: image)
      return
    }
    lock.withLock {
      card = Card(folder: folder, programDirectory: programDirectory, image: image, packed: Self.modified(image))
    }
  }

  /// Lays the card out at `staging`: the title's folder, plus what is in the program's own folder
  /// again at the root, where nothing of that name is there already. The program file itself is
  /// not repeated. On APFS the copies share their blocks with the originals.
  static func stage(_ folder: URL, programDirectory: [String], program: String?, at staging: URL) throws {
    let fm = FileManager.default
    try fm.copyItem(at: folder, to: staging)
    guard !programDirectory.isEmpty else { return }
    let own = programDirectory.reduce(staging) { $0.appendingPathComponent($1, isDirectory: true) }
    for name in try fm.contentsOfDirectory(atPath: own.path) where name != program {
      let atRoot = staging.appendingPathComponent(name)
      if !fm.fileExists(atPath: atRoot.path) {
        try fm.copyItem(at: own.appendingPathComponent(name), to: atRoot)
      }
    }
  }

  /// Puts the prepared card in slot B. A Wii program has the Wii's own SD card instead.
  func insert(isWii: Bool) {
    lock.withLock {
      guard !isWii, var prepared = card else { return }
      core.insert(prepared.image)
      prepared.inserted = true
      card = prepared
    }
  }

  /// Ends the run: takes the card out, copies back what the program changed, deletes the image.
  /// Call it once the core has shut down, which is when the image is complete on disk.
  func finish() {
    guard let used = lock.withLock({ () -> Card? in
      defer { card = nil }
      return card
    }) else { return }
    let fm = FileManager.default
    defer { try? fm.removeItem(at: used.image) }
    guard used.inserted else { return }
    core.remove()
    guard Self.modified(used.image) != used.packed else { return }
    let unpacked = workDirectory.appendingPathComponent(used.folder.lastPathComponent + ".unpacked", isDirectory: true)
    try? fm.removeItem(at: unpacked)
    defer { try? fm.removeItem(at: unpacked) }
    guard core.unpack(used.image, unpacked) else { return }
    Self.copyChanges(from: unpacked, into: used.folder, programDirectory: used.programDirectory)
  }

  /// A boot that never started: drop the image and leave slot B alone.
  private func discard() {
    guard let unused = lock.withLock({ () -> Card? in
      defer { card = nil }
      return card
    }) else { return }
    if unused.inserted { core.remove() }
    try? FileManager.default.removeItem(at: unused.image)
  }

  private static func modified(_ file: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
  }

  /// Copies every file of `card` that is new or different into `folder`, and returns where each
  /// went. A file at the card's root that came from the program's own folder goes back there.
  /// Nothing is deleted: a file the program removed from its card stays in the folder, so a bad
  /// run cannot lose the user's files.
  @discardableResult
  static func copyChanges(from card: URL, into folder: URL, programDirectory: [String] = []) -> [String] {
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: card, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    // Decide everything against the folder as it was packed, then copy: the card holds the
    // program folder's files twice, and only one of the two copies may have changed.
    var direct: [String: URL] = [:]
    var mirrored: [String: URL] = [:]
    for case let source as URL in walker {
      guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let relative = Array(source.pathComponents.suffix(walker.level))
      guard relative.allSatisfy(HomebrewName.isSafe) else { continue }
      let destination = relative.reduce(folder) { $0.appendingPathComponent($1) }
      if fm.contentsEqual(atPath: source.path, andPath: destination.path) { continue }
      let inProgramFolder = programDirectory + relative
      let original = inProgramFolder.reduce(folder) { $0.appendingPathComponent($1) }
      if programDirectory.isEmpty || fm.fileExists(atPath: destination.path) || !fm.fileExists(atPath: original.path) {
        direct[relative.joined(separator: "/")] = source
      } else if !fm.contentsEqual(atPath: source.path, andPath: original.path) {
        mirrored[inProgramFolder.joined(separator: "/")] = source
      }
    }
    // A file changed in its own place wins over the copy of it at the root.
    let plan = mirrored.merging(direct) { _, own in own }
    var changed: [String] = []
    for (path, source) in plan {
      let destination = path.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
      do {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
          _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
          try fm.moveItem(at: source, to: destination)
        }
        changed.append(path)
      } catch {
        continue
      }
    }
    return changed.sorted()
  }

  // MARK: - The emulation loop's entry points

  private static let shared = HomebrewSDCard()

  @objc(prepareForProgramAtPath:)
  static func prepare(programPath: String?) {
    shared.prepare(programPath: programPath, homebrewRoot: try? HomebrewPaths.root())
  }

  @objc(insertWithIsWii:)
  static func insert(isWii: Bool) {
    shared.insert(isWii: isWii)
  }

  @objc static var hasCard: Bool { shared.hasCard }

  @objc static func finish() {
    shared.finish()
  }
}
