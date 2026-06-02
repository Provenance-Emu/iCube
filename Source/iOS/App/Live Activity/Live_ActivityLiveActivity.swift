// Copyright 2025 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import ActivityKit
import SwiftUI
import WidgetKit

struct Live_ActivityLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: GameActivityAttributes.self) { context in
      // Lock screen / banner UI
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(context.state.title.isEmpty ? "Playing" : context.state.title)
            .font(.headline)
            .lineLimit(1)
          if let maker = context.state.subtitle, !maker.isEmpty {
            Text(maker)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 4) {
          Text(context.state.isPaused ? "Paused" : "Playing")
            .font(.subheadline)
            .bold()
          // show mm:ss elapsed
          let secs = max(0, context.state.elapsedSeconds)
          let mm = secs / 60
          let ss = secs % 60
          Text(String(format: "%02d:%02d", mm, ss))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .activityBackgroundTint(Color.black.opacity(0.15))
      .activitySystemActionForegroundColor(.primary)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.state.isPaused ? "Paused" : "Playing")
              .font(.caption)
              .bold()
            Text(context.state.title.isEmpty ? "Game" : context.state.title)
              .font(.headline)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          let secs = max(0, context.state.elapsedSeconds)
          let mm = secs / 60
          let ss = secs % 60
          Text(String(format: "%02d:%02d", mm, ss))
            .font(.title3)
            .monospacedDigit()
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let maker = context.state.subtitle, !maker.isEmpty {
            Text(maker)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      } compactLeading: {
        Image(systemName: context.state.isPaused ? "pause.fill" : "play.fill")
      } compactTrailing: {
        let secs = max(0, context.state.elapsedSeconds)
        let mm = secs / 60
        let ss = secs % 60
        Text(String(format: "%d:%02d", mm, ss))
          .monospacedDigit()
      } minimal: {
        Image(systemName: context.state.isPaused ? "pause.fill" : "play.fill")
      }
      .keylineTint(Color.accentColor)
    }
  }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Notification", as: .content, using: GameActivityAttributes(gameId: "XXXX01")) {
  Live_ActivityLiveActivity()
} contentStates: {
  GameActivityAttributes.ContentState(title: "Mario Kart Wii", subtitle: "Nintendo", isPaused: false, elapsedSeconds: 125)
  GameActivityAttributes.ContentState(title: "Mario Kart Wii", subtitle: "Nintendo", isPaused: true, elapsedSeconds: 125)
}
#endif
