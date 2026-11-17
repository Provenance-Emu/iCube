// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_MACCATALYST

NS_ASSUME_NONNULL_BEGIN

/// One row of the menu-bar menu.
@interface ICMacMenuEntry : NSObject
@property(nonatomic, copy, readonly) NSString* title;
@property(nonatomic, readonly) BOOL checked;
@property(nonatomic, readonly, getter=isSeparator) BOOL separator;
/// Nil for a row that only shows text.
@property(nonatomic, copy, readonly, nullable) void (^handler)(void);

+ (instancetype)separatorEntry NS_SWIFT_NAME(separator());
+ (instancetype)entryWithTitle:(NSString*)title checked:(BOOL)checked handler:(nullable void (^)(void))handler
    NS_SWIFT_NAME(init(title:checked:handler:));
@end

/// The few things the Mac build needs from AppKit that UIKit has no equivalent for: an item in the
/// menu bar, and activating or quitting the app. Main thread only.
@interface ICMacAppKitBridge : NSObject
/// False when AppKit's status bar could not be reached; the app then behaves as it does without one.
+ (BOOL)installStatusItemWithSymbolName:(NSString*)symbolName toolTip:(NSString*)toolTip;
+ (void)setStatusMenuEntries:(NSArray<ICMacMenuEntry*>*)entries;
+ (void)activateApp;
+ (void)terminateApp;
@end

NS_ASSUME_NONNULL_END

#endif
