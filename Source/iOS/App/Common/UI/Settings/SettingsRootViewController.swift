// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit
import SwiftUI

class SettingsRootViewController: UITableViewController {
  @IBOutlet weak var versionLabel: UILabel!
  @IBOutlet weak var coreVersionLabel: UILabel!

  override func viewDidLoad() {
    super.viewDidLoad()

    // Replace UIKit table with SwiftUI root settings
    let swiftUIView = SettingsRootView()
    let hosting = UIHostingController(rootView: swiftUIView)
    addChild(hosting)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    hosting.didMove(toParent: self)
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
  }

  @IBAction func unwindToSettings( _ seg: UIStoryboardSegue) {}
}
