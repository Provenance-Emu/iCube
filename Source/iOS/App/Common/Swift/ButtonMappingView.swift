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
    let mappingVC = TVMappingRootViewController()
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

/// Programmatic tvOS mapping screen (storyboard-free). Named distinctly from the
/// legacy ObjC `MappingRootViewController` (whose .h is on the bridging-header path)
/// to avoid a same-name clash with the storyboard-backed ObjC class that crashed
/// looking for the tvOS-absent ButtonMapping.storyboard.
class TVMappingRootViewController: UITableViewController {
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

  override convenience init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
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
    // Nothing needed here in Swift; we will access config via bridges when needed
  }

  private func currentDefaultDeviceQualifier() -> String {
    if mappingType == .DOLMappingTypePad {
      return TVControllerMappingBridge.defaultDevice(forGCPort: Int(mappingPort + 1))
    } else {
      return TVControllerMappingBridge.defaultDevice(forWiimote: Int(mappingPort + 1))
    }
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
          ["type": "extension", "title": L("Extension"), "subtitle": currentDefaultWiimoteExtensionDisplayName()],
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
      // Use a value1 style to show current device qualifier as subtitle
      let cell = UITableViewCell(style: .value1, reuseIdentifier: "DeviceCell")
      cell.textLabel?.text = title
      let current = currentDefaultDeviceQualifier()
      cell.detailTextLabel?.text = current.isEmpty ? "—" : friendlyName(forQualified: current)
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
    // Create programmatic device selection view controller
    let deviceVC = DeviceSelectionViewController()
    deviceVC.mappingType = mappingType
    deviceVC.mappingPort = mappingPort
    deviceVC.delegate = self

    navigationController?.pushViewController(deviceVC, animated: true)
  }

  private func showExtensionSelection() {
    // Create programmatic extension selection view controller
    let extensionVC = ExtensionSelectionViewController()
    extensionVC.mappingType = mappingType
    extensionVC.mappingPort = mappingPort
    extensionVC.delegate = self

    navigationController?.pushViewController(extensionVC, animated: true)
  }

  private func currentDefaultWiimoteExtensionDisplayName() -> String {
    let names = TVControllerMappingBridge.wiimoteAttachmentDisplayNames(for: Int(mappingPort + 1))
    let idx = TVControllerMappingBridge.selectedWiimoteAttachment(for: Int(mappingPort + 1))
    guard !names.isEmpty, idx >= 0, idx < names.count else { return L("None") }
    return names[idx]
  }

  private func showGroupEdit(for groupName: String) {
    // Create programmatic group edit view controller
    let groupEditVC = GroupEditViewController()
    groupEditVC.title = groupName
    groupEditVC.groupName = groupName
    groupEditVC.mappingType = mappingType
    groupEditVC.mappingPort = mappingPort
    groupEditVC.delegate = self

    navigationController?.pushViewController(groupEditVC, animated: true)
  }

  private func showProfileLoad() {
    // Create programmatic profile load view controller
    let profileLoadVC = ProfileLoadViewController()
    profileLoadVC.mappingType = mappingType
    profileLoadVC.mappingPort = mappingPort
    profileLoadVC.delegate = self

    let navController = UINavigationController(rootViewController: profileLoadVC)
    #if os(tvOS)
    navController.modalPresentationStyle = .fullScreen
    #else
    navController.modalPresentationStyle = .formSheet
    #endif

    present(navController, animated: true)
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
    // Create programmatic input display view controller
    let inputDisplayVC = InputDisplayViewController()
    inputDisplayVC.mappingType = mappingType
    inputDisplayVC.mappingPort = mappingPort

    navigationController?.pushViewController(inputDisplayVC, animated: true)
  }
}

// MARK: - Delegate Extensions

extension MappingRootViewController: DeviceSelectionDelegate, GroupEditDelegate, ProfileLoadDelegate, ExtensionSelectionDelegate {
  func deviceDidChange() {
    // Reload sections to update device display
    populateSections()
  }

  func groupDidChange() {
    // Save configuration changes
    // In C++: _config->SaveConfig()
  }

  func profileDidLoad() {
    // Reload sections after profile load
    populateSections()
  }

  func extensionDidChange() {
    // Reload sections to update extension display
    populateSections()
  }
}

// MARK: - Delegate Protocols

protocol DeviceSelectionDelegate: AnyObject {
  func deviceDidChange()
}

protocol GroupEditDelegate: AnyObject {
  func groupDidChange()
}

protocol ProfileLoadDelegate: AnyObject {
  func profileDidLoad()
}

protocol ExtensionSelectionDelegate: AnyObject {
  func extensionDidChange()
}

// MARK: - Supporting View Controllers

/// Programmatic device selection view controller
class DeviceSelectionViewController: UITableViewController {
  var mappingType: DOLMappingType = .DOLMappingTypePad
  var mappingPort: Int32 = 0
  weak var delegate: DeviceSelectionDelegate?

  private var devices: [String] = []
  private var selectedIndex: Int = -1

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("Device")

    // Register cell type
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")

    // Ensure DSU client is enabled on tvOS so DSU devices enumerate
    #if os(tvOS)
    if !DOLConfigBridge.dsuClientEnabled() { DOLConfigBridge.setDsuClientEnabled(true) }
    #endif

    // Observe device changes
    NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged), name: NSNotification.Name("TVControllerDevicesChangedNotification"), object: nil)
    TVControllerMappingBridge.beginPostingDevicesChangedNotifications()

    // Load available devices
    loadDevices()

    // Nudge device discovery and schedule a couple delayed reloads
    TVControllerMappingBridge.refreshDevices()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      TVControllerMappingBridge.refreshDevices()
      self.loadDevices()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      TVControllerMappingBridge.refreshDevices()
      self.loadDevices()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    TVControllerMappingBridge.endPostingDevicesChangedNotifications()
  }

  @objc private func devicesChanged() {
    loadDevices()
  }

  private func loadDevices() {
    // Enumerate devices via bridge
    devices = TVControllerMappingBridge.allQualifiedDevices() as [String]

    // tvOS: filter out iOS Touchscreen devices (not available on tvOS)
    #if os(tvOS)
    devices = devices.filter { !$0.hasPrefix("iOS/") }
    #endif

    // Sort with DSU first for visibility
    devices.sort { a, b in
      let aIsDSU = a.hasPrefix("DSUClient/")
      let bIsDSU = b.hasPrefix("DSUClient/")
      if aIsDSU != bIsDSU { return aIsDSU }
      return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    // Set current selection based on current default device
    let current = (mappingType == .DOLMappingTypePad)
      ? TVControllerMappingBridge.defaultDevice(forGCPort: Int(mappingPort + 1))
      : TVControllerMappingBridge.defaultDevice(forWiimote: Int(mappingPort + 1))
    selectedIndex = devices.firstIndex(of: current) ?? -1
    tableView.reloadData()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return devices.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
    let q = devices[indexPath.row]
    cell.textLabel?.text = friendlyName(forQualified: q)
    cell.detailTextLabel?.text = q
    cell.accessoryType = indexPath.row == selectedIndex ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    // Update selection and persist via bridge
    if selectedIndex != indexPath.row {
      selectedIndex = indexPath.row
      let qualified = devices[indexPath.row]
      if mappingType == .DOLMappingTypePad {
        TVControllerMappingBridge.setDefaultDevice(qualified, forGCPort: Int(mappingPort + 1))
      } else {
        TVControllerMappingBridge.setDefaultDevice(qualified, forWiimote: Int(mappingPort + 1))
      }

      // Auto-load a default profile for known device types and restore the device binding
      if let profile = defaultProfileName(forQualified: qualified) {
        if mappingType == .DOLMappingTypePad {
          _ = TVControllerMappingBridge.loadProfile(profile, forGCPort: Int(mappingPort + 1), restoreDevice: true)
        } else {
          _ = TVControllerMappingBridge.loadProfile(profile, forWiimote: Int(mappingPort + 1), restoreDevice: true)
        }
      }

      tableView.reloadData()
      delegate?.deviceDidChange()
    }
  }
}

private func friendlyName(forQualified q: String) -> String {
  //  if q.hasPrefix("DSUClient/") { return "DualShock UDP" }
  //  if q.hasPrefix("MFi/") { return "MFi Controller" }
  //  if q.hasPrefix("iOS/") { return "Touchscreen" }
  //  return q
  return q
}

private func defaultProfileName(forQualified q: String) -> String? {
  if q.hasPrefix("DSUClient/") { return "DSU" }
  if q.hasPrefix("iOS/") { return "Touchscreen" }
  if q.hasPrefix("MFi") { return "Physical Controller" }
  return nil
}

/// Programmatic group edit view controller
class GroupEditViewController: UITableViewController {
  var mappingType: DOLMappingType = .DOLMappingTypePad
  var mappingPort: Int32 = 0
  var groupName: String = ""
  weak var delegate: GroupEditDelegate?

  private var controls: [String] = []
  private var controlExpressions: [String] = []

  override func viewDidLoad() {
    super.viewDidLoad()

    // Register cell types
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ControlCell")

    // Load controls for this group
    loadControls()
  }

  private func loadControls() {
    // Query Dolphin for control names based on mapping type and group
    let groupId = groupIdForName(groupName)
    if mappingType == .DOLMappingTypePad {
      controls = TVControllerMappingBridge.padControlNames(forGroup: Int(mappingPort + 1), group: groupId)
      controlExpressions = TVControllerMappingBridge.padControlExpressions(forGroup: Int(mappingPort + 1), group: groupId)
    } else {
      controls = TVControllerMappingBridge.wiimoteControlNames(forGroup: Int(mappingPort + 1), group: groupId)
      controlExpressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Int(mappingPort + 1), group: groupId)
    }
    tableView.reloadData()
  }

  private func groupIdForName(_ name: String) -> Int {
    if mappingType == .DOLMappingTypePad {
      switch name {
      case L("Buttons"): return 0
      case L("D-Pad"): return 1
      case L("Control Stick"): return 2
      case L("C Stick"): return 3
      case L("Triggers"): return 4
      case L("Rumble"): return 5
      case L("Options"): return 6
      default: return 0
      }
    } else {
      switch name {
      case L("Buttons"): return 0
      case L("D-Pad"): return 1
      case L("IR"): return 2
      case L("Swing"): return 3
      case L("Tilt"): return 4
      case L("Shake"): return 5
      case L("Extension"): return 6
      case L("Rumble"): return 7
      case L("Options"): return 8
      default: return 0
      }
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return controls.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ControlCell", for: indexPath)
    cell.textLabel?.text = controls[indexPath.row]
    let expr = controlExpressions[safe: indexPath.row] ?? "—"
    cell.detailTextLabel?.text = expr
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    // Start input detection via MappingCommon dialog on UIKit controller
    let alert = UIAlertController(title: L("Press Input"), message: L("Press the input you want to map to \(controls[indexPath.row])"), preferredStyle: .alert)
    alert.addTextField { tf in tf.placeholder = L("Enter expression or press input") }
    alert.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: L("OK"), style: .default, handler: { _ in
      let expr = alert.textFields?.first?.text ?? ""
      guard !expr.isEmpty else { return }
      let groupId = self.groupIdForName(self.groupName)
      if self.mappingType == .DOLMappingTypePad {
        TVControllerMappingBridge.setPadControlExpressionForPort(Int(self.mappingPort + 1), group: groupId, index: indexPath.row, expression: expr)
        self.controlExpressions = TVControllerMappingBridge.padControlExpressions(forGroup: Int(self.mappingPort + 1), group: groupId)
      } else {
        TVControllerMappingBridge.setWiimoteControlExpressionFor(Int(self.mappingPort + 1), group: groupId, index: indexPath.row, expression: expr)
        self.controlExpressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Int(self.mappingPort + 1), group: groupId)
      }
      self.tableView.reloadRows(at: [indexPath], with: .automatic)
    }))
    present(alert, animated: true)
  }
}

/// Programmatic profile load view controller
class ProfileLoadViewController: UITableViewController {
  var mappingType: DOLMappingType = .DOLMappingTypePad
  var mappingPort: Int32 = 0
  weak var delegate: ProfileLoadDelegate?

  private var profiles: [String] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("Load")

    // Add cancel button
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelPressed))

    // Register cell type
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProfileCell")

    // Load available profiles
    loadProfiles()
  }

  @objc private func cancelPressed() {
    dismiss(animated: true)
  }

  private func loadProfiles() {
    if mappingType == .DOLMappingTypePad {
      profiles = TVControllerMappingBridge.profiles(forGCPort: Int(mappingPort + 1))
    } else {
      profiles = TVControllerMappingBridge.profiles(forWiimote: Int(mappingPort + 1))
    }
    tableView.reloadData()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return profiles.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ProfileCell", for: indexPath)
    cell.textLabel?.text = profiles[indexPath.row]
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    // Load the selected profile
    let name = profiles[indexPath.row]
    let ok: Bool
    if mappingType == .DOLMappingTypePad {
      ok = TVControllerMappingBridge.loadProfile(name, forGCPort: Int(mappingPort + 1), restoreDevice: true)
    } else {
      ok = TVControllerMappingBridge.loadProfile(name, forWiimote: Int(mappingPort + 1), restoreDevice: true)
    }
    if ok { delegate?.profileDidLoad() }
    dismiss(animated: true)
  }
}

/// Programmatic extension selection view controller
class ExtensionSelectionViewController: UITableViewController {
  var mappingType: DOLMappingType = .DOLMappingTypePad
  var mappingPort: Int32 = 0
  weak var delegate: ExtensionSelectionDelegate?

  private var extensions: [String] = []
  private var selectedIndex: Int = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("Extension")

    // Register cell type
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ExtensionCell")

    // Load available extensions
    loadExtensions()
  }

  private func loadExtensions() {
    // Wii Remote extensions via bridge
    extensions = TVControllerMappingBridge.wiimoteAttachmentDisplayNames(for: Int(mappingPort + 1))
    selectedIndex = TVControllerMappingBridge.selectedWiimoteAttachment(for: Int(mappingPort + 1))
    tableView.reloadData()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return extensions.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ExtensionCell", for: indexPath)
    cell.textLabel?.text = extensions[indexPath.row]
    cell.accessoryType = indexPath.row == selectedIndex ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    // Update selection and persist via bridge
    if selectedIndex != indexPath.row {
      selectedIndex = indexPath.row
      TVControllerMappingBridge.setSelectedWiimoteAttachment(selectedIndex, forWiimote: Int(mappingPort + 1))
      tableView.reloadData()
      delegate?.extensionDidChange()
    }
  }
}

/// Programmatic input display view controller
class InputDisplayViewController: UITableViewController {
  var mappingType: DOLMappingType = .DOLMappingTypePad
  var mappingPort: Int32 = 0

  private var inputs: [(String, String)] = [] // (name, value)
  private var updateTimer: Timer?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = L("Input Display")

    // Register cell type
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "InputCell")

    // Load inputs
    loadInputs()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    // Start update timer
    updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
      self.updateInputValues()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)

    // Stop update timer
    updateTimer?.invalidate()
    updateTimer = nil
  }

  private func loadInputs() {
    // Seed from current device names
    let qualified: String
    if mappingType == .DOLMappingTypePad {
      qualified = TVControllerMappingBridge.defaultDevice(forGCPort: Int(mappingPort + 1))
    } else {
      qualified = TVControllerMappingBridge.defaultDevice(forWiimote: Int(mappingPort + 1))
    }
    if !qualified.isEmpty {
      let names = TVControllerMappingBridge.inputs(forQualifiedDevice: qualified)
      inputs = names.map { ($0, "0.00") }
    } else {
      inputs.removeAll()
    }
    tableView.reloadData()
  }

  private func groupIdForName(_ name: String) -> Int {
    if mappingType == .DOLMappingTypePad {
      switch name {
      case L("Buttons"): return 0
      case L("D-Pad"): return 1
      case L("Control Stick"): return 2
      case L("C Stick"): return 3
      case L("Triggers"): return 4
      case L("Rumble"): return 5
      case L("Options"): return 6
      default: return 0
      }
    } else {
      switch name {
      case L("Buttons"): return 0
      case L("D-Pad"): return 1
      case L("IR"): return 2
      case L("Swing"): return 3
      case L("Tilt"): return 4
      case L("Shake"): return 5
      case L("Extension"): return 6
      case L("Rumble"): return 7
      case L("Options"): return 8
      default: return 0
      }
    }
  }

  private func updateInputValues() {
    // Read states from the current default device via bridge when possible
    let qualified: String
    if mappingType == .DOLMappingTypePad {
      qualified = TVControllerMappingBridge.defaultDevice(forGCPort: Int(mappingPort + 1))
    } else {
      qualified = TVControllerMappingBridge.defaultDevice(forWiimote: Int(mappingPort + 1))
    }
    if !qualified.isEmpty {
      let names = TVControllerMappingBridge.inputs(forQualifiedDevice: qualified)
      let values = TVControllerMappingBridge.inputStates(forQualifiedDevice: qualified)
      inputs = zip(names, values).map { ($0.0, String(format: "%.2f", $0.1.floatValue)) }
    } else {
      inputs.removeAll()
    }
    tableView.reloadData()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return inputs.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "InputCell", for: indexPath)
    let input = inputs[indexPath.row]
    cell.textLabel?.text = input.0
    cell.detailTextLabel?.text = input.1
    return cell
  }
}

// Note: DOLMappingType is provided to Swift by the bridged ObjC header
// (MappingRootViewController.h), kept on the tvOS bridging-header path for exactly
// this purpose. No Swift redeclaration — that was the second half of the name clash.

#endif

// MARK: - Array Safe Subscript Extension

private extension Array {
  subscript(safe index: Index) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}
