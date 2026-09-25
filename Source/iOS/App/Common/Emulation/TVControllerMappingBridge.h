// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#import <GameController/GCExtendedGamepad.h>
#import <GameController/GCMicroGamepad.h>
#import <GameController/GCKeyboard.h>
#import <GameController/GCDeviceHaptics.h>
#import <GameController/GCDualShockGamepad.h>
#import <GameController/GCDualSenseGamepad.h>
#import <GameController/GCXboxGamepad.h>
#else
#import <GameController/GameController.h>
#endif

NS_ASSUME_NONNULL_BEGIN

extern NSString* const TVControllerDevicesChangedNotification;

@interface TVControllerMappingBridge : NSObject

+ (NSString*)qualifiedNameForController:(GCController*)controller NS_SWIFT_NAME(qualifiedName(for:));
+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(defaultDevice(forGCPort:));
+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(clearDefaultDevice(forGCPort:));

/// True when the GC pad slot's emulated controller has at least one non-empty
/// control expression bound — i.e. it has a real mapping, not just an
/// activated-but-unconfigured default. `reconcileAssignments` clears a
/// disconnected device's default-device binding but never touches these
/// expressions, so this stays true across a reconnect. Used by
/// `ControllerAssignmentService.assign` to decide whether re-binding a device
/// should reload the device-default profile or keep the existing mapping.
+ (BOOL)padHasAnyBinding:(NSInteger)portOneBased NS_SWIFT_NAME(padHasAnyBinding(forGCPort:));

/// Wiimote counterpart of `padHasAnyBinding:`.
+ (BOOL)wiimoteHasAnyBinding:(NSInteger)indexOneBased NS_SWIFT_NAME(wiimoteHasAnyBinding(forWiimote:));

/// Assign the iOS Touchscreen virtual device as the default device for a GC port.
+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(assignTouchscreen(toGCPort:));

/// Mechanical only: drops default-device bindings that point at devices the
/// ControllerInterface no longer enumerates, so the Swift AssignmentEngine sees
/// an accurate snapshot. This never chooses a port and never assigns a device.
+ (void)reconcileAssignments;

/// Enumerate all input devices' qualified names that are valid for mapping (iOS, MFi, DSU)
+ (NSArray<NSString*>*)allQualifiedDevices;

/// Get/set default device for GC Pad (1-based port)
+ (void)setDefaultDevice:(NSString*)qualified forGCPort:(NSInteger)portOneBased;

/// Get/set default device for Wiimote (1-based index)
+ (NSString*)defaultDeviceForWiimote:(NSInteger)indexOneBased NS_SWIFT_NAME(defaultDevice(forWiimote:));
+ (void)setDefaultDevice:(NSString*)qualified forWiimote:(NSInteger)indexOneBased NS_SWIFT_NAME(setDefaultDevice(_:forWiimote:));

/// Input display: names and states for a qualified device
+ (NSArray<NSString*>*)inputsForQualifiedDevice:(NSString*)qualified;
+ (NSArray<NSNumber*>*)inputStatesForQualifiedDevice:(NSString*)qualified;

/// Wiimote attachments (extension) API for a Wiimote index (1-based)
+ (NSArray<NSString*>*)wiimoteAttachmentDisplayNamesForIndex:(NSInteger)indexOneBased;
+ (NSInteger)selectedWiimoteAttachmentForIndex:(NSInteger)indexOneBased;
+ (void)setSelectedWiimoteAttachment:(NSInteger)attachmentIndex forWiimote:(NSInteger)indexOneBased;

/// Profiles (enumeration and loading)
+ (NSArray<NSString*>*)profilesForGCPort:(NSInteger)portOneBased;
+ (NSArray<NSString*>*)profilesForWiimote:(NSInteger)indexOneBased;
+ (BOOL)loadProfile:(NSString*)name forGCPort:(NSInteger)portOneBased restoreDevice:(BOOL)restore;
+ (BOOL)loadProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased restoreDevice:(BOOL)restore;

/// Profiles (saving). Writes the live pad/Wiimote config to
/// `<user profile dir>/<name>.ini` — always the user directory, never the sys
/// directory, so the bundled profiles are never overwritten in place. Returns
/// NO when the controller does not exist or the file could not be written.
+ (BOOL)saveProfile:(NSString*)name forGCPort:(NSInteger)portOneBased;
+ (BOOL)saveProfile:(NSString*)name forWiimote:(NSInteger)indexOneBased;

/// Device hotplug notifications
+ (void)beginPostingDevicesChangedNotifications;
+ (void)endPostingDevicesChangedNotifications;
+ (void)refreshDevices;

/// Control group editing (Pad)
+ (NSArray<NSString*>*)padControlNamesForGroup:(NSInteger)portOneBased group:(NSInteger)groupId NS_SWIFT_NAME(padControlNames(forGroup:group:));
+ (NSArray<NSString*>*)padControlExpressionsForGroup:(NSInteger)portOneBased group:(NSInteger)groupId NS_SWIFT_NAME(padControlExpressions(forGroup:group:));
+ (void)setPadControlExpressionForPort:(NSInteger)portOneBased group:(NSInteger)groupId index:(NSInteger)controlIndex expression:(NSString*)expression;

/// Control group editing (Wiimote)
+ (NSArray<NSString*>*)wiimoteControlNamesForGroup:(NSInteger)indexOneBased group:(NSInteger)groupId NS_SWIFT_NAME(wiimoteControlNames(forGroup:group:));
+ (NSArray<NSString*>*)wiimoteControlExpressionsForGroup:(NSInteger)indexOneBased group:(NSInteger)groupId NS_SWIFT_NAME(wiimoteControlExpressions(forGroup:group:));
+ (void)setWiimoteControlExpressionForIndex:(NSInteger)indexOneBased group:(NSInteger)groupId index:(NSInteger)controlIndex expression:(NSString*)expression NS_SWIFT_NAME(setWiimoteControlExpressionFor(_:group:index:expression:));

@end

NS_ASSUME_NONNULL_END
