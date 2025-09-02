import Foundation
import ReplayKit
import UIKit
import Photos

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
			let saveToPhotos = UserDefaults.standard.bool(forKey: "replaykit_save_to_photos")
			let onlyPhotos = UserDefaults.standard.bool(forKey: "replaykit_save_only_photos")
			if !onlyPhotos { try? fm.createDirectory(at: clips, withIntermediateDirectories: true) }
			let filename = "Clip_\(Int(Date().timeIntervalSince1970)).mov"
			let baseDir = onlyPhotos ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) : clips
			let url = baseDir.appendingPathComponent(filename)
			RPScreenRecorder.shared().exportClip(to: url, duration: secs) { err in
				DispatchQueue.main.async {
					if let e = err {
						NSLog("[ReplayKit] exportClip error: %@", e.localizedDescription)
						NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Failed to save replay")])
					} else {
						if saveToPhotos {
							self.saveToPhotos(fileURL: url) { success in
								if success {
									if onlyPhotos {
										try? fm.removeItem(at: url)
										NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Saved clip to Photos")])
									} else {
										NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Saved clip to Clips and Photos")])
									}
								} else {
									// Fall back snackbar to indicate local save succeeded
									if onlyPhotos {
										NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved last %1ds to Clips"), Int(secs))])
									} else {
										NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved last %1ds to Clips"), Int(secs))])
									}
								}
							}
						} else {
							NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Saved last %1ds to Clips"), Int(secs))])
						}
					}
				}
			}
		}
	}

	private func saveToPhotos(fileURL: URL, completion: @escaping (Bool) -> Void) {
		let performSave = {
			PHPhotoLibrary.shared().performChanges({
				let request = PHAssetCreationRequest.forAsset()
				request.addResource(with: .video, fileURL: fileURL, options: nil)
			}, completionHandler: { success, error in
				DispatchQueue.main.async {
					if let e = error { NSLog("[ReplayKit] Photos save error: %@", e.localizedDescription) }
					completion(success)
				}
			})
		}
		if #available(iOS 14.0, *) {
			let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
			if status == .authorized || status == .limited { performSave(); return }
			PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in performSave() }
		} else {
			let status = PHPhotoLibrary.authorizationStatus()
			if status == .authorized { performSave(); return }
			PHPhotoLibrary.requestAuthorization { _ in performSave() }
		}
	}
}
