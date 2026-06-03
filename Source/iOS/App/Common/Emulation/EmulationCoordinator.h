// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class EmulationBootParameter;
@class UIView;

NSString* _Nonnull const DOLEmulationDidStartNotification = @"DOLEmulationDidStartNotification";
NSString* _Nonnull const DOLEmulationDidEndNotification = @"DOLEmulationDidEndNotification";

NS_ASSUME_NONNULL_BEGIN

@interface EmulationCoordinator : NSObject

+ (EmulationCoordinator*)shared;

@property (nonatomic, setter=setIsExternalDisplayConnected:) bool isExternalDisplayConnected;
@property (nonatomic) bool userRequestedPause;

- (void)registerMainDisplayView:(UIView*)mainView;
- (void)registerExternalDisplayView:(UIView*)externalView;
- (void)runEmulationWithBootParameter:(EmulationBootParameter*)bootParameter;
- (void)clearMetalLayer;

/// Expose the current main display view used for rendering
- (nullable UIView*)mainDisplayView;

/// The scale that feeds the render surface's drawableSize and `wsi.render_surface_scale`
/// (i.e. the backbuffer_scale the video backend uses). Accounts for the force-scale-1 preference,
/// so it is NOT always UIScreen.scale. Use this to convert UIKit points to backbuffer pixels.
- (CGFloat)currentRenderSurfaceScale;

/// Ensures GameCube Pad 1 is bound to the iOS Touchscreen when no default device is connected.
/// Also provides auto-assignment for newly connected external controllers.
+ (void)ensurePad1DefaultsToTouchscreen;
/// Assign the most recently connected external controller to the first available player slot
/// that is not already bound to a connected physical controller (ignores touchscreen bindings).
+ (void)autoAssignNewestExternalControllerToFirstAvailableSlot;

// Ensure a given Wiimote port (1-based) is set to Emulated and uses the iOS Touchscreen profile
+ (void)ensureWiimoteDefaultsToTouchscreenForPort:(NSInteger)portOneBased;

/// Live adaptive-clock (auto) toggle. Writes the `adaptive_clock_enable` NSUserDefault and either
/// starts the controller immediately (ON) or stops/invalidates its timer and clears the CurrentRun
/// overclock overrides (OFF) — takes effect without relaunching the game.
- (void)setAdaptiveClockEnabled:(BOOL)on;

/// Build a chat-ready plaintext state dump (GAME / HARDWARE / LIVE PERF / SETTINGS) and place it on
/// the general pasteboard. Used by the "Copy State" button in the in-emulation perf overlay.
+ (void)copyStateToClipboard;

@end

NS_ASSUME_NONNULL_END
