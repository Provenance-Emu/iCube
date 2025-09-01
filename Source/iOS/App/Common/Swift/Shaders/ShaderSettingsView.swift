import Foundation
import SwiftUI

/// Simple preset model
struct ShaderPreset: Identifiable, Equatable {
	let id: URL
	let name: String
}

/// Discovers shader preset files. Looks in app bundle and user folder recursively for compiled containers
final class ShaderLibrary {
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

	private func normalizedPath(_ absPath: String) -> String {
		let bundleBase = Bundle.main.bundleURL.path
		if absPath.hasPrefix(bundleBase), let dotApp = absPath.range(of: ".app/") {
			return String(absPath[dotApp.upperBound...])
		}
		return absPath
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
				if !favorites.isEmpty {
					Section(header: Text(L("Favorites"))) {
						ForEach(presets.filter { favorites.contains(normalizedPath($0.id.path)) }) { preset in
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
				if !mru.isEmpty {
					Section(header: Text(L("Recently Used"))) {
						ForEach(presets.filter { mru.contains(normalizedPath($0.id.path)) }) { preset in
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
				ForEach(presets) { preset in
					Group {
						let absPath = preset.id.path
						let bundleBase = Bundle.main.bundleURL.path
						let normalized: String = {
							if absPath.hasPrefix(bundleBase), let dotApp = absPath.range(of: ".app/") {
								return String(absPath[dotApp.upperBound...])
							} else {
								return absPath
							}
						}()
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

/// Full settings page with enable toggle and picker
struct ShaderSettingsView: View {
	@State private var enabled: Bool = false
	@State private var presetPath: String?
	@State private var dbgBypass: Bool = false
	@State private var dbgChecker: Bool = false
	@State private var dbgFlip: Bool = true
	@State private var dbgShowPass: Bool = false
	@State private var dbgPassIndex: Int = 0
	@AppStorage("shader_precopy_enabled") private var compatPreCopyEnabled: Bool = false

	// Persisted toggles using @AppStorage for immediate UI updates
	@AppStorage("shader_debug_checker_apply") private var dbgCheckerApply: Bool = false
	@AppStorage("shader_debug_binding0_checker") private var dbgBinding0Checker: Bool = false
	@AppStorage("shader_debug_force_all_checker") private var dbgForceAllChecker: Bool = false
	@AppStorage("shader_debug_force_bgra8") private var dbgForceBGRA8: Bool = false
	@AppStorage("shader_debug_positions_index0") private var dbgPositionsIndex0: Bool = false
	@AppStorage("shader_debug_log_once") private var dbgLogOnce: Bool = true
	@AppStorage("shader_debug_force_offscreen_last") private var dbgOffscreenLast: Bool = false
	@AppStorage("shader_debug_disable_precopy") private var dbgDisablePreCopy: Bool = false
	@AppStorage("shader_debug_force_source_binding0") private var dbgForceSourceBinding0: Bool = false
	@AppStorage("shader_debug_force_prev_output_binding0") private var dbgForcePrevOutputBinding0: Bool = false
	@AppStorage("shader_debug_map_source_semantics") private var dbgMapSourceSemantics: Bool = false
	@AppStorage("shader_debug_clear_passes") private var dbgClearPasses: Bool = false

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

			Section(header: Text(L("Debug"))) {
				Toggle(L("Bypass (show source)"), isOn: $dbgBypass)
					.onChange(of: dbgBypass) {
						UserDefaults.standard.set($0, forKey: "shader_bypass")
						NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
					}
				Toggle(L("Show checkerboard"), isOn: $dbgChecker)
					.onChange(of: dbgChecker) {
						UserDefaults.standard.set($0, forKey: "shader_debug_checker")
						NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
					}
				Toggle(L("Apply shader over checkerboard"), isOn: $dbgCheckerApply)
				Toggle(L("Flip vertically"), isOn: $dbgFlip)
					.onChange(of: dbgFlip) {
						UserDefaults.standard.set($0, forKey: "shader_flip_vertical")
						NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
					}
				Toggle(L("Force binding 0 = checker (pass 0)"), isOn: $dbgBinding0Checker)
				Toggle(L("Force all bindings = checker"), isOn: $dbgForceAllChecker)
				Toggle(L("Force BGRA8 formats"), isOn: $dbgForceBGRA8)
				Toggle(L("Vertex positions at buffer index 0"), isOn: $dbgPositionsIndex0)
				Toggle(L("One-shot diagnostics"), isOn: $dbgLogOnce)
				Toggle(L("Force last pass offscreen"), isOn: $dbgOffscreenLast)
				Toggle(L("Disable pre-copy (debug)"), isOn: $dbgDisablePreCopy)
				Toggle(L("Enable pre-copy (compat)"), isOn: $compatPreCopyEnabled)
				Toggle(L("Force pass 0 Source at binding 0"), isOn: $dbgForceSourceBinding0)
				Toggle(L("Force prev pass output at binding 0"), isOn: $dbgForcePrevOutputBinding0)
				Toggle(L("Map 'source' semantics to expected binding"), isOn: $dbgMapSourceSemantics)
				Toggle(L("Clear each pass (debug)"), isOn: $dbgClearPasses)
				Toggle(L("Preview intermediate pass"), isOn: $dbgShowPass)
					.onChange(of: dbgShowPass) {
						UserDefaults.standard.set($0, forKey: "shader_debug_show_pass_enabled")
						NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
					}
				HStack {
					Text(L("Pass index"))
					Spacer()
					#if os(tvOS)
					TVIntStepper(value: $dbgPassIndex, range: 0...32, step: 1)
					#else
					Stepper(value: $dbgPassIndex, in: 0...32) {
						Text("\(dbgPassIndex)")
					}
					#endif
				}
				.onChange(of: dbgPassIndex) {
					UserDefaults.standard.set($0, forKey: "shader_debug_show_pass")
					NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
				}
			}
		}
		.navigationTitle(L("Shaders"))
		.onAppear { sync() }
		.onChange(of: presetPath) { p in
			if let p {
				let bundleBase = Bundle.main.bundleURL.path
				let pathToStore: String
				if p.hasPrefix(bundleBase), let dotApp = p.range(of: ".app/") {
					let suffix = String(p[dotApp.upperBound...])
					pathToStore = suffix
				} else {
					pathToStore = p
				}
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
		dbgBypass = UserDefaults.standard.bool(forKey: "shader_bypass")
		dbgChecker = UserDefaults.standard.bool(forKey: "shader_debug_checker")
		        dbgFlip = (UserDefaults.standard.object(forKey: "shader_flip_vertical") as? Bool) ?? false
		dbgShowPass = UserDefaults.standard.bool(forKey: "shader_debug_show_pass_enabled")
		dbgPassIndex = (UserDefaults.standard.object(forKey: "shader_debug_show_pass") as? NSNumber)?.intValue ?? 0
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
                    HStack { ProgressView(); Text(L("Loading preset…")).foregroundStyle(.secondary) }
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
                        }
#if os(iOS)
                        Slider(value: Binding(
                            get: { values[p.index] ?? p.initialCGFloat },
                            set: { newVal in
                                values[p.index] = newVal
                                DOLShaderPostProcessor.shared.setValue(newVal, forParameterIndex: p.index)
                            }
                        ), in: p.minimumCGFloat...p.maximumCGFloat, step: p.stepCGFloat)
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
                            range: p.minimumCGFloat...p.maximumCGFloat,
                            step: p.stepCGFloat
                        )
#endif
                    }
                    .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLShaderPresetDidLoad"))) { _ in
            self.isLoadingPreset = false
            let token = currentPresetSignature()
            if token != lastLoadedPresetToken { load() }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
#endif
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(L("None")) {
                        currentPresetPath = nil
                        DOLShaderPostProcessor.shared.applyPresetPath(nil)
                        isLoadingPreset = true
                    }
                    let presets = ShaderLibrary.discoverPresets()
                    ForEach(presets, id: \.id) { preset in
                        Button(preset.name) {
                            let absPath = preset.id.path
                            let bundleBase = Bundle.main.bundleURL.path
                            let normalized: String = {
                                if absPath.hasPrefix(bundleBase), let dotApp = absPath.range(of: ".app/") {
                                    return String(absPath[dotApp.upperBound...])
                                } else { return absPath }
                            }()
                            currentPresetPath = normalized
                            DOLShaderPostProcessor.shared.applyPresetPath(normalized)
                            isLoadingPreset = true
                            // Update MRU on quick change
                            var list = UserDefaults.standard.stringArray(forKey: "shader_mru") ?? []
                            list.removeAll(where: { $0 == normalized })
                            list.insert(normalized, at: 0)
                            if list.count > 10 { list = Array(list.prefix(10)) }
                            UserDefaults.standard.set(list, forKey: "shader_mru")
                        }
                    }
                } label: {
                    Label(L("Preset"), systemImage: "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(L("Reset All")) {
                    for p in params {
                        let v = p.initialCGFloat
                        values[p.index] = v
                        DOLShaderPostProcessor.shared.setValue(v, forParameterIndex: p.index)
                    }
                }
            }
        }
    }

    private func load() {
        let ps = DOLShaderPostProcessor.shared.currentParameters()
        self.params = ps
        var map: [Int: CGFloat] = [:]
        for p in ps {
            map[p.index] = DOLShaderPostProcessor.shared.currentValueForParameter(index: p.index)
        }
        self.values = map
        self.groups = buildGroups(params: ps)
        if !groups.contains(where: { $0.id == selectedGroup }) { selectedGroup = groups.first?.id ?? "ALL" }
        self.lastLoadedPresetToken = currentPresetSignature()
    }

    private func currentPresetSignature() -> String? {
        let path = UserDefaults.standard.string(forKey: "shader_preset_path") ?? "(none)"
        return "\(path)|\(params.count)"
    }

    private func buildGroups(params: [Compiled.Parameter]) -> [(id: String, title: String, indices: [Int])] {
        // We don’t have per-param pass/alias in the parameter itself, so group all under ALL for now
        // Future: if parameter naming convention includes pass aliases (e.g., "Bloom:Intensity"), split by prefix
        // Try to derive groups from name prefix before ':'
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
        // Ensure ALL appears first
        return result.sorted(by: { (a: (id: String, title: String, indices: [Int]), b: (id: String, title: String, indices: [Int])) -> Bool in
            if a.id == "ALL" { return true }
            if b.id == "ALL" { return false }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        })
    }

    private func shouldShowParam(_ index: Int) -> Bool {
        if selectedGroup == "ALL" { return true }
        if let grp = groups.first(where: { $0.id == selectedGroup }) {
            return grp.indices.contains(index)
        }
        return true
    }
}

private extension Compiled.Parameter {
    var initialCGFloat: CGFloat { (initial as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: initial as NSDecimalNumber) : 0 }
    var minimumCGFloat: CGFloat { (minimum as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: minimum as NSDecimalNumber) : 0 }
    var maximumCGFloat: CGFloat { (maximum as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: maximum as NSDecimalNumber) : 1 }
    var stepCGFloat: CGFloat { (step as NSDecimalNumber).doubleValue.isFinite ? CGFloat(truncating: step as NSDecimalNumber) : 0.01 }
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
