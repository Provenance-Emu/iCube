import Foundation
import SwiftUI

/// Simple preset model
struct ShaderPreset: Identifiable, Equatable {
  let id: URL
  let name: String
}

extension ShaderPreset {
  /// The preset's containing folder name, used as a lightweight grouping label
  /// in the pause-menu quick picker (e.g. "CRT", "Smoothing").
  var category: String {
    let parent = id.deletingLastPathComponent().lastPathComponent
    return parent.isEmpty ? L("Shader") : parent
  }
}

/// Discovers shader preset files. Looks in app bundle and user folder recursively for compiled containers
final class ShaderLibrary {
  /// Single source of truth for turning an absolute on-disk preset path into the
  /// bundle-relative form persisted to `shader_preset_path` (so a reinstall with a
  /// different bundle UUID doesn't orphan the stored preset). Previously reimplemented
  /// at three separate call sites (`ShaderPickerView.normalizedPath`, its `allItems`
  /// loop, and `ShaderSettingsView.onChange(of:)`), which is exactly the kind of drift
  /// that lets one of them fall out of sync with the others.
  static func normalizedPath(_ absPath: String) -> String {
    let bundleBase = Bundle.main.bundleURL.path
    if absPath.hasPrefix(bundleBase), let dotApp = absPath.range(of: ".app/") {
      return String(absPath[dotApp.upperBound...])
    }
    return absPath
  }

  static func discoverPresets() -> [ShaderPreset] {
    var results: [ShaderPreset] = []
    let fm = FileManager.default
    var visited: Set<URL> = []
    func addZip(_ url: URL) { results.append(.init(id: url, name: url.deletingPathExtension().lastPathComponent)) }
    func addDir(_ url: URL) { results.append(.init(id: url, name: url.lastPathComponent)) }
    func scan(_ url: URL) {
      guard visited.insert(url).inserted else { return }
      if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
        for case let f as URL in e {
          let last = f.lastPathComponent.lowercased()
          if last.hasSuffix(".oecompiledshader") { addZip(f) } else if last == "shader.json" { addDir(f.deletingLastPathComponent()) }
        }
      }
    }
    if let res = Bundle.main.resourceURL { scan(res) }
    let userFolder = UserFolderUtil.getUserFolder()
    let u = URL(fileURLWithPath: userFolder).appendingPathComponent("Shaders", isDirectory: true)
    if fm.fileExists(atPath: u.path) { scan(u) }

    // De-dup directories or zips with same path
    let unique = Dictionary(grouping: results, by: { $0.id }).compactMap { $0.value.first }
    return unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

/// Reusable picker usable from Settings or in-game UI
struct ShaderPickerView: View {
  @Binding var selectedPresetPath: String?
  @State private var presets: [ShaderPreset] = []
  @State private var favorites: [String] = UserDefaults.standard.stringArray(forKey: "shader_favorites") ?? []
  @State private var mru: [String] = UserDefaults.standard.stringArray(forKey: "shader_mru") ?? []
  @State private var searchText: String = ""

  private func normalizedPath(_ absPath: String) -> String {
    ShaderLibrary.normalizedPath(absPath)
  }

  private func toggleFavorite(_ norm: String) {
    var set = Set(favorites)
    if set.contains(norm) { set.remove(norm) } else { set.insert(norm) }
    favorites = Array(set)
    UserDefaults.standard.set(favorites, forKey: "shader_favorites")
  }

  private func pushMRU(_ norm: String) {
    var list = mru.filter { $0 != norm }
    list.insert(norm, at: 0)
    if list.count > 10 { list = Array(list.prefix(10)) }
    mru = list
    UserDefaults.standard.set(mru, forKey: "shader_mru")
  }

  /// Returns true if the preset matches the current search filter
  private func matchesSearch(_ preset: ShaderPreset) -> Bool {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return true }
    let needle = q.lowercased()
    let name = preset.name.lowercased()
    let path = normalizedPath(preset.id.path).lowercased()
    return name.contains(needle) || path.contains(needle)
  }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        SelectRow(label: L("None"), checked: selectedPresetPath == nil) {
          selectedPresetPath = nil
          UserDefaults.standard.removeObject(forKey: "shader_preset_path")
          NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
        }
        .id("NONE")
        // Favorites
        let favItems = presets.filter(matchesSearch).filter { favorites.contains(normalizedPath($0.id.path)) }
        if !favorites.isEmpty && !favItems.isEmpty {
          Section(header: Text(L("Favorites"))) {
            ForEach(favItems) { preset in
              let absPath = preset.id.path
              let normalized = normalizedPath(absPath)
              HStack {
                SelectRow(label: preset.name, checked: (selectedPresetPath == normalized) || (selectedPresetPath == absPath)) {
                  selectedPresetPath = normalized
                  NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
                  DOLShaderPostProcessor.shared.applyPresetPath(normalized)
                  pushMRU(normalized)
                }
                Spacer()
                Button(action: { toggleFavorite(normalized) }) {
                  Image(systemName: "star.fill").foregroundColor(.yellow)
                }
              }
            }
          }
        }
        // Recently used
        let recentItems = presets.filter(matchesSearch).filter { mru.contains(normalizedPath($0.id.path)) }
        if !mru.isEmpty && !recentItems.isEmpty {
          Section(header: Text(L("Recently Used"))) {
            ForEach(recentItems) { preset in
              let absPath = preset.id.path
              let normalized = normalizedPath(absPath)
              HStack {
                SelectRow(label: preset.name, checked: (selectedPresetPath == normalized) || (selectedPresetPath == absPath)) {
                  selectedPresetPath = normalized
                  NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
                  DOLShaderPostProcessor.shared.applyPresetPath(normalized)
                  pushMRU(normalized)
                }
                Spacer()
                Button(action: { toggleFavorite(normalized) }) {
                  Image(systemName: favorites.contains(normalized) ? "star.fill" : "star").foregroundColor(.yellow)
                }
              }
            }
          }
        }
        let allItems = presets.filter(matchesSearch)
        ForEach(allItems) { preset in
          Group {
            let absPath = preset.id.path
            let normalized = ShaderLibrary.normalizedPath(absPath)
            HStack {
              SelectRow(label: preset.name, checked: (selectedPresetPath == normalized) || (selectedPresetPath == absPath)) {
                selectedPresetPath = normalized
                NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
                // Immediate apply while running
                DOLShaderPostProcessor.shared.applyPresetPath(normalized)
                pushMRU(normalized)
              }
              Spacer()
              Button(action: { toggleFavorite(normalized) }) {
                Image(systemName: favorites.contains(normalized) ? "star.fill" : "star")
                  .foregroundColor(.yellow)
              }
            }
            .id(preset.id)
          }
        }
      }
      #if !os(tvOS)
      .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(L("Search Shaders")))
      #else
      .searchable(text: $searchText, placement: .automatic, prompt: Text(L("Search Shaders")))
      #endif
      .navigationTitle(L("Shaders"))
      .onAppear {
        presets = ShaderLibrary.discoverPresets()
        favorites = UserDefaults.standard.stringArray(forKey: "shader_favorites") ?? []
        mru = UserDefaults.standard.stringArray(forKey: "shader_mru") ?? []
        /// Auto-scroll to the currently selected shader (or None)
        DispatchQueue.main.async {
          scrollToSelected(proxy: proxy)
        }
      }
    }
  }

  /// Scrolls to the selected preset if present; otherwise to None
  private func scrollToSelected(proxy: ScrollViewProxy) {
    let bundleBase = Bundle.main.bundleURL.path
    let targetId: AnyHashable
    if let sel = selectedPresetPath {
      let abs: String
      if sel.hasPrefix(bundleBase) { abs = sel } else { abs = Bundle.main.bundleURL.appendingPathComponent(sel).path }
      if let match = presets.first(where: { $0.id.path == abs }) {
        targetId = match.id
      } else {
        targetId = "NONE"
      }
    } else {
      targetId = "NONE"
    }
    proxy.scrollTo(targetId, anchor: .center)
  }
}

/// Full settings page with enable toggle and picker.
///
/// D16: the debug/diagnostic toggles that used to live in a "Debug" section here
/// (checkerboard/bypass/forced-binding hacks used to bring up shader pipeline bugs)
/// moved to `ShaderDeveloperDebugView`, which only exists in `#if DEBUG` builds — see
/// that file for which keys are dead code (deleted outright) vs. still read by
/// `FilterChain`/`ShaderPostProcessor` (gated there too, so a stray `true` from an
/// old debug build can't linger into a Release one). "Flip vertically" and "Enable
/// pre-copy (compat)" are real device-compatibility knobs rather than engineering
/// diagnostics, so they stayed user-visible in the "Advanced" section below instead
/// of moving behind `#if DEBUG`.
struct ShaderSettingsView: View {
  @State private var enabled: Bool = false
  @State private var presetPath: String?
  @State private var flipVertically: Bool = false
  @AppStorage("shader_precopy_enabled") private var compatPreCopyEnabled: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("Post-Processing Shader")), footer: Text(L("Note: Some shaders can reduce performance. Heavier effects may cause slowdowns depending on your device."))) {
        Toggle(L("Enable Shader"), isOn: $enabled)
          .onChange(of: enabled) {
            UserDefaults.standard.set($0, forKey: "shader_enabled")
            NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
          }
        NavigationLink(destination: ShaderPickerView(selectedPresetPath: $presetPath)) {
          HStack {
            Text(L("Preset"))
            Spacer()
            Text(presetLabel)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(!enabled)
      }

      Section(header: Text(L("Advanced")), footer: Text(L("Compatibility options for specific devices or shaders. Most people never need these."))) {
        Toggle(L("Flip vertically"), isOn: $flipVertically)
          .onChange(of: flipVertically) {
            UserDefaults.standard.set($0, forKey: "shader_flip_vertical")
            NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
          }
        Toggle(L("Enable pre-copy (compat)"), isOn: $compatPreCopyEnabled)
      }

      #if DEBUG
      Section(header: Text(L("Developer"))) {
        NavigationLink(L("Shader Debug Tools"), destination: ShaderDeveloperDebugView())
      }
      #endif
    }
    .navigationTitle(L("Shaders"))
    .onAppear { sync() }
    .onChange(of: presetPath) { p in
      if let p {
        let pathToStore = ShaderLibrary.normalizedPath(p)
        UserDefaults.standard.set(pathToStore, forKey: "shader_preset_path")
      } else {
        UserDefaults.standard.removeObject(forKey: "shader_preset_path")
      }
      NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      // Immediate apply while running
      DOLShaderPostProcessor.shared.applyPresetPath(p)
    }
  }

  private var presetLabel: String {
    guard enabled else { return L("Disabled") }
    guard let presetPath else { return L("None") }
    return URL(fileURLWithPath: presetPath).deletingPathExtension().lastPathComponent
  }

  private func sync() {
    enabled = UserDefaults.standard.bool(forKey: "shader_enabled")
    presetPath = UserDefaults.standard.string(forKey: "shader_preset_path")
    flipVertically = (UserDefaults.standard.object(forKey: "shader_flip_vertical") as? Bool) ?? false
  }
}

// MARK: - Live Parameter Editor

struct ShaderParameterEditor: View {
  @State private var params: [Compiled.Parameter] = []
  @State private var values: [Int: CGFloat] = [:]
  @State private var currentPresetPath: String? = UserDefaults.standard.string(forKey: "shader_preset_path")
  @State private var isLoadingPreset: Bool = false
  @State private var groups: [(id: String, title: String, indices: [Int])] = []
  @State private var selectedGroup: String = "ALL"
  @State private var lastLoadedPresetToken: String?

  var body: some View {
    List {
      if params.isEmpty {
        if isLoadingPreset {
          DolphinLoadingView(message: L("Loading preset…"))
        } else {
          Text(L("No adjustable parameters in the current shader")).foregroundStyle(.secondary)
        }
      } else {
        if groups.count > 1 {
          Picker(L("Group"), selection: $selectedGroup) {
            ForEach(groups, id: \.id) { g in
              Text(g.title).tag(g.id)
            }
          }
          .pickerStyle(.segmented)
        }
        ForEach(params, id: \.index) { p in
          if shouldShowParam(p.index) {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(p.desc)
                Spacer()
                Text(String(format: "%.3f", values[p.index] ?? p.initialCGFloat))
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
                Button(L("Reset")) {
                  values[p.index] = p.initialCGFloat
                  DOLShaderPostProcessor.shared.setValue(p.initialCGFloat, forParameterIndex: p.index)
                }
                .buttonStyle(.bordered)
                #if os(iOS)
                  .controlSize(.small)
                #endif
              }
              #if os(iOS)
              Slider(value: Binding(
                get: {
                  let rawMin = p.minimumCGFloat
                  let rawMax = p.maximumCGFloat
                  let minVal = rawMin.isFinite ? rawMin : 0
                  var width = (rawMax.isFinite ? rawMax : minVal) - minVal
                  if !width.isFinite { width = 0 }
                  // Ensure strictly positive width
                  let minWidth: CGFloat = 0.01
                  if width <= 0 { width = minWidth }
                  let maxVal = minVal + width
                  var v = values[p.index] ?? p.initialCGFloat
                  if !v.isFinite { v = minVal }
                  return max(min(v, maxVal), minVal)
                },
                set: { newVal in
                  let rawMin = p.minimumCGFloat
                  let rawMax = p.maximumCGFloat
                  let minVal = rawMin.isFinite ? rawMin : 0
                  var width = (rawMax.isFinite ? rawMax : minVal) - minVal
                  if !width.isFinite { width = 0 }
                  let minWidth: CGFloat = 0.01
                  if width <= 0 { width = minWidth }
                  let maxVal = minVal + width
                  let clamped = max(min(newVal.isFinite ? newVal : minVal, maxVal), minVal)
                  values[p.index] = clamped
                  DOLShaderPostProcessor.shared.setValue(clamped, forParameterIndex: p.index)
                }
              ), in: { () -> ClosedRange<CGFloat> in
                let rawMin = p.minimumCGFloat
                let rawMax = p.maximumCGFloat
                let minVal = rawMin.isFinite ? rawMin : 0
                var width = (rawMax.isFinite ? rawMax : minVal) - minVal
                if !width.isFinite { width = 0 }
                let minWidth: CGFloat = 0.01
                if width <= 0 { width = minWidth }
                let maxVal = minVal + width
                return minVal ... maxVal
              }(), step: { () -> CGFloat in
                let rawMin = p.minimumCGFloat
                let rawMax = p.maximumCGFloat
                let minVal = rawMin.isFinite ? rawMin : 0
                var width = (rawMax.isFinite ? rawMax : minVal) - minVal
                if !width.isFinite { width = 0 }
                let minWidth: CGFloat = 0.01
                if width <= 0 { width = minWidth }
                let rawStep = p.stepCGFloat
                var step = (rawStep.isFinite && rawStep > 0) ? rawStep : (width / 100)
                let minStep = width / 1000
                if !step.isFinite || step <= 0 { step = minStep }
                // Cap overly large steps to keep at least two steps in range
                if step >= width { step = width / 100 }
                // Final guard
                return max(step, minStep)
              }())
              #else
              // tvOS: Use TVFloatStepper for better UX
              TVFloatStepper(
                value: Binding(
                  get: { values[p.index] ?? p.initialCGFloat },
                  set: { newVal in
                    values[p.index] = newVal
                    DOLShaderPostProcessor.shared.setValue(newVal, forParameterIndex: p.index)
                  }
                ),
                range: p.minimumCGFloat ... p.maximumCGFloat,
                step: p.stepCGFloat
              )
              #endif
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .navigationTitle(L("Parameters"))
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(L("Reset All")) {
          for p in params {
            values[p.index] = p.initialCGFloat
            DOLShaderPostProcessor.shared.setValue(p.initialCGFloat, forParameterIndex: p.index)
          }
        }
      }
    }
    .onAppear { loadParams() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLShaderPresetDidLoad"))) { _ in loadParams() }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLShaderSettingsDidChange"))) { _ in loadParams() }
  }

  private func shouldShowParam(_ idx: Int) -> Bool {
    if selectedGroup == "ALL" { return true }
    if let g = groups.first(where: { $0.id == selectedGroup }) { return g.indices.contains(idx) }
    return true
  }

  private func loadParams() {
    isLoadingPreset = true
    let loaded = DOLShaderPostProcessor.shared.currentParameters()
    params = loaded
    groups = buildGroups(params: loaded)
    var dict: [Int: CGFloat] = [:]
    for p in loaded { dict[p.index] = DOLShaderPostProcessor.shared.currentValueForParameter(index: p.index) }
    values = dict
    isLoadingPreset = false
  }

  private func buildGroups(params: [Compiled.Parameter]) -> [(id: String, title: String, indices: [Int])] {
    var buckets: [String: [Int]] = [:]
    for p in params {
      let comps = p.name.split(separator: ":", maxSplits: 1).map(String.init)
      let key = comps.count > 1 ? comps[0] : "ALL"
      buckets[key, default: []].append(p.index)
    }
    var result: [(id: String, title: String, indices: [Int])] = []
    for (k, idxs) in buckets {
      let title = (k == "ALL") ? L("All") : k
      result.append((id: k, title: title, indices: idxs.sorted()))
    }
    return result.sorted(by: { a, b in
      if a.id == "ALL" { return true }
      if b.id == "ALL" { return false }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    })
  }
}

/// Not `private`: also used by `ShaderQuickParameterView` (Shaders/ShaderQuickPickerView.swift),
/// which needs the same Decimal->CGFloat clamping for a preset that may not be the
/// live pipeline's current one.
extension Compiled.Parameter {
  var initialCGFloat: CGFloat { (initial as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: initial as NSDecimalNumber) : 0 }
  var minimumCGFloat: CGFloat { (minimum as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: minimum as NSDecimalNumber) : 0 }
  var maximumCGFloat: CGFloat { (maximum as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: maximum as NSDecimalNumber) : 1 }
  var stepCGFloat: CGFloat { (step as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: step as NSDecimalNumber) : 0.01 }
}

/// Safe (min...max, step) for a shader parameter's slider, guarding against the
/// non-finite / zero-width ranges some compiled shaders report. Factored out of
/// `ShaderParameterEditor`'s inline Slider bindings below so `ShaderQuickParameterView`
/// (Shaders/ShaderQuickPickerView.swift) doesn't reimplement the same clamping a
/// third time.
enum ShaderParameterRangeHelper {
  static func safeRange(_ p: Compiled.Parameter) -> (range: ClosedRange<CGFloat>, step: CGFloat) {
    let rawMin = p.minimumCGFloat
    let rawMax = p.maximumCGFloat
    let minVal = rawMin.isFinite ? rawMin : 0
    var width = (rawMax.isFinite ? rawMax : minVal) - minVal
    if !width.isFinite { width = 0 }
    let minWidth: CGFloat = 0.01
    if width <= 0 { width = minWidth }
    let maxVal = minVal + width
    let rawStep = p.stepCGFloat
    var step = (rawStep.isFinite && rawStep > 0) ? rawStep : (width / 100)
    let minStep = width / 1000
    if !step.isFinite || step <= 0 { step = minStep }
    if step >= width { step = width / 100 }
    return (minVal ... maxVal, max(step, minStep))
  }
}

// tvOS-friendly selectable row (duplicate of SettingsRootView's private helper)
private struct SelectRow: View {
  let label: String
  let checked: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack {
        Text(label)
        Spacer()
        if checked { Image(systemName: "checkmark") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    #if os(tvOS)
    .buttonStyle(.automatic)
    #else
    .buttonStyle(.plain)
    #endif
    #if os(tvOS)
    .focusable(true)
    #endif
  }
}
