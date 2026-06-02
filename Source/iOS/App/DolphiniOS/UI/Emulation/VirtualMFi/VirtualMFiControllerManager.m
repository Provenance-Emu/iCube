// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "VirtualMFiControllerManager.h"

#if TARGET_OS_MACCATALYST
#import <GameController/GCController.h>
#import <GameController/GCExtendedGamepad.h>
#import <GameController/GCMicroGamepad.h>
#import <GameController/GCDeviceHaptics.h>
#import <GameController/GCDualShockGamepad.h>
#import <GameController/GCDualSenseGamepad.h>
#import <GameController/GCXboxGamepad.h>
#else
#import <GameController/GameController.h>
#endif

@interface VirtualMFiControllerManager ()

@end

@implementation VirtualMFiControllerManager {
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
  GCVirtualController* _controller API_AVAILABLE(ios(15.0));
#endif
  bool _isControllerConnected;
}

+ (VirtualMFiControllerManager*)shared {
  static VirtualMFiControllerManager* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (id)init {
  if (self = [super init]) {
    if (@available(iOS 15.0, *)) {
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
      GCVirtualControllerConfiguration* configuration = [[GCVirtualControllerConfiguration alloc] init];
      configuration.elements = [NSSet setWithArray:@[
        GCInputButtonA,
        GCInputButtonB,
        GCInputButtonX,
        GCInputButtonY,
        GCInputLeftThumbstick,
        GCInputRightThumbstick,
        GCInputLeftShoulder,
        GCInputRightShoulder,
        GCInputLeftTrigger,
        GCInputRightTrigger
      ]];

      _controller = [GCVirtualController virtualControllerWithConfiguration:configuration];
#endif
    }
  }

  return self;
}

- (void)connectControllerToView:(UIView*)superview {
  // Yes, this is a gigantic hack. Unfortunately, GCVirtualController likes to attach to the wrong view (UITabBarController),
  // so we need to manually override that by adding it to the requesting controller.
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
  if (_isControllerConnected) {
    return;
  }

  if (_controller == nil) {
    NSLog(@"VirtualMFiControllerManager: GCVirtualController unavailable (requires iOS 15.0)");
    return;
  }

  [_controller connectWithReplyHandler:^(NSError* error) {
    if (error != nil) {
      NSLog(@"Failed to connect GCVirtualController with error: %@", [error localizedDescription]);
    } else {
      self->_isControllerConnected = true;
      id<VirtualMFiControllerManagerDelegate> delegate = self.delegate;
      if (delegate && [delegate respondsToSelector:@selector(virtualMFiControllerDidConnect)]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate virtualMFiControllerDidConnect]; });
      }
    }
  }];
#endif
}

- (void)disconnectController {
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
  if (_controller == nil || !_isControllerConnected) {
    return;
  }

  [_controller disconnect];
#endif

  _isControllerConnected = false;
  id<VirtualMFiControllerManagerDelegate> delegate = self.delegate;
  if (delegate && [delegate respondsToSelector:@selector(virtualMFiControllerDidDisconnect)]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate virtualMFiControllerDidDisconnect]; });
  }
}

@end
