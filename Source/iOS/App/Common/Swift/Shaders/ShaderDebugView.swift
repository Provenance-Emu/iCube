// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// D16: the raw shader-pipeline diagnostics (checkerboard/bypass/forced-binding
// hacks used while bringing up `FilterChain`) used to sit in a "Debug" section of
// `ShaderSettingsView`, visible to every user in every build. They're real
// engineering tools — force a checkerboard onto a binding to prove a shader is
// sampling the right texture, dump an intermediate pass, etc. — with no use to
// someone just trying to pick a shader. This view is the whole file, and the
// whole file only compiles in DEBUG builds; `ShaderSettingsView` only links to it
// from inside `#if DEBUG`. The `FilterChain`/`ShaderPostProcessor` read sites for
// these same keys are ALSO gated behind `#if DEBUG` (see those files), so a value
// someone flipped on in a debug build can't linger and silently affect a Release
// build that has no UI to turn it back off.
//
// Four toggles that used to live here were deleted outright rather than moved:
// "Vertex positions at buffer index 0" (shader_debug_positions_index0), "Force
// last pass offscreen" (shader_debug_force_offscreen_last), "Force pass 0 Source
// at binding 0" (shader_debug_force_source_binding0), and "Clear each pass
// (debug)" (shader_debug_clear_passes). A repo-wide grep found no reader for any
// of the four outside this old UI — dead code, not dead-but-someday-useful code.
#if DEBUG
import SwiftUI

struct ShaderDeveloperDebugView: View {
  @State private var dbgBypass: Bool = false
  @State private var dbgChecker: Bool = false
  @State private var dbgShowPass: Bool = false
  @State private var dbgPassIndex: Int = 0

  @AppStorage("shader_debug_checker_apply") private var dbgCheckerApply: Bool = false
  @AppStorage("shader_debug_binding0_checker") private var dbgBinding0Checker: Bool = false
  @AppStorage("shader_debug_force_all_checker") private var dbgForceAllChecker: Bool = false
  @AppStorage("shader_debug_force_bgra8") private var dbgForceBGRA8: Bool = false
  @AppStorage("shader_debug_log_once") private var dbgLogOnce: Bool = true
  @AppStorage("shader_debug_disable_precopy") private var dbgDisablePreCopy: Bool = false
  @AppStorage("shader_debug_force_prev_output_binding0") private var dbgForcePrevOutputBinding0: Bool = false
  @AppStorage("shader_debug_map_source_semantics") private var dbgMapSourceSemantics: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("Pipeline")), footer: Text(L("Internal tools for debugging the shader render pipeline. Not needed to pick or tune a shader."))) {
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
        Toggle(L("Force binding 0 = checker (pass 0)"), isOn: $dbgBinding0Checker)
        Toggle(L("Force all bindings = checker"), isOn: $dbgForceAllChecker)
        Toggle(L("Force BGRA8 formats"), isOn: $dbgForceBGRA8)
        Toggle(L("One-shot diagnostics"), isOn: $dbgLogOnce)
        Toggle(L("Disable pre-copy (debug)"), isOn: $dbgDisablePreCopy)
        Toggle(L("Force prev pass output at binding 0"), isOn: $dbgForcePrevOutputBinding0)
        Toggle(L("Map 'source' semantics to expected binding"), isOn: $dbgMapSourceSemantics)
        Toggle(L("Preview intermediate pass"), isOn: $dbgShowPass)
          .onChange(of: dbgShowPass) {
            UserDefaults.standard.set($0, forKey: "shader_debug_show_pass_enabled")
            NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
          }
        HStack {
          Text(L("Pass index"))
          Spacer()
          #if os(tvOS)
          TVIntStepper(value: $dbgPassIndex, range: 0 ... 32, step: 1)
          #else
          Stepper(value: $dbgPassIndex, in: 0 ... 32) {
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
    .navigationTitle(L("Shader Debug Tools"))
    .onAppear { sync() }
  }

  private func sync() {
    dbgBypass = UserDefaults.standard.bool(forKey: "shader_bypass")
    dbgChecker = UserDefaults.standard.bool(forKey: "shader_debug_checker")
    dbgShowPass = UserDefaults.standard.bool(forKey: "shader_debug_show_pass_enabled")
    dbgPassIndex = (UserDefaults.standard.object(forKey: "shader_debug_show_pass") as? NSNumber)?.intValue ?? 0
  }
}
#endif
