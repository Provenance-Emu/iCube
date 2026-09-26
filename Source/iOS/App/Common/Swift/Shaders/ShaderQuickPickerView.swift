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
// Thumbnails — cards now show REAL per-preset previews. Each card renders its
// preset through `ShaderPreviewRenderer`, an isolated `FilterChain` on its own
// `MTLCommandQueue` that never touches the live `DOLShaderPostProcessor`
// singleton, against the last live game frame (`SaveStateService.pausePreviewURL`,
// captured the moment the pause menu opened) as the common source image — so
// every card shows what that preset actually does to the current frame, not a
// shared, un-shaded backdrop. Rendering is lazy (`.task(id:)` per card, so only
// visible/near-visible cards in the `LazyVGrid` do any work), bounded to a
// couple of renders in flight at once, and cached by `ShaderPreviewCache`
// (keyed on preset + source-frame mtime) so reopening the sheet or rescrolling
// doesn't re-render anything. A card falls back to today's name-derived
// icon/tint badge until its render lands — or forever, if rendering fails or
// times out (see `ShaderPreviewRenderer`'s header for the isolation/fail-soft
// design and why it's a fundamentally different approach from iFly's
// `ShaderPreviewGenerator`, which mutates the shared singleton's state under
// the hood despite looking isolated). The hero card previews the CURRENTLY
// SELECTED preset the same way, independent of the "Enabled" toggle.
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
  @State private var heroPreviewImage: UIImage?
  /// The pause frame, downscaled once and shared by every card's preview
  /// render (plus the hero's) — see `ShaderPreviewRenderer.sourceDownscaleMaxWidth`.
  @State private var previewSource: PreviewSourceFrame?
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
            grid(favoriteItems, sectionKey: "favorites")
          }
          if !recentItems.isEmpty {
            sectionHeader(L("Recently Used"))
            grid(recentItems, sectionKey: "recent")
          }
          sectionHeader(L("All Shaders"))
          grid(allItems, sectionKey: "all")
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
    .defaultFocus($focusedCardID, "all/" + (currentPath ?? PickerItem.noneID))
    .navigationDestination(item: $pushedParameterPath) { path in
      ShaderQuickParameterView(presetPath: path, presetName: displayName(forPresetPath: path))
    }
    .task {
      // Discovery recursively enumerates the whole bundle's resources — keep it
      // off the main actor so opening the sheet doesn't hitch the still-visible
      // (if paused) pause menu behind it.
      presets = await Task.detached(priority: .userInitiated) { ShaderLibrary.discoverPresets() }.value
      let fresh = Self.loadFreshPausePreview()
      heroImage = fresh?.image
      if let fresh, let cg = fresh.image.cgImage {
        let downscaled = ShaderPreviewRenderer.downscaledCGImage(cg, maxWidth: ShaderPreviewRenderer.sourceDownscaleMaxWidth)
        previewSource = PreviewSourceFrame(image: downscaled, mtime: fresh.mtime)
      }
      isLoading = false
    }
    .task(id: HeroTaskKey(path: currentPath, sourceReady: previewSource != nil, presetCount: presets.count)) {
      // Hero preview: the currently SELECTED preset, applied to the same
      // shared source frame every grid card uses — independent of the
      // "Enabled" toggle, since flipping that doesn't change which preset is
      // picked. Shares its cache key with the matching grid card (same
      // preset path + source mtime + thumbnail size), so whichever renders
      // first "pays" for both.
      heroPreviewImage = nil
      guard let currentPath, let previewSource,
            let presetURL = presets.first(where: { ShaderLibrary.normalizedPath($0.id.path) == currentPath })?.id
      else { return }
      guard let rendered = await ShaderPreviewCache.shared.preview(
        presetPath: currentPath,
        presetURL: presetURL,
        sourceImage: previewSource.image,
        sourceMTime: previewSource.mtime
      ) else { return }
      guard !Task.isCancelled else { return }
      heroPreviewImage = UIImage(cgImage: rendered)
    }
  }

  /// `currentPath` already has its final value on first render, before discovery has
  /// populated `presets`/`previewSource`; keying the hero task on those too makes it
  /// re-run once they arrive instead of leaving the hero on the raw frame all session.
  private struct HeroTaskKey: Hashable {
    let path: String?
    let sourceReady: Bool
    let presetCount: Int
  }

  /// The shared source frame handed to `ShaderPreviewRenderer` for every card
  /// (and the hero) in this sheet — downscaled once up front rather than per
  /// card. `fileprivate` for the same reason as `PickerItem`: `ShaderQuickCard`
  /// (a sibling top-level type in this file) needs to reference it by name.
  fileprivate struct PreviewSourceFrame {
    let image: CGImage
    let mtime: TimeInterval
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
    // Prefer the rendered preview of the currently selected preset; fall back
    // to the raw pause frame while it's still rendering (or if there's no
    // preset selected, or the render failed/timed out).
    if let heroPreviewImage {
      Image(uiImage: heroPreviewImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else if let heroImage {
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

  /// Loads `SaveStateService.pausePreviewURL` (image + its modification time,
  /// the latter doubling as `ShaderPreviewCacheKey.sourceMTime`) if it was
  /// captured recently enough to plausibly be THIS pause (not a leftover from a
  /// much older session, or a different game, since the file lives in
  /// `NSTemporaryDirectory()` and isn't scoped per-game). Mirrors
  /// `SaveStateService.adoptPausePreviewIfFresh`'s own 60-second window.
  private static func loadFreshPausePreview() -> (image: UIImage, mtime: TimeInterval)? {
    let url = SaveStateService.pausePreviewURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modified = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(modified) < pausePreviewFreshnessWindow,
          let image = UIImage(contentsOfFile: url.path)
    else { return nil }
    return (image, modified.timeIntervalSinceReferenceDate)
  }

  // MARK: - Grid

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundColor(.white.opacity(0.6))
      .textCase(.uppercase)
      .padding(.horizontal, 16)
  }

  /// `sectionKey` scopes the focus ids: the same preset appears in Favorites, Recent AND
  /// All Shaders, and duplicate `@FocusState` values across mounted views are undefined.
  private func grid(_ items: [PickerItem], sectionKey: String) -> some View {
    LazyVGrid(columns: Self.columns, spacing: 14) {
      ForEach(items) { item in
        ShaderQuickCard(
          item: item,
          focusKey: "\(sectionKey)/\(item.id)",
          isSelected: item.id == (currentPath ?? PickerItem.noneID),
          isFavorite: item.preset != nil && favorites.contains(item.id),
          focusedCardID: $focusedCardID,
          previewSource: previewSource,
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
    // Immediate apply to the LIVE pipeline — takes visual effect in the actual
    // game view once it resumes and a frame actually renders, since the render
    // loop is stopped while paused. This is separate from (and does not touch)
    // the offscreen preview rendering the cards use — see `ShaderPreviewRenderer`.
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
  /// Section-scoped focus id (see `grid(_:sectionKey:)`).
  let focusKey: String
  let isSelected: Bool
  let isFavorite: Bool
  var focusedCardID: FocusState<String?>.Binding
  /// Shared source frame for rendering this card's preview — `nil` when there's
  /// no fresh pause frame to render against (falls back to the name-derived
  /// badge, same as a failed/slow render).
  let previewSource: ShaderQuickPickerView.PreviewSourceFrame?
  let onApply: () -> Void
  let onToggleFavorite: () -> Void
  let onOpenParameters: () -> Void

  @State private var previewImage: UIImage?

  private var isFocused: Bool { focusedCardID.wrappedValue == focusKey }

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
      .focused(focusedCardID, equals: focusKey)
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
          .focused(focusedCardID, equals: focusKey + "#params")
          .accessibilityLabel(L("Parameters"))

          Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(isFavorite ? .yellow : .white)
              .padding(6)
              .background(Color.black.opacity(0.65), in: Circle())
          }
          .buttonStyle(.plain)
          .focused(focusedCardID, equals: focusKey + "#fav")
          .accessibilityLabel(isFavorite ? L("Remove Favorite") : L("Add Favorite"))
        }
      }
      .padding(6)
    }
    .animation(.easeInOut(duration: 0.15), value: isFocused)
    .task(id: item.id) {
      // Fresh identity each time `item.id` changes (including when this card
      // is reused by `ForEach` for a different preset) — start clean rather
      // than briefly showing the previous card's thumbnail.
      previewImage = nil
      guard let preset = item.preset, let previewSource else { return }
      guard let rendered = await ShaderPreviewCache.shared.preview(
        presetPath: ShaderLibrary.normalizedPath(preset.id.path),
        presetURL: preset.id,
        sourceImage: previewSource.image,
        sourceMTime: previewSource.mtime
      ) else { return }
      // SwiftUI cancels this Task automatically if the card scrolls out and
      // `ForEach` tears it down (or the whole sheet closes) before the render
      // lands — this guard just avoids a pointless `@State` write on the way
      // out; the render itself already ran and is cached for next time.
      guard !Task.isCancelled else { return }
      previewImage = UIImage(cgImage: rendered)
    }
  }

  @ViewBuilder
  private var thumbnail: some View {
    ZStack {
      if let previewImage {
        Image(uiImage: previewImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(tint.opacity(0.22))
        Image(systemName: iconName)
          .font(.system(size: 26, weight: .medium))
          .foregroundColor(tint)
      }
    }
    .frame(height: 78)
    .frame(maxWidth: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .padding(8)
  }

  private var tint: Color { Self.tint(forName: item.preset?.name) }
  private var iconName: String { Self.icon(forName: item.preset?.name) }

  /// Deterministic-per-launch color from the preset's name — the fallback
  /// look while a real preview is rendering (or if it never lands: rendering
  /// failed, timed out, or there's no source frame to render against).
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
