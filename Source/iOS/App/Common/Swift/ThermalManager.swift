import Foundation
import UIKit

/// Monitors device thermal state and auto-tunes graphics settings when enabled
final class ThermalManager {
  @MainActor
	static let shared = ThermalManager()
	private init() {}

	static let changedNotification = Notification.Name("DOLThermalStateChanged")
	private var observing = false
	private var baselineCaptured = false
	private var baselineEfbScale: Int = 1
	private var baselineAnisotropy: Int = 1
	private var baselineShaderEnabled: Bool = false
	private var baselineHDREnabled: Bool = false
	private var lastNotified: ProcessInfo.ThermalState = .nominal

	/// Start observing thermal changes
	func start() {
		guard !observing else { return }
		observing = true
		NotificationCenter.default.addObserver(self, selector: #selector(onThermalChange), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
		captureBaselineIfNeeded()
		applyForState(ProcessInfo.processInfo.thermalState)
	}

	/// Stop observing
	func stop() {
		guard observing else { return }
		observing = false
		NotificationCenter.default.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
	}

	@objc private func onThermalChange() {
		applyForState(ProcessInfo.processInfo.thermalState)
	}

	private func captureBaselineIfNeeded() {
		guard !baselineCaptured else { return }
		baselineEfbScale = DOLConfigBridge.gfxEfbScale()
		baselineAnisotropy = DOLConfigBridge.gfxEnhanceAnisotropySamples()
		baselineShaderEnabled = UserDefaults.standard.bool(forKey: "shader_enabled")
		baselineHDREnabled = UserDefaults.standard.bool(forKey: "gfx_edr_enabled")
		baselineCaptured = true
	}

	private func restoreBaseline() {
		DOLConfigBridge.setGfxEfbScale(baselineEfbScale)
		DOLConfigBridge.setGfxEnhanceAnisotropySamples(baselineAnisotropy)
		UserDefaults.standard.set(baselineShaderEnabled, forKey: "shader_enabled")
		NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
		UserDefaults.standard.set(baselineHDREnabled, forKey: "gfx_edr_enabled")
		TVEmulationBridge.resizeSurfaceNow()
	}

	private func notify(_ state: ProcessInfo.ThermalState) {
		guard state != lastNotified else { return }
		lastNotified = state
		NotificationCenter.default.post(name: ThermalManager.changedNotification, object: nil, userInfo: ["state": mapState(state)])
	}

	private func mapState(_ state: ProcessInfo.ThermalState) -> Int {
		switch state {
		case .nominal: return 0
		case .fair: return 1
		case .serious: return 2
		case .critical: return 3
		@unknown default: return 0
		}
	}

	private func applyForState(_ state: ProcessInfo.ThermalState) {
		notify(state)
		guard UserDefaults.standard.bool(forKey: "thermal_auto_enable") else { return }
		switch state {
		case .nominal:
			restoreBaseline()
			NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Thermal: Restored quality")])
		case .fair:
			captureBaselineIfNeeded()
			let efb = max(1, min(baselineEfbScale, DOLConfigBridge.gfxEfbScale()) - 1)
			let aniso = max(1, baselineAnisotropy / 2)
			DOLConfigBridge.setGfxEfbScale(efb)
			DOLConfigBridge.setGfxEnhanceAnisotropySamples(aniso)
			UserDefaults.standard.set(false, forKey: "gfx_edr_enabled")
			TVEmulationBridge.resizeSurfaceNow()
			NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Thermal: Reduced resolution/AF")])
		case .serious, .critical:
			captureBaselineIfNeeded()
			DOLConfigBridge.setGfxEfbScale(1)
			DOLConfigBridge.setGfxEnhanceAnisotropySamples(1)
			UserDefaults.standard.set(false, forKey: "gfx_edr_enabled")
			if UserDefaults.standard.bool(forKey: "shader_enabled") {
				UserDefaults.standard.set(false, forKey: "shader_enabled")
				NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
			}
			TVEmulationBridge.resizeSurfaceNow()
			NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Thermal: Aggressive power saving")])
		@unknown default:
			break
		}
	}
}
