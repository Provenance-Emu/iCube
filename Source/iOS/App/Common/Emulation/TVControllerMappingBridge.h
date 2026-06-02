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
+ (void)assignController:(GCController*)controller toGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(assign(_:toGCPort:));
+ (NSString*)defaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(defaultDevice(forGCPort:));
+ (void)clearDefaultDeviceForGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(clearDefaultDevice(forGCPort:));

/// Assign the iOS Touchscreen virtual device as the default device for a GC port.
+ (void)assignTouchscreenToGCPort:(NSInteger)portOneBased NS_SWIFT_NAME(assignTouchscreen(toGCPort:));

/// Reconciles default devices against currently connected controllers, removing phantom devices
/// and reassigning Player 1 to a connected controller when possible.
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
