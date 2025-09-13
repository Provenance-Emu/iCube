// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// SwiftUI wrapper for the button mapping interface that works on both iOS and tvOS
internal struct ButtonMappingView: UIViewControllerRepresentable {
  let isGC: Bool
  let portOneBased: Int

  func makeUIViewController(context: Context) -> UIViewController {
    #if os(tvOS)
    // For tvOS, create the view controller programmatically
    let mappingVC = MappingRootViewController()
    mappingVC.mappingType = isGC ? .DOLMappingTypePad : .DOLMappingTypeWiimote
    mappingVC.mappingPort = Int32(max(0, portOneBased - 1))

    let navController = UINavigationController(rootViewController: mappingVC)

    return navController
    #else
    // For iOS, use the existing storyboard approach
    let storyboard = UIStoryboard(name: "ButtonMapping", bundle: nil)
    let vc = storyboard.instantiateInitialViewController() ?? UIViewController()
    // Pass mapping context via KVC to avoid additional bridging requirements
    // DOLMappingType: 0 = Pad, 1 = Wiimote
    vc.setValue(isGC ? 0 : 1, forKey: "mappingType")
    vc.setValue(max(0, portOneBased - 1), forKey: "mappingPort")
    return vc
    #endif
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    // No-op; mapping UI manages its own state
  }
}

#if os(tvOS)
// MARK: - Programmatic MappingRootViewController for tvOS

/// Programmatic version of MappingRootViewController that doesn't rely on storyboards
@objc class MappingRootViewController: UITableViewController {
  @objc var mappingType: DOLMappingType = .DOLMappingTypePad
  @objc var mappingPort: Int32 = 0

  private var config: UnsafeMutableRawPointer?
  private var controller: UnsafeMutableRawPointer?
  private var sections: [[String: Any]] = []

    // Initialize with grouped style
  override init(style: UITableView.Style) {
    #if os(tvOS)
    super.init(style: .grouped)
    #else
    super.init(style: .insetGrouped)
    #endif
  }

  convenience override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
    #if os(tvOS)
    self.init(style: .grouped)
    #else
    self.init(style: .insetGrouped)
    #endif
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = L("Mapping")
    #if !os(tvOS)
    navigationItem.largeTitleDisplayMode = .never
    #endif

    // Configure table view (style is set in init)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 44

    // Register cell types
    registerCells()

    // Initialize Dolphin configuration
    initializeDolphinConfig()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    populateSections()
  }

  private func registerCells() {
    // Register basic cell types programmatically
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ExtensionSelectCell")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "GroupCell")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProfileSaveCell")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProfileLoadCell")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "InputDisplayCell")
  }

  private func initializeDolphinConfig() {
    // This would need to call into the Dolphin C++ code
    // For now, we'll create placeholder sections
    // In a real implementation, this would call Pad::GetConfig() or Wiimote::GetConfig()
  }

  private func populateSections() {
    sections.removeAll()

    // Device section
    sections.append([
      "title": "",
      "items": [
        ["type": "device", "title": L("Device"), "subtitle": "—"],
        ["type": "inputDisplay", "title": L("Show Input Display"), "subtitle": ""]
      ]
    ])

    // Profile section
    sections.append([
      "title": L("Profile"),
      "items": [
        ["type": "profileLoad", "title": L("Load"), "subtitle": ""],
        ["type": "profileSave", "title": L("Save"), "subtitle": ""]
      ]
    ])

    // Controller-specific sections
    if mappingType == .DOLMappingTypePad {
      // GameCube controller sections
      sections.append([
        "title": L("General and Options"),
        "items": [
          ["type": "group", "title": L("Buttons"), "subtitle": ""],
          ["type": "group", "title": L("D-Pad"), "subtitle": ""],
          ["type": "group", "title": L("Control Stick"), "subtitle": ""],
          ["type": "group", "title": L("C Stick"), "subtitle": ""],
          ["type": "group", "title": L("Triggers"), "subtitle": ""],
          ["type": "group", "title": L("Rumble"), "subtitle": ""],
          ["type": "group", "title": L("Options"), "subtitle": ""]
        ]
      ])
    } else {
      // Wii Remote sections
      sections.append([
        "title": L("General"),
        "items": [
          ["type": "group", "title": L("Buttons"), "subtitle": ""],
          ["type": "group", "title": L("D-Pad"), "subtitle": ""],
          ["type": "group", "title": L("IR"), "subtitle": ""],
          ["type": "group", "title": L("Swing"), "subtitle": ""],
          ["type": "group", "title": L("Tilt"), "subtitle": ""],
          ["type": "group", "title": L("Shake"), "subtitle": ""],
          ["type": "extension", "title": L("Extension"), "subtitle": L("None")],
          ["type": "group", "title": L("Rumble"), "subtitle": ""],
          ["type": "group", "title": L("Options"), "subtitle": ""]
        ]
      ])
    }

    tableView.reloadData()
  }

  // MARK: - Table View Data Source

  override func numberOfSections(in tableView: UITableView) -> Int {
    return sections.count
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let items = sections[section]["items"] as? [[String: Any]] else { return 0 }
    return items.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    let title = sections[section]["title"] as? String
    return title?.isEmpty == false ? title : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let items = sections[indexPath.section]["items"] as? [[String: Any]],
          let item = items[safe: indexPath.row],
          let type = item["type"] as? String,
          let title = item["title"] as? String else {
      return UITableViewCell()
    }

    let subtitle = item["subtitle"] as? String ?? ""

    switch type {
    case "device":
      let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
      cell.textLabel?.text = title
      cell.detailTextLabel?.text = subtitle
      cell.accessoryType = .disclosureIndicator
      return cell

    case "extension":
      let cell = tableView.dequeueReusableCell(withIdentifier: "ExtensionSelectCell", for: indexPath)
      cell.textLabel?.text = title
      cell.detailTextLabel?.text = subtitle
      cell.accessoryType = .disclosureIndicator
      return cell

    case "group":
      let cell = tableView.dequeueReusableCell(withIdentifier: "GroupCell", for: indexPath)
      cell.textLabel?.text = title
      cell.accessoryType = .disclosureIndicator
      return cell

    case "profileLoad":
      let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileLoadCell", for: indexPath)
      cell.textLabel?.text = title
      cell.textLabel?.textColor = .systemBlue
      return cell

    case "profileSave":
      let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileSaveCell", for: indexPath)
      cell.textLabel?.text = title
      cell.textLabel?.textColor = .systemBlue
      return cell

    case "inputDisplay":
      let cell = tableView.dequeueReusableCell(withIdentifier: "InputDisplayCell", for: indexPath)
      cell.textLabel?.text = title
      cell.textLabel?.textColor = .systemBlue
      return cell

    default:
      let cell = UITableViewCell()
      cell.textLabel?.text = title
      return cell
    }
  }

  // MARK: - Table View Delegate

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    guard let items = sections[indexPath.section]["items"] as? [[String: Any]],
          let item = items[safe: indexPath.row],
          let type = item["type"] as? String else {
      return
    }

    switch type {
    case "device":
      // Navigate to device selection
      showDeviceSelection()

    case "extension":
      // Navigate to extension selection
      showExtensionSelection()

    case "group":
      // Navigate to group editing
      if let title = item["title"] as? String {
        showGroupEdit(for: title)
      }

    case "profileLoad":
      // Show profile loading
      showProfileLoad()

    case "profileSave":
      // Show profile save dialog
      showProfileSave()

    case "inputDisplay":
      // Show input display
      showInputDisplay()

    default:
      break
    }
  }

  // MARK: - Navigation Methods

  private func showDeviceSelection() {
    // Placeholder for device selection
    let alert = UIAlertController(title: L("Device Selection"), message: L("Device selection not yet implemented in programmatic version"), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("OK"), style: .default))
    present(alert, animated: true)
  }

  private func showExtensionSelection() {
    // Placeholder for extension selection
    let alert = UIAlertController(title: L("Extension Selection"), message: L("Extension selection not yet implemented in programmatic version"), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("OK"), style: .default))
    present(alert, animated: true)
  }

  private func showGroupEdit(for groupName: String) {
    // Placeholder for group editing
    let alert = UIAlertController(title: L("Group Edit"), message: L("Group editing for '\(groupName)' not yet implemented in programmatic version"), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("OK"), style: .default))
    present(alert, animated: true)
  }

  private func showProfileLoad() {
    // Placeholder for profile loading
    let alert = UIAlertController(title: L("Load Profile"), message: L("Profile loading not yet implemented in programmatic version"), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("OK"), style: .default))
    present(alert, animated: true)
  }

  private func showProfileSave() {
    let alert = UIAlertController(title: L("Enter Name"), message: L("Please enter a name for this profile."), preferredStyle: .alert)

    alert.addTextField { textField in
      textField.placeholder = L("Name")
    }

    alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))

    alert.addAction(UIAlertAction(title: L("Save"), style: .default) { _ in
      guard let profileName = alert.textFields?.first?.text, !profileName.isEmpty else {
        let errorAlert = UIAlertController(title: L("Invalid Name"), message: L("Please enter a profile name."), preferredStyle: .alert)
        errorAlert.addAction(UIAlertAction(title: L("OK"), style: .default))
        self.present(errorAlert, animated: true)
        return
      }

      // TODO: Implement actual profile saving
      // This would call into the Dolphin C++ code to save the profile
    })

    present(alert, animated: true)
  }

  private func showInputDisplay() {
    // Placeholder for input display
    let alert = UIAlertController(title: L("Input Display"), message: L("Input display not yet implemented in programmatic version"), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: L("OK"), style: .default))
    present(alert, animated: true)
  }
}

// MARK: - DOLMappingType enum for tvOS

@objc enum DOLMappingType: UInt {
  case DOLMappingTypePad = 0
  case DOLMappingTypeWiimote = 1
}

#endif

// MARK: - Array Safe Subscript Extension

private extension Array {
  subscript(safe index: Index) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}
