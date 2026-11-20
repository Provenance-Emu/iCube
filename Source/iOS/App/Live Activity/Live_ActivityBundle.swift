// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import PVWidgets
import SwiftUI
import WidgetKit

@main
struct Live_ActivityBundle: WidgetBundle {
  init() {
    PVWidgetsHost.configure(dataSource: ICubeWidgetDataSource(), theme: ICubeWidgetTheme.standard)
  }

  var body: some Widget {
    Live_ActivityLiveActivity()
    RecentGamesWidget()
    if #available(iOS 18.0, *) {
      ResumeLastGameControl()
    }
  }
}
