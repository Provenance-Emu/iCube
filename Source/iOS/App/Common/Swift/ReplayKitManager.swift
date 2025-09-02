import Foundation
import ReplayKit
import UIKit

/// Simple facade for ReplayKit rolling clips
final class ReplayKitManager {
	static let shared = ReplayKitManager()
	private init() {}
	private var isBuffering = false

	/// Returns whether Instant Replay is enabled in settings and available on device
	private var shouldUseReplayKit: Bool {
		guard UserDefaults.standard.bool(forKey: "replaykit_instant_replay_enabled") else { return false }
		if #available(iOS 15.0, *) {
			return RPScreenRecorder.shared().isAvailable
		}
		return false
	}

	/// Begin rolling clip buffering if enabled
	func startBufferingIfEnabled() {
		guard shouldUseReplayKit else { return }
		if #available(iOS 15.0, *) {
			guard !isBuffering else { return }
			RPScreenRecorder.shared().startClipBuffering { err in
				DispatchQueue.main.async {
					self.isBuffering = (err == nil)
					if let e = err {
						NSLog("[ReplayKit] startClipBuffering error: %@", e.localizedDescription)
					}
				}
			}
		}
	}

	/// Stop rolling clip buffering
	func stopBuffering() {
		if #available(iOS 15.0, *) {
			guard isBuffering else { return }
			RPScreenRecorder.shared().stopClipBuffering { err in
				DispatchQueue.main.async { self.isBuffering = false }
				if let e = err { NSLog("[ReplayKit] stopClipBuffering error: %@", e.localizedDescription) }
			}
		}
	}

	/// Export the most recent seconds of buffered video to Documents/Clips and post a snackbar
	func saveRecentClip(seconds: TimeInterval = 15) {
		guard shouldUseReplayKit else {
			NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Instant Replay is disabled")])
			return
		}
		if #available(iOS 15.0, *) {
			let preferred = UserDefaults.standard.integer(forKey: "replaykit_clip_seconds")
			let secs = preferred > 0 ? TimeInterval(preferred) : seconds
			let fm = FileManager.default
			let docs = URL(fileURLWithPath: UserFolderUtil.getUserFolder())
			let clips = docs.appendingPathComponent("Clips", isDirectory: true)
			try? fm.createDirectory(at: clips, withIntermediateDirectories: true)
			let filename = "Clip_\(Int(Date().timeIntervalSince1970)).mov"
			let url = clips.appendingPathComponent(filename)
			RPScreenRecorder.shared().exportClip(to: url, duration: secs) { err in
				DispatchQueue.main.async {
					if let e = err {
						NSLog("[ReplayKit] exportClip error: %@", e.localizedDescription)
						NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Failed to save replay")])
					} else {
						NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved last %1ds to Clips"), Int(secs))])
					}
				}
			}
		}
	}
}
