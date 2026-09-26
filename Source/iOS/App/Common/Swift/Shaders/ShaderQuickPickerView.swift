// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// D16: quick-preview shader picker for the pause menu, ported from iFly's
// InlineShaderStrip / ShaderLibraryView interaction model — tap a card to apply
// immediately, long-press (or the gear button, for tvOS/reliability) to tune its
// parameters — restyled to iCube's card language (rounded rect + `.ultraThinMaterial`,
// a tinted icon badge, the same shape `PauseMenuView.menuButtonIOS` uses) rather than
// carrying over iFly's own theme tokens. This replaces `ShaderSettingsView` as the
// sheet `PauseMenuView` opens for "Shaders" (see the `.sheet(isPresented: $showShaders)`
// there). `ShaderSettingsView`/`ShaderPickerView`/`ShaderParameterEditor` are untouched
// and still serve Settings and the in-game FX sheet in `EmulationScreen`.
//
// Thumbnails — read this before assuming these are live per-shader previews, they
// are NOT: iFly's `ShaderPreviewGenerator` renders every candidate preset through
// its OWN offscreen `FilterChain` instance, so its cards show what each shader
// actually looks like. iCube's `DOLShaderPostProcessor` is a singleton bound to the
// one live render pipeline (see the long comment above the preset-scoped parameter
// helpers in `ShaderPostProcessor.swift`) — there is no second, isolated FilterChain
// to render an arbitrary preset off to the side without touching whatever is
// actually driving the screen, and building one safely was out of scope for this
// pass. Instead, cards use the last live game frame — `SaveStateService.pausePreviewURL`,
// already captured the moment the pause menu opened — as a shared backdrop (real
// game content, not a placeholder), but it is the SAME frame under every card, not
// a per-shader render. Visual distinction between cards comes from the preset's
// name, its containing-folder category, and a name-derived icon/tint badge. The
// hero card is the only place the frame appears at full strength; grid cards dim
// it further specifically so they don't read as implying a per-shader effect
// preview that doesn't exist.
import SwiftUI
import UIKit

struct ShaderQuickPickerView: View {
  #if !os(tvOS)
  @Environment(\.dismiss) private var dismiss
  #endif

  @State private var presets: [ShaderPreset] = []
  @State private var isLoading = true
  @State private var enabled: Bool = UserDefaults.standard.bool(forKey: "shader_enabled")
  @State private var currentPath: String? = UserDefaults.standard.string(forKey: "shader_preset_path")
  @State private var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shader_favorites") ?? [])
  @State private var mru: [String] = UserDefaults.standard.stringArray(forKey: "shader_mru") ?? []
  @State private var heroImage: UIImage?
  @State private var pushedParameterPath: String?

  @FocusState private var focusedCardID: String?

  private static let columns = [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 14)]
  /// `SaveStateService.captureThumbnail`'s own freshness window for adopting the
  /// pause preview into a save thumbnail. Reused here for the same reason: a PNG
  /// left over in `NSTemporaryDirectory()` from a much older pause (or a
  /// different game entirely, if the temp file survived an app-switch) shouldn't
  /// be shown as "the current frame".
  private static let pausePreviewFreshnessWindow: TimeInterval = 60

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        heroSection

        if isLoading {
          ProgressView(L("Loading shaders…"))
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
          if !favoriteItems.isEmpty {
            sectionHeader(L("Favorites"))
            grid(favoriteItems)
          }
          if !recentItems.isEmpty {
            sectionHeader(L("Recently Used"))
            grid(recentItems)
          }
          sectionHeader(L("All Shaders"))
          grid(allItems)
        }
      }
      .padding(.vertical, 16)
    }
    .background(Color.black.ignoresSafeArea())
    .navigationTitle(L("Shaders"))
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(L("Close")) { dismiss() }
      }
    }
    #endif
    .defaultFocus($focusedCardID, currentPath ?? PickerItem.noneID)
    .navigationDestination(item: $pushedParameterPath) { path in
      ShaderQuickParameterView(presetPath: path, presetName: displayName(forPresetPath: path))
    }
    .task {
      // Discovery recursively enumerates the whole bundle's resources — keep it
      // off the main actor so opening the sheet doesn't hitch the still-visible
      // (if paused) pause menu behind it.
      presets = await Task.detached(priority: .userInitiated) { ShaderLibrary.discoverPresets() }.value
      heroImage = Self.loadFreshPausePreview()
      isLoading = false
    }
  }

  // MARK: - Item model

  /// Wraps a `ShaderPreset?` with a stable, `Hashable` id ("NONE" for the no-shader
  /// card) so `ForEach`/`@FocusState<String?>` have something to key on without
  /// forcing `ShaderPreset` itself to model the "no preset" case.
  /// `fileprivate`, not `private`: `ShaderQuickCard` below (a sibling top-level
  /// type in this same file, not an extension of `ShaderQuickPickerView`) needs
  /// to reference this type by name, which plain `private` on a nested type
  /// would not allow.
  fileprivate struct PickerItem: Identifiable {
    static let noneID = "NONE"
    let id: String
    let preset: ShaderPreset?

    init(_ preset: ShaderPreset?) {
      self.preset = preset
      self.id = preset.map { ShaderLibrary.normalizedPath($0.id.path) } ?? Self.noneID
    }
  }

  private var allItems: [PickerItem] {
    [PickerItem(nil)] + presets.map(PickerItem.init)
  }

  private var favoriteItems: [PickerItem] {
    presets.filter { favorites.contains(ShaderLibrary.normalizedPath($0.id.path)) }.map(PickerItem.init)
  }

  private var recentItems: [PickerItem] {
    presets
      .filter { mru.contains(ShaderLibrary.normalizedPath($0.id.path)) && !favorites.contains(ShaderLibrary.normalizedPath($0.id.path)) }
      .sorted { a, b in
        let ma = mru.firstIndex(of: ShaderLibrary.normalizedPath(a.id.path)) ?? Int.max
        let mb = mru.firstIndex(of: ShaderLibrary.normalizedPath(b.id.path)) ?? Int.max
        return ma < mb
      }
      .map(PickerItem.init)
  }

  private func displayName(forPresetPath path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  // MARK: - Hero

  private var currentDisplayName: String {
    guard let currentPath else { return L("No Shader") }
    return displayName(forPresetPath: currentPath)
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { enabled },
      set: { newValue in
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: "shader_enabled")
        NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      }
    )
  }

  private var heroSection: some View {
    ZStack(alignment: .bottomLeading) {
      heroBackdrop
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(
          LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )

      VStack(alignment: .leading, spacing: 10) {
        Text(currentDisplayName)
          .font(.system(size: 20, weight: .bold))
          .foregroundColor(.white)
          .lineLimit(1)

        HStack(spacing: 12) {
          Toggle(isOn: enabledBinding) { EmptyView() }
            .labelsHidden()
            .tint(.orange)
          Text(enabled ? L("Enabled") : L("Disabled"))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))

          if currentPath != nil {
            Spacer()
            Button(L("Parameters")) { pushedParameterPath = currentPath }
              .buttonStyle(.bordered)
              .tint(.white)
              .focused($focusedCardID, equals: "HERO#params")
          }
        }
      }
      .padding(16)
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .padding(.horizontal, 16)
  }

  @ViewBuilder
  private var heroBackdrop: some View {
    if let heroImage {
      Image(uiImage: heroImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else {
      ZStack {
        Color.white.opacity(0.06)
        Image(systemName: "wand.and.stars")
          .font(.system(size: 36, weight: .medium))
          .foregroundColor(.white.opacity(0.4))
      }
    }
  }

  /// Loads `SaveStateService.pausePreviewURL` if it was captured recently enough
  /// to plausibly be THIS pause (not a leftover from a much older session, or a
  /// different game, since the file lives in `NSTemporaryDirectory()` and isn't
  /// scoped per-game). Mirrors `SaveStateService.adoptPausePreviewIfFresh`'s own
  /// 60-second window.
  private static func loadFreshPausePreview() -> UIImage? {
    let url = SaveStateService.pausePreviewURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modified = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(modified) < pausePreviewFreshnessWindow
    else { return nil }
    return UIImage(contentsOfFile: url.path)
  }

  // MARK: - Grid

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(.white.opacity(0.6))
      .textCase(.uppercase)
      .padding(.horizontal, 16)
  }

  private func grid(_ items: [PickerItem]) -> some View {
    LazyVGrid(columns: Self.columns, spacing: 14) {
      ForEach(items) { item in
        ShaderQuickCard(
          item: item,
          isSelected: item.id == (currentPath ?? PickerItem.noneID),
          isFavorite: item.preset != nil && favorites.contains(item.id),
          focusedCardID: $focusedCardID,
          onApply: { apply(item.preset) },
          onToggleFavorite: {
            if let preset = item.preset { toggleFavorite(preset) }
          },
          onOpenParameters: { openParameters(item.preset) }
        )
      }
    }
    .padding(.horizontal, 16)
  }

  // MARK: - Actions

  /// Applies `preset` (or clears to "None") exactly the way `ShaderPickerView`
  /// does — same UserDefaults keys, same notification, same
  /// `DOLShaderPostProcessor.applyPresetPath` call — with one deliberate addition:
  /// picking a preset here also force-enables shaders. The whole point of a
  /// "tap to apply" picker is that a tap visibly does something; the older
  /// Settings-based picker left `shader_enabled` alone, so tapping a preset while
  /// shaders were off silently did nothing until the user separately found the
  /// enable toggle. "None" does not touch `shader_enabled` (matches the old
  /// behavior), since turning a specific shader off isn't the same action as
  /// disabling the whole feature.
  private func apply(_ preset: ShaderPreset?) {
    guard let preset else {
      currentPath = nil
      UserDefaults.standard.removeObject(forKey: "shader_preset_path")
      NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      DOLShaderPostProcessor.shared.applyPresetPath(nil)
      return
    }
    let normalized = ShaderLibrary.normalizedPath(preset.id.path)
    currentPath = normalized
    enabled = true
    UserDefaults.standard.set(true, forKey: "shader_enabled")
    UserDefaults.standard.set(normalized, forKey: "shader_preset_path")
    NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
    // Immediate apply — takes visual effect once the game resumes and a frame
    // actually renders; see the big comment atop this file re: no live preview
    // while the pause menu (and therefore the render loop) is stopped.
    DOLShaderPostProcessor.shared.applyPresetPath(normalized)
    pushMRU(normalized)
  }

  private func toggleFavorite(_ preset: ShaderPreset) {
    let normalized = ShaderLibrary.normalizedPath(preset.id.path)
    if favorites.contains(normalized) {
      favorites.remove(normalized)
    } else {
      favorites.insert(normalized)
    }
    UserDefaults.standard.set(Array(favorites), forKey: "shader_favorites")
  }

  private func pushMRU(_ normalized: String) {
    var list = mru.filter { $0 != normalized }
    list.insert(normalized, at: 0)
    if list.count > 10 { list = Array(list.prefix(10)) }
    mru = list
    UserDefaults.standard.set(mru, forKey: "shader_mru")
  }

  /// "None" has no parameters to tune. For a real preset, this is safe to call
  /// for ANY preset — including one that isn't loaded into the live pipeline yet
  /// — see `DOLShaderPostProcessor.parameters(forPresetPath:)`.
  private func openParameters(_ preset: ShaderPreset?) {
    guard let preset else { return }
    pushedParameterPath = ShaderLibrary.normalizedPath(preset.id.path)
  }
}

/// One shader card: tap the body to apply, long-press or tap the gear to open
/// parameters, tap the star to favorite — three independent focusable/tappable
/// targets (not one nested inside another), following the same pattern this
/// codebase's own controller-setup rows use, and for the same reason: a control
/// nested inside another Button's label fires both actions together on tap, and
/// collapses to a single, unreachable focus target on tvOS.
private struct ShaderQuickCard: View {
  let item: ShaderQuickPickerView.PickerItem
  let isSelected: Bool
  let isFavorite: Bool
  var focusedCardID: FocusState<String?>.Binding
  let onApply: () -> Void
  let onToggleFavorite: () -> Void
  let onOpenParameters: () -> Void

  private var isFocused: Bool { focusedCardID.wrappedValue == item.id }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onApply) {
        VStack(alignment: .leading, spacing: 0) {
          thumbnail
          VStack(alignment: .leading, spacing: 2) {
            Text(item.preset?.name ?? L("None"))
              .font(.system(size: 14, weight: .semibold))
              .foregroundColor(.white)
              .lineLimit(1)
            Text(item.preset?.category ?? L("Shaders off"))
              .font(.system(size: 11, weight: .medium))
              .foregroundColor(.white.opacity(0.6))
              .lineLimit(1)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? Color.accentColor : Color.white.opacity(isFocused ? 0.6 : 0.08), lineWidth: isSelected ? 3 : (isFocused ? 2 : 1))
        )
        .scaleEffect(isFocused ? 1.04 : 1.0)
      }
      .buttonStyle(.plain)
      .focused(focusedCardID, equals: item.id)
      // A plain `.onLongPressGesture` on a Button inside a scroll view can
      // swallow the scroll gesture or double-fire alongside the tap.
      // `.simultaneousGesture` lets both the Button's tap and this long-press
      // coexist cleanly — primarily an iOS/touch affordance; the gear button
      // below is the reliable path on tvOS (and for anyone who doesn't know
      // long-press is there).
      .simultaneousGesture(
        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
          guard item.preset != nil else { return }
          onOpenParameters()
        }
      )

      HStack(spacing: 6) {
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.green)
            .padding(6)
            .background(Color.black.opacity(0.65), in: Circle())
        }
        if item.preset != nil {
          Button(action: onOpenParameters) {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.white)
              .padding(6)
              .background(Color.black.opacity(0.65), in: Circle())
          }
          .buttonStyle(.plain)
          .focused(focusedCardID, equals: item.id + "#params")
          .accessibilityLabel(L("Parameters"))

          Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(isFavorite ? .yellow : .white)
              .padding(6)
              .background(Color.black.opacity(0.65), in: Circle())
          }
          .buttonStyle(.plain)
          .focused(focusedCardID, equals: item.id + "#fav")
          .accessibilityLabel(isFavorite ? L("Remove Favorite") : L("Add Favorite"))
        }
      }
      .padding(6)
    }
    .animation(.easeInOut(duration: 0.15), value: isFocused)
  }

  @ViewBuilder
  private var thumbnail: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(tint.opacity(0.22))
      Image(systemName: iconName)
        .font(.system(size: 26, weight: .medium))
        .foregroundColor(tint)
    }
    .frame(height: 78)
    .padding(8)
  }

  private var tint: Color { Self.tint(forName: item.preset?.name) }
  private var iconName: String { Self.icon(forName: item.preset?.name) }

  /// Deterministic-per-launch color from the preset's name, purely for grid
  /// scannability (this is NOT derived from the shader's actual visual effect —
  /// see the file-level comment on `ShaderQuickPickerView` re: no per-shader
  /// render pipeline to preview from).
  private static func tint(forName name: String?) -> Color {
    guard let name, !name.isEmpty else { return .gray }
    let palette: [Color] = [.orange, .purple, .teal, .pink, .indigo, .mint, .cyan, .blue]
    var hasher = Hasher()
    hasher.combine(name)
    let index = abs(hasher.finalize()) % palette.count
    return palette[index]
  }

  /// Best-effort icon guess from common shader-name vocabulary (CRT, sharpen,
  /// smoothing, retro, palette/color). Falls back to a generic wand for anything
  /// unrecognized, and a "no shader" glyph for the None card.
  private static func icon(forName name: String?) -> String {
    guard let lower = name?.lowercased() else { return "circle.slash" }
    if lower.contains("crt") || lower.contains("scanline") { return "tv" }
    if lower.contains("sharp") || lower.contains("crisp") || lower.contains("xbr") { return "sparkles" }
    if lower.contains("smooth") || lower.contains("blur") || lower.contains("soft") { return "drop.fill" }
    if lower.contains("retro") || lower.contains("arcade") { return "gamecontroller" }
    if lower.contains("color") || lower.contains("palette") { return "paintpalette" }
    return "wand.and.stars"
  }
}

// MARK: - Parameter editor (preset-scoped, not live-pipeline-scoped)

/// Parameter editor for a specific preset path, independent of whether that
/// preset happens to be loaded into the live GPU pipeline right now. Necessary
/// because the pause menu can be (and usually is) still paused when this is
/// opened: picking a preset in `ShaderQuickPickerView` while paused persists the
/// choice but does not reload the live `FilterChain` until the game resumes and
/// a frame renders (see the comment above `DOLShaderPostProcessor.parameters(forPresetPath:)`).
/// Editing a not-yet-loaded preset here still works correctly — reads/writes go
/// through the same preset-scoped helpers, which fall back to the persisted
/// value / persist-only write when `presetPath` isn't the live one — it just has
/// nothing to visually preview until the pipeline actually loads it.
struct ShaderQuickParameterView: View {
  let presetPath: String
  let presetName: String

  @State private var params: [Compiled.Parameter] = []
  @State private var values: [Int: CGFloat] = [:]
  @State private var groups: [(id: String, title: String, indices: [Int])] = []
  @State private var selectedGroup: String = "ALL"

  var body: some View {
    List {
      if params.isEmpty {
        Text(L("No adjustable parameters in the current shader")).foregroundStyle(.secondary)
      } else {
        if groups.count > 1 {
          Picker(L("Group"), selection: $selectedGroup) {
            ForEach(groups, id: \.id) { g in Text(g.title).tag(g.id) }
          }
          .pickerStyle(.segmented)
        }
        ForEach(params, id: \.index) { p in
          if shouldShowParam(p.index) {
            let bounds = ShaderParameterRangeHelper.safeRange(p)
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(p.desc)
                Spacer()
                Text(String(format: "%.3f", values[p.index] ?? p.initialCGFloat))
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
                Button(L("Reset")) { setValue(p.initialCGFloat, index: p.index) }
                  .buttonStyle(.bordered)
                  #if os(iOS)
                  .controlSize(.small)
                  #endif
              }
              #if os(iOS)
              Slider(
                value: Binding(
                  get: { values[p.index] ?? p.initialCGFloat },
                  set: { setValue($0, index: p.index) }
                ),
                in: bounds.range,
                step: bounds.step
              )
              #else
              TVFloatStepper(
                value: Binding(
                  get: { values[p.index] ?? p.initialCGFloat },
                  set: { setValue($0, index: p.index) }
                ),
                range: bounds.range,
                step: bounds.step
              )
              #endif
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .navigationTitle(presetName)
    #if !os(tvOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(L("Reset All")) {
          for p in params { setValue(p.initialCGFloat, index: p.index) }
        }
        .disabled(params.isEmpty)
      }
    }
    .onAppear { load() }
  }

  private func shouldShowParam(_ idx: Int) -> Bool {
    if selectedGroup == "ALL" { return true }
    if let g = groups.first(where: { $0.id == selectedGroup }) { return g.indices.contains(idx) }
    return true
  }

  private func load() {
    let loaded = DOLShaderPostProcessor.shared.parameters(forPresetPath: presetPath)
    params = loaded
    groups = buildGroups(params: loaded)
    var dict: [Int: CGFloat] = [:]
    for p in loaded {
      dict[p.index] = DOLShaderPostProcessor.shared.parameterValue(forPresetPath: presetPath, index: p.index, fallback: p.initialCGFloat)
    }
    values = dict
  }

  private func setValue(_ value: CGFloat, index: Int) {
    values[index] = value
    DOLShaderPostProcessor.shared.setParameterValue(value, forPresetPath: presetPath, index: index)
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
