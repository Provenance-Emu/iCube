// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One-time move of an existing install's Logger.ini from the old shipped default (every log type
/// enabled at Verbosity 4, WriteToWindow on) to the quiet default.
///
/// Why it matters: a log type that is enabled costs a fmt::vformat plus a timestamp format per
/// message on the emulation threads, even when no listener is attached, and an enabled window
/// listener counts as attached whether or not one is registered. The app copies Logger.ini into the
/// user folder only when none exists (`File::Copy` without overwrite), so installs made before the
/// default changed keep the old one.
///
/// Runs at launch (`DolphinCoreService`) after the bundled copy and before `UICommon::Init`, because
/// LogManager reads the file once, at init, and before the launch rewrite of Verbosity (which would
/// hide the old default). Works on the file text alone; touches nothing else. The debug menu's
/// console-logging mode does not need the file's types: the launch widens them at runtime.
@objc(ICubeLoggerIniMigration)
final class LoggerIniMigration: NSObject {
  /// Raise to run the migration once more on every install.
  static let currentVersion = 1
  static let versionKey = "logger_ini_v"
  /// Up to WARNING. LogLevel is not monotonic (NOTICE 1, ERROR 2, WARNING 3, INFO 4, DEBUG 5), so 3
  /// still carries every error and warning and drops INFO and DEBUG.
  @objc static let defaultVerbosity = 3
  static let oldDefaultVerbosity = 4

  /// The log types that stay enabled: the ones whose warnings and errors explain a failed boot, a
  /// disc read problem or a video fault. Everything else, notably OSREPORT, DSP mail, SI, EXI and PowerPC, is off.
  /// Keys are the short names Dolphin writes (LogManager.cpp).
  static let quietDefaultTypes: Set<String> = [
    "BOOT", "COMMON", "CORE", "DIO", "DSPHLE", "DSPLLE", "DVD", "Host GPU", "IOS", "IOS_DI",
    "IOS_ES", "IOS_FS", "MASTER", "MemCard Manager", "Video",
  ]

  /// The [Logs] keys the old shipped Logger.ini held, all True. Absent keys read as disabled, so a
  /// file that dropped some is not the old default even if every key left is True.
  static let oldDefaultTypes: Set<String> = [
    "ActionReplay", "AI", "Audio", "BOOT", "CI", "COMMON", "CONSOLE", "CORE", "CP", "DIO", "DSP",
    "DSPHLE", "DSPLLE", "DSPMails", "DVD", "EXI", "FileMon", "FRAMEDUMP", "GDB_STUB", "GP", "HLE",
    "Host GPU", "HSP", "IOS", "IOS_DI", "IOS_ES", "IOS_FS", "IOS_NET", "IOS_SD", "IOS_SSL",
    "IOS_STM", "IOS_USB", "IOS_WC24", "IOS_WFS", "IOS_WIIMOTE", "JIT", "MASTER", "MemCard Manager",
    "MI", "NETPLAY", "OSREPORT", "OSREPORT_HLE", "PE", "PI", "PowerPC", "RetroAchievements", "SI",
    "SP1", "SYMBOLS", "VI", "Video", "WII_IPC", "Wiimote",
  ]

  enum Decision: Equatable {
    /// Still the old default; rewrite it.
    case rewrite
    /// Changed by the user (or already the new default); leave it.
    case keepCustomized
    /// This install already ran the migration.
    case alreadyDone
    /// No Logger.ini (or it holds no [Logs] section).
    case nothingToMigrate
  }

  /// True when the file is what older builds shipped and nobody has touched since: a [Logs] section
  /// with every shipped type on (extra types only if off), Verbosity 4, WriteToWindow on and WriteToFile off. A Verbosity above 4 is a
  /// deliberate choice (the debug menu stores it), so it counts as customized.
  static func looksLikeOldDefault(_ text: String) -> Bool {
    let parsed = parse(text)
    // Every shipped type present and on. LogManager::SaveSettings writes every LogType at shutdown, so
    // an untouched install also carries the types the file never listed, saved as False; those match
    // an absent key (off) and don't make the file customized. Any other extra key turned on does.
    guard oldDefaultTypes.allSatisfy({ isTrue(parsed.logs[$0] ?? "") }) else { return false }
    let extras = parsed.logs.filter { !oldDefaultTypes.contains($0.key) }
    guard extras.allSatisfy({ !isTrue($0.value) }) else { return false }
    // WriteToConsole is ignored: earlier launches rewrote it themselves. WriteToFile shipped False, so
    // a True there is the user's choice to log to a file.
    return parsed.options["Verbosity"].flatMap { Int($0) } == oldDefaultVerbosity
      && isTrue(parsed.options["WriteToWindow"] ?? "")
      && !isTrue(parsed.options["WriteToFile"] ?? "")
  }

  static func decide(text: String?, recordedVersion: Int, version: Int = currentVersion) -> Decision {
    if recordedVersion >= version { return .alreadyDone }
    guard let text, !parse(text).logs.isEmpty else { return .nothingToMigrate }
    guard looksLikeOldDefault(text) else { return .keepCustomized }
    return .rewrite
  }

  /// The text with the quiet default applied. Lines and sections the migration does not own
  /// (comments, other keys) are kept as they are.
  static func quietDefault(from text: String) -> String {
    var section = ""
    let lines = splitLines(text).map { line -> String in
      if let name = sectionName(line) {
        section = name
        return line
      }
      guard let (key, _) = keyValue(line) else { return line }
      switch (section, key) {
      case ("Logs", _):
        return "\(key) = \(quietDefaultTypes.contains(key) ? "True" : "False")"
      case ("Options", "Verbosity"):
        return "\(key) = \(defaultVerbosity)"
      case ("Options", "WriteToWindow"):
        return "\(key) = False"
      default:
        return line
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Reads `iniPath`, rewrites it when `decide` says so, and records the version once it has dealt
  /// with the file (a failed write is retried at the next launch). Returns the decision taken.
  @discardableResult
  static func run(iniPath: String, defaults: UserDefaults, version: Int = currentVersion) -> Decision {
    let text = try? String(contentsOfFile: iniPath, encoding: .utf8)
    let decision = decide(text: text, recordedVersion: defaults.integer(forKey: versionKey), version: version)
    switch decision {
    case .rewrite:
      guard let text else { return decision }
      do {
        try quietDefault(from: text).write(toFile: iniPath, atomically: true, encoding: .utf8)
        defaults.set(version, forKey: versionKey)
        NSLog("[LoggerIniMigration] Logger.ini moved to the quiet default (v%ld)", version)
      } catch {
        NSLog("[LoggerIniMigration] could not rewrite Logger.ini: %@; retrying next launch", error.localizedDescription)
      }
    case .keepCustomized:
      defaults.set(version, forKey: versionKey)
    case .alreadyDone, .nothingToMigrate:
      break
    }
    return decision
  }

  @objc(runAtLaunchWithIniPath:)
  static func runAtLaunch(iniPath: String) {
    run(iniPath: iniPath, defaults: .standard)
  }

  // MARK: - Launch options

  /// The options the launch forces into [Options] whatever the file holds: console output follows
  /// the debug menu, Verbosity is the menu's value, and WriteToWindow is off. No window listener
  /// exists when LogManager initializes (the debug bench registers and enables its own at runtime),
  /// and a True here, from the old default or a saved bench run, would make every enabled log line
  /// count as having a listener.
  static func launchOptions(consoleEnabled: Bool, verbosity: Int) -> [(key: String, value: String)] {
    [("WriteToConsole", consoleEnabled ? "True" : "False"), ("Verbosity", String(verbosity)), ("WriteToWindow", "False")]
  }

  /// The text with `values` set inside [Options] only: a matching line there is replaced, a key
  /// that is missing is added at the end of the section (the section is added if absent), and the
  /// same text in a comment or in another section is left alone.
  static func settingOptions(_ values: [(key: String, value: String)], in text: String) -> String {
    var lines = splitLines(text)
    var handled = Set<String>()
    var section = ""
    var optionsEnd: Int? // the index just after the last non-blank line of [Options]
    for index in lines.indices {
      if let name = sectionName(lines[index]) {
        section = name
        if name == "Options" { optionsEnd = index + 1 }
        continue
      }
      guard section == "Options" else { continue }
      if let (key, _) = keyValue(lines[index]), let match = values.first(where: { $0.key == key }) {
        lines[index] = "\(key) = \(match.value)"
        handled.insert(key)
      }
      if !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { optionsEnd = index + 1 }
    }
    let missing = values.filter { !handled.contains($0.key) }.map { "\($0.key) = \($0.value)" }
    guard !missing.isEmpty else { return lines.joined(separator: "\n") }
    if let end = optionsEnd {
      lines.insert(contentsOf: missing, at: end)
    } else {
      if lines.last == "" { lines.removeLast() }
      lines += ["[Options]"] + missing + [""]
    }
    return lines.joined(separator: "\n")
  }

  /// Applies `launchOptions` to the file at `iniPath` (no file, nothing to do). Runs at launch,
  /// before LogManager reads it.
  @objc(applyLaunchOptionsToIniPath:consoleEnabled:verbosity:)
  static func applyLaunchOptions(iniPath: String, consoleEnabled: Bool, verbosity: Int) {
    guard let text = try? String(contentsOfFile: iniPath, encoding: .utf8), !text.isEmpty else { return }
    let updated = settingOptions(launchOptions(consoleEnabled: consoleEnabled, verbosity: verbosity), in: text)
    guard updated != text else { return }
    do {
      try updated.write(toFile: iniPath, atomically: true, encoding: .utf8)
    } catch {
      NSLog("[LoggerIniMigration] could not write the launch options to Logger.ini: %@", error.localizedDescription)
    }
  }

  // MARK: - Minimal INI reading

  /// The lines of `text` whatever its endings (LF, CRLF or CR). The rewrites join with "\n", so a
  /// CRLF file comes out with consistent LF endings and no stray "\r" on any value; Dolphin's
  /// IniFile reads both.
  private static func splitLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
  }

  private static func isTrue(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespaces).lowercased() == "true"
  }

  private static func sectionName(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
    return String(trimmed.dropFirst().dropLast())
  }

  private static func keyValue(_ line: String) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
          let eq = trimmed.firstIndex(of: "=") else { return nil }
    let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
    let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    return key.isEmpty ? nil : (key, value)
  }

  private static func parse(_ text: String) -> (logs: [String: String], options: [String: String]) {
    var logs: [String: String] = [:]
    var options: [String: String] = [:]
    var section = ""
    for line in splitLines(text) {
      if let name = sectionName(line) {
        section = name
      } else if let (key, value) = keyValue(line) {
        if section == "Logs" { logs[key] = value } else if section == "Options" { options[key] = value }
      }
    }
    return (logs, options)
  }
}
