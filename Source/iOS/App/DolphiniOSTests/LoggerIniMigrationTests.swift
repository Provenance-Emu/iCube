// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// The Logger.ini migration: which files count as the old shipped default (rewritten), which are
/// the user's own (left alone), what the rewrite produces, and that a second pass changes nothing.
final class LoggerIniMigrationTests: XCTestCase {
  /// The key set the old shipped file held; the migration only trusts a file with exactly these.
  private let types = LoggerIniMigration.oldDefaultTypes.sorted()

  private func ini(types allTypes: [String: Bool], verbosity: Int, window: Bool, console: Bool = true) -> String {
    var lines = ["[Logs]"]
    for key in allTypes.keys.sorted() { lines.append("\(key) = \(allTypes[key]! ? "True" : "False")") }
    lines += ["[Options]", "Verbosity = \(verbosity)", "WriteToConsole = \(console ? "True" : "False")",
              "WriteToFile = False", "WriteToWindow = \(window ? "True" : "False")"]
    return lines.joined(separator: "\n") + "\n"
  }

  private var oldDefault: String {
    ini(types: Dictionary(uniqueKeysWithValues: types.map { ($0, true) }), verbosity: 4, window: true)
  }

  private func value(_ key: String, in text: String) -> String? {
    text.components(separatedBy: "\n").compactMap { line -> String? in
      let parts = line.components(separatedBy: " = ")
      return parts.count == 2 && parts[0] == key ? parts[1] : nil
    }.first
  }

  // MARK: - Decision

  func testTheOldShippedDefaultIsRewritten() {
    XCTAssertTrue(LoggerIniMigration.looksLikeOldDefault(oldDefault))
    XCTAssertEqual(LoggerIniMigration.decide(text: oldDefault, recordedVersion: 0), .rewrite)
  }

  func testWindowsLineEndingsAndPaddingStillMatch() {
    let crlf = oldDefault.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: " = ", with: "  =  ")
    XCTAssertEqual(LoggerIniMigration.decide(text: crlf, recordedVersion: 0), .rewrite)
  }

  func testCRLFFilesAreRewrittenWithConsistentLineEndings() {
    let crlf = oldDefault.replacingOccurrences(of: "\n", with: "\r\n")
    XCTAssertTrue(LoggerIniMigration.looksLikeOldDefault(crlf))
    let out = LoggerIniMigration.quietDefault(from: crlf)
    XCTAssertFalse(out.contains("\r"))
    XCTAssertEqual(out, LoggerIniMigration.quietDefault(from: oldDefault))
    // A file with a CR on the last value (no trailing newline) is still classified correctly.
    XCTAssertTrue(LoggerIniMigration.looksLikeOldDefault(crlf.trimmingCharacters(in: .newlines) + "\r"))
    let options = launch(crlf)
    XCTAssertFalse(options.contains("\r"))
    XCTAssertEqual(value("WriteToWindow", in: options), "False")
    XCTAssertEqual(value("BOOT", in: options), "True")
  }

  func testShutdownAddedFalseKeysStillMigrate() {
    // LogManager::SaveSettings writes every LogType at shutdown; types the old file never listed come
    // back as False. That is still the untouched old default.
    var saved = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    saved["SI_AMBB"] = false
    saved["NEWTYPE"] = false
    XCTAssertTrue(LoggerIniMigration.looksLikeOldDefault(ini(types: saved, verbosity: 4, window: true)))
    // An extra type the user turned on is a customization.
    saved["NEWTYPE"] = true
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(ini(types: saved, verbosity: 4, window: true)))
  }

  func testNumericTrueCountsAsOnLikeDolphin() {
    XCTAssertTrue(LoggerIniMigration.isTrue("1"))
    XCTAssertTrue(LoggerIniMigration.isTrue("1.0"))
    XCTAssertTrue(LoggerIniMigration.isTrue(" TRUE "))
    XCTAssertFalse(LoggerIniMigration.isTrue("0"))
    XCTAssertFalse(LoggerIniMigration.isTrue("False"))
    // File logging turned on as `1`, or an extra type turned on as `1`, is a customization.
    let fileOn = oldDefault.replacingOccurrences(of: "WriteToFile = False", with: "WriteToFile = 1")
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(fileOn))
    var saved = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    saved["SI_CARD"] = false
    let extraOn = ini(types: saved, verbosity: 4, window: true).replacingOccurrences(of: "SI_CARD = False", with: "SI_CARD = 1")
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(extraOn))
  }

  func testFileLoggingTurnedOnIsKept() {
    // WriteToFile shipped False; turning it on is a deliberate choice the migration must keep.
    let text = oldDefault.replacingOccurrences(of: "WriteToFile = False", with: "WriteToFile = True")
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(text))
    XCTAssertEqual(LoggerIniMigration.decide(text: text, recordedVersion: 0), .keepCustomized)
  }

  func testACustomizedFileIsKept() {
    var some = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    some["OSREPORT"] = false
    XCTAssertEqual(LoggerIniMigration.decide(text: ini(types: some, verbosity: 4, window: true), recordedVersion: 0), .keepCustomized)
    // A removed key reads as disabled, so a file that dropped one is customized even though every key
    // left is True.
    var dropped = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    dropped["OSREPORT"] = nil
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(ini(types: dropped, verbosity: 4, window: true)))
    XCTAssertEqual(LoggerIniMigration.decide(text: ini(types: dropped, verbosity: 4, window: true), recordedVersion: 0),
                   .keepCustomized)
    // An extra key (a newer build saved SI_AMBB and friends) is not the shipped file either.
    var extra = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    extra["SI_AMBB"] = true
    XCTAssertEqual(LoggerIniMigration.decide(text: ini(types: extra, verbosity: 4, window: true), recordedVersion: 0),
                   .keepCustomized)
    let all = Dictionary(uniqueKeysWithValues: types.map { ($0, true) })
    // Verbosity above 4 is what the debug menu stores for a deliberate choice.
    XCTAssertEqual(LoggerIniMigration.decide(text: ini(types: all, verbosity: 5, window: true), recordedVersion: 0), .keepCustomized)
    XCTAssertEqual(LoggerIniMigration.decide(text: ini(types: all, verbosity: 4, window: false), recordedVersion: 0), .keepCustomized)
  }

  func testTheNewDefaultIsNotRewrittenAgain() {
    let quiet = LoggerIniMigration.quietDefault(from: oldDefault)
    XCTAssertEqual(LoggerIniMigration.decide(text: quiet, recordedVersion: 0), .keepCustomized)
  }

  func testAlreadyMigratedInstallsAreSkippedWhateverTheFileHolds() {
    XCTAssertEqual(LoggerIniMigration.decide(text: oldDefault, recordedVersion: LoggerIniMigration.currentVersion), .alreadyDone)
  }

  func testNothingToMigrateWithoutAFileOrLogsSection() {
    XCTAssertEqual(LoggerIniMigration.decide(text: nil, recordedVersion: 0), .nothingToMigrate)
    XCTAssertEqual(LoggerIniMigration.decide(text: "[Options]\nVerbosity = 4\n", recordedVersion: 0), .nothingToMigrate)
    XCTAssertEqual(LoggerIniMigration.decide(text: "", recordedVersion: 0), .nothingToMigrate)
  }

  // MARK: - Rewrite

  func testRewriteKeepsOnlyTheQuietTypesAndDropsVerbosityAndWindow() {
    let text = LoggerIniMigration.quietDefault(from: oldDefault)
    for key in types {
      let expected = LoggerIniMigration.quietDefaultTypes.contains(key) ? "True" : "False"
      XCTAssertEqual(value(key, in: text), expected, key)
    }
    XCTAssertEqual(value("OSREPORT", in: text), "False")
    XCTAssertEqual(value("BOOT", in: text), "True")
    XCTAssertEqual(value("Verbosity", in: text), "3")
    XCTAssertEqual(value("WriteToWindow", in: text), "False")
    // Not the migration's to change.
    XCTAssertEqual(value("WriteToConsole", in: text), "True")
    XCTAssertEqual(value("WriteToFile", in: text), "False")
  }

  func testRewriteIsIdempotent() {
    let once = LoggerIniMigration.quietDefault(from: oldDefault)
    XCTAssertEqual(LoggerIniMigration.quietDefault(from: once), once)
  }

  func testRewriteKeepsCommentsAndOtherSections() {
    let text = "# note\n[Logs]\nBOOT = True\nSI = True\n[Other]\nSI = True\n[Options]\nVerbosity = 4\nWriteToWindow = True\n"
    let out = LoggerIniMigration.quietDefault(from: text)
    XCTAssertTrue(out.hasPrefix("# note\n"))
    XCTAssertEqual(out, "# note\n[Logs]\nBOOT = True\nSI = False\n[Other]\nSI = True\n[Options]\nVerbosity = 3\nWriteToWindow = False\n")
  }

  func testTheShippedDefaultIsAlreadyTheQuietDefault() throws {
    let url = try XCTUnwrap(Bundle(for: LoggerIniMigration.self).url(forResource: "Logger", withExtension: "ini"))
    let shipped = try String(contentsOf: url, encoding: .utf8)
    XCTAssertEqual(LoggerIniMigration.quietDefault(from: shipped), shipped)
    XCTAssertEqual(value("Verbosity", in: shipped), String(LoggerIniMigration.defaultVerbosity))
    XCTAssertEqual(value("WriteToWindow", in: shipped), "False")
    XCTAssertFalse(LoggerIniMigration.looksLikeOldDefault(shipped))
  }

  // MARK: - Launch options

  private func launch(_ text: String, console: Bool = false, verbosity: Int = 3) -> String {
    LoggerIniMigration.settingOptions(LoggerIniMigration.launchOptions(consoleEnabled: console, verbosity: verbosity), in: text)
  }

  func testLaunchOptionsSetTheThreeKeys() {
    let out = launch(oldDefault, console: true, verbosity: 5)
    XCTAssertEqual(value("WriteToConsole", in: out), "True")
    XCTAssertEqual(value("Verbosity", in: out), "5")
    XCTAssertEqual(value("WriteToWindow", in: out), "False")
    XCTAssertEqual(value("WriteToFile", in: out), "False")
    XCTAssertEqual(value("BOOT", in: out), "True")
  }

  func testLaunchOptionsOnlyTouchTheOptionsSection() {
    // The same key text in a comment and in another section, both before the real [Options] key.
    let text = "# WriteToWindow = True and Verbosity = 4\n[Notes]\nWriteToWindow = True\nVerbosity = 4\n"
      + "[Logs]\nBOOT = True\n[Options]\nVerbosity = 4\nWriteToConsole = True\nWriteToWindow = True\n"
    let out = launch(text)
    XCTAssertEqual(out, "# WriteToWindow = True and Verbosity = 4\n[Notes]\nWriteToWindow = True\nVerbosity = 4\n"
      + "[Logs]\nBOOT = True\n[Options]\nVerbosity = 3\nWriteToConsole = False\nWriteToWindow = False\n")
  }

  func testLaunchOptionsAddMissingKeysInsideOptions() {
    let out = launch("[Options]\nVerbosity = 4\n[Logs]\nBOOT = True\n")
    XCTAssertEqual(out, "[Options]\nVerbosity = 3\nWriteToConsole = False\nWriteToWindow = False\n[Logs]\nBOOT = True\n")
    XCTAssertEqual(launch("[Logs]\nBOOT = True\n"),
                   "[Logs]\nBOOT = True\n[Options]\nWriteToConsole = False\nVerbosity = 3\nWriteToWindow = False\n")
  }

  func testLaunchOptionsAreIdempotent() {
    let once = launch(oldDefault)
    XCTAssertEqual(launch(once), once)
  }

  // MARK: - On disk

  private let suiteName = "LoggerIniMigrationTests"
  private var defaults: UserDefaults!
  private var path: String!

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suiteName)
    defaults = UserDefaults(suiteName: suiteName)
    path = NSTemporaryDirectory() + "LoggerIniMigrationTests-\(UUID().uuidString).ini"
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(atPath: path)
    super.tearDown()
  }

  func testRunRewritesOnceThenLeavesTheFileAlone() throws {
    try oldDefault.write(toFile: path, atomically: true, encoding: .utf8)
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .rewrite)
    let migrated = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertEqual(migrated, LoggerIniMigration.quietDefault(from: oldDefault))
    XCTAssertEqual(defaults.integer(forKey: LoggerIniMigration.versionKey), LoggerIniMigration.currentVersion)

    // The user turns a type back on; a second launch must not undo it.
    let edited = migrated.replacingOccurrences(of: "OSREPORT = False", with: "OSREPORT = True")
    try edited.write(toFile: path, atomically: true, encoding: .utf8)
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .alreadyDone)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), edited)
  }

  func testRunLeavesACustomizedFileUntouchedAndRecordsTheVersion() throws {
    let custom = oldDefault.replacingOccurrences(of: "SI = True", with: "SI = False")
    try custom.write(toFile: path, atomically: true, encoding: .utf8)
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .keepCustomized)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), custom)
    XCTAssertEqual(defaults.integer(forKey: LoggerIniMigration.versionKey), LoggerIniMigration.currentVersion)
  }

  func testRunRewritesEvenWhileConsoleLoggingIsOn() throws {
    // The launch widens the types at runtime for the console mode, so the file is migrated anyway;
    // the launch rewrite of Verbosity must not be able to hide the old default from a later pass.
    try oldDefault.write(toFile: path, atomically: true, encoding: .utf8)
    defaults.set(true, forKey: "logger_console_enabled")
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .rewrite)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), LoggerIniMigration.quietDefault(from: oldDefault))
  }

  func testRunLeavesAFileThatDroppedAKeyUntouched() throws {
    let dropped = oldDefault.replacingOccurrences(of: "OSREPORT = True\n", with: "")
    try dropped.write(toFile: path, atomically: true, encoding: .utf8)
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .keepCustomized)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), dropped)
  }

  func testApplyLaunchOptionsRewritesTheFileOnDisk() throws {
    try oldDefault.write(toFile: path, atomically: true, encoding: .utf8)
    LoggerIniMigration.applyLaunchOptions(iniPath: path, consoleEnabled: false, verbosity: 3)
    let out = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertEqual(value("WriteToWindow", in: out), "False")
    XCTAssertEqual(value("Verbosity", in: out), "3")
    // No file: nothing is created.
    let missing = path + ".missing"
    LoggerIniMigration.applyLaunchOptions(iniPath: missing, consoleEnabled: false, verbosity: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
  }

  func testRunWithoutAFileDoesNothing() {
    XCTAssertEqual(LoggerIniMigration.run(iniPath: path, defaults: defaults), .nothingToMigrate)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertEqual(defaults.integer(forKey: LoggerIniMigration.versionKey), 0)
  }
}
