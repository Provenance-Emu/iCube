// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "MappingDeviceViewController.h"

#import <string>
#import <vector>
#include <mutex>

#import "Common/FileUtil.h"

#import "InputCommon/ControllerEmu/ControllerEmu.h"
#import "InputCommon/ControllerInterface/ControllerInterface.h"
#import "InputCommon/InputConfig.h"

#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"
#import "MappingDeviceCell.h"
#import "MappingDeviceViewControllerDelegate.h"

struct Device {
  std::string actualName;
  std::string uiName;
};

@interface MappingDeviceViewController ()

@end

@implementation MappingDeviceViewController {
  NSInteger _lastSelected;
  std::vector<std::string> _devices;
  NSMutableArray<NSString*>* _deviceNames;
  std::mutex _devicesMutex;
  ControllerInterface::HotplugCallbackHandle _hotplugHandle;
  BOOL _hotplugRegistered;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  _deviceNames = [[NSMutableArray alloc] init];
  _hotplugRegistered = NO;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [self repopulateDevices];
  if (!_hotplugRegistered && g_controller_interface.IsInit()) {
    __weak MappingDeviceViewController* weakSelf = self;
    _hotplugHandle = g_controller_interface.RegisterDevicesChangedCallback([weakSelf](){
      MappingDeviceViewController* strongSelf = weakSelf;
      if (!strongSelf) return;
      dispatch_async(dispatch_get_main_queue(), ^{
        [strongSelf repopulateDevices];
      });
    });
    _hotplugRegistered = YES;
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (_hotplugRegistered) {
    g_controller_interface.UnregisterDevicesChangedCallback(_hotplugHandle);
    _hotplugRegistered = NO;
  }
}

- (void)repopulateDevices {
  // Build device lists under lock, then reload UI after unlocking to avoid deadlock
  {
    std::lock_guard<std::mutex> lock(_devicesMutex);
    _devices.clear();
    [_deviceNames removeAllObjects];

    g_controller_interface.RefreshDevices();

    for (const auto& name : g_controller_interface.GetAllDeviceStrings()) {
      if (self.filterType != DOLDeviceFilterNone) {
        ciface::Core::DeviceQualifier qualifier;
        qualifier.FromString(name);

        if (qualifier.source == "iOS" && qualifier.name == "Touchscreen") {
          // Don't list unnecessary Touchscreen devices depending on the filter type.
          if ((self.filterType == DOLDeviceFilterTouchscreenExceptPad && qualifier.cid != 0)
              || (self.filterType == DOLDeviceFilterTouchscreenExceptWii && qualifier.cid != 4)
              || self.filterType == DOLDeviceFilterTouchscreenAll) {
            continue;
          }
        }
      }

      _devices.push_back(name);
      [_deviceNames addObject:CppToFoundationString(name)];
    }

    _lastSelected = -1;

    const std::string defaultDevice = self.emulatedController->GetDefaultDevice().ToString();

    if (!defaultDevice.empty()) {
      for (int i = 0; i < _devices.size(); i++) {
        if (_devices[i] == defaultDevice) {
          _lastSelected = i;
        }
      }

      if (_lastSelected == -1) {
        _devices.push_back(defaultDevice);

        NSString* foundationDeviceName = CppToFoundationString(defaultDevice);
        [_deviceNames addObject:[NSString stringWithFormat:@"[%@] %@", DOLCoreLocalizedString(@"disconnected"), foundationDeviceName]];

        _lastSelected = _devices.size() - 1;
      }
    }
  }

  [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  std::lock_guard<std::mutex> lock(_devicesMutex);
  return (NSInteger)_devices.size();
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  MappingDeviceCell* cell = [tableView dequeueReusableCellWithIdentifier:@"DeviceCell" forIndexPath:indexPath];

  NSString* name = nil;
  NSInteger last = -1;
  {
    std::lock_guard<std::mutex> lock(_devicesMutex);
    if (indexPath.row < _deviceNames.count) {
      name = _deviceNames[indexPath.row];
    }
    last = _lastSelected;
  }

  cell.deviceLabel.text = name ?: @"";
  cell.accessoryType = (indexPath.row == last) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  std::string device;
  NSInteger previous = -1;
  {
    std::lock_guard<std::mutex> lock(_devicesMutex);
    if (indexPath.row < _devices.size()) {
      device = _devices[indexPath.row];
    }
    previous = _lastSelected;
  }

  if (previous != indexPath.row && !device.empty()) {
    ciface::Core::DeviceQualifier qualifier;
    qualifier.FromString(device);

    // Remember selected device before any profile loads
    const std::string selectedDevice = device;
    self.emulatedController->SetDefaultDevice(selectedDevice);
    self.emulatedController->UpdateReferences(g_controller_interface);

    MappingDeviceCell* cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryCheckmark;

    if (previous != -1) {
      MappingDeviceCell* oldCell = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:previous inSection:0]];
      oldCell.accessoryType = UITableViewCellAccessoryNone;
    }

    {
      std::lock_guard<std::mutex> lock(_devicesMutex);
      _lastSelected = indexPath.row;
    }

    bool isTouchscreen = qualifier.source == "iOS";
    bool isMFiPhysicalController = qualifier.source == "MFi" && qualifier.name != "Keyboard";
    bool isDSU = (qualifier.source == "DSUClient");
    if (isTouchscreen || isMFiPhysicalController || isDSU) {
      UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"Load Defaults" message:@"Would you like to load the default profile for this device type?\n\nWARNING: If you choose to proceed, your current configuration will be overwritten." preferredStyle:UIAlertControllerStyleAlert];

       [alertController addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) {
         std::string iniName;

        if (isTouchscreen) {
          iniName = "Touchscreen";
        } else if (isMFiPhysicalController) {
          iniName = "Physical Controller";
        } else {
          iniName = "DSU";
        }

         const std::string profilePath = self.inputConfig->GetSysProfileDirectoryPath() + iniName + ".ini";

         Common::IniFile iniFile;
         iniFile.Load(profilePath);

         self.emulatedController->LoadConfig(iniFile.GetOrCreateSection("Profile"));
        // Restore selected device in case profile specifies a different Device
        self.emulatedController->SetDefaultDevice(selectedDevice);
         self.emulatedController->UpdateReferences(g_controller_interface);
       }]];

      [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Load" style:UIAlertActionStyleCancel handler:nil]];

      [self presentViewController:alertController animated:true completion:nil];
    }

    [self.delegate deviceDidChange:self];
  }

  [tableView deselectRowAtIndexPath:indexPath animated:true];
}

@end
