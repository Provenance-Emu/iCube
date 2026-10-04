// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class EmulationBootParameter;
@class UIScreen;
@class UIView;

FOUNDATION_EXPORT NSString* _Nonnull const DOLEmulationWillStartNotification;
FOUNDATION_EXPORT NSString* _Nonnull const DOLEmulationDidStartNotification;
FOUNDATION_EXPORT NSString* _Nonnull const DOLEmulationDidEndNotification;
FOUNDATION_EXPORT NSString* _Nonnull const DOLExternalDisplayDidChangeNotification;

NS_ASSUME_NONNULL_BEGIN

@interface EmulationCoordinator : NSObject

+ (EmulationCoordinator*)shared;

@property (nonatomic, setter=setIsExternalDisplayConnected:) bool isExternalDisplayConnected;
@property (nonatomic) bool userRequestedPause;

// Auto-pause emulation when the app is backgrounded/interrupted, and resume on return.
// Distinct from userRequestedPause: a manual pause survives a background round-trip.
- (void)pauseForBackground;
- (void)resumeFromBackground;

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

/// UIScreen hosting the Metal render surface (external display when connected, else main).
- (UIScreen*)activeRenderScreen;

/// YES on tvOS (main TV) or when an iOS external display scene is connected.
- (BOOL)isOverscanCompensationApplicable;

/// User preference `gfx_overscan_fullscreen`: when YES, sets overscanCompensation to .none.
- (BOOL)overscanFullscreenEnabled;
- (void)setOverscanFullscreenEnabled:(BOOL)enabled;

/// Applies the overscan preference to the active render screen when applicable.
- (void)applyOverscanCompensationPreference;

// Ensure a given Wiimote port (1-based) is set to Emulated and uses the iOS Touchscreen profile.
// Mechanical: every assignment policy, the pre-boot fallbacks included, lives in the Swift
// `AssignmentEngine` (`ControllerManager.reconcile()`, `ControllerManager.prepareForBoot`).
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
