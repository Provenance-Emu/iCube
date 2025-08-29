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

	var body: some View {
		ScrollViewReader { proxy in
			List {
				SelectRow(label: L("None"), checked: selectedPresetPath == nil) {
					selectedPresetPath = nil
					UserDefaults.standard.removeObject(forKey: "shader_preset_path")
					NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
				}
				.id("NONE")
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
						SelectRow(label: preset.name, checked: (selectedPresetPath == normalized) || (selectedPresetPath == absPath)) {
							selectedPresetPath = normalized
							NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
							// Immediate apply while running
							DOLShaderPostProcessor.shared.applyPresetPath(normalized)
						}
						.id(preset.id)
					}
				}
			}
			.navigationTitle(L("Shaders"))
			.onAppear {
				presets = ShaderLibrary.discoverPresets()
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

	var body: some View {
		List {
			Section(header: Text(L("Post-Processing Shader"))) {
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
				Toggle(L("Apply shader over checkerboard"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "shader_debug_checker_apply") }, set: { UserDefaults.standard.set($0, forKey: "shader_debug_checker_apply") }))
				                Toggle(L("Flip vertically"), isOn: $dbgFlip)
                    .onChange(of: dbgFlip) {
                        UserDefaults.standard.set($0, forKey: "shader_flip_vertical")
                        NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
                    }
				Toggle(L("Force binding 0 = checker (pass 0)"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "shader_debug_binding0_checker") }, set: { UserDefaults.standard.set($0, forKey: "shader_debug_binding0_checker") }))
				Toggle(L("Force all bindings = checker"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "shader_debug_force_all_checker") }, set: { UserDefaults.standard.set($0, forKey: "shader_debug_force_all_checker") }))
				Toggle(L("Force BGRA8 formats"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "shader_debug_force_bgra8") }, set: { UserDefaults.standard.set($0, forKey: "shader_debug_force_bgra8") }))
				Toggle(L("Vertex positions at buffer index 0"), isOn: Binding(get: { UserDefaults.standard.bool(forKey: "shader_debug_positions_index0") }, set: { UserDefaults.standard.set($0, forKey: "shader_debug_positions_index0") }))
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
