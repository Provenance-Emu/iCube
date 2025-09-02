import Foundation
import UIKit

#if os(iOS)
final class SiriShortcutManager {
	static let shared = SiriShortcutManager()
	private init() {}

	/// Donate a "Play [Game]" shortcut for Siri suggestions
	func donatePlay(game: TVGameItem) {
		let activityType = "dios.play.game"
		let activity = NSUserActivity(activityType: activityType)
		activity.title = String(format: L("Play %@"), game.title)
		activity.userInfo = ["gameID": game.gameID]
		activity.persistentIdentifier = NSUserActivityPersistentIdentifier("dios.play.\(game.gameID)")
		activity.isEligibleForPrediction = true
		activity.isEligibleForSearch = false
		UIApplication.shared.userActivity = activity
		activity.becomeCurrent()
	}
}
#endif
