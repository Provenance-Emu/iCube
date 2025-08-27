// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "AudioSessionManager.h"
#import "BootNoticeManager.h"
#import "DolphinCoreService.h"
#import "EmulationCoordinator.h"
#if !TARGET_OS_TV
#import "FirebaseService.h"
#endif
#import "FirstRunInitializationService.h"
#import "GameFileCacheManager.h"
#import "JitManager.h"
#import "JitManager+AltServer.h"
#import "JitManager+JitStreamer.h"
#import "JitManager+PTrace.h"
#import "LegacyInputConfigMigrationService.h"
#import "MainSceneCoordinator.h"
#import "UpdateNoticeViewController.h"
#import "UpdateRequiredNoticeViewController.h"
#import "FastmemManager.h"

#if TARGET_OS_TV
#import "EmuEventVC.h"
#import "TCManagerInterface.h"
#import "InputOverriderBridge.h"
#endif

#if TARGET_OS_IOS
#import "DOLUIKitSwitch.h"
#endif

// SwiftUI tvOS bridges
#import "TVGameItem.h"
#import "TVLibraryBridge.h"
#import "TVEmulationBridge.h"
#import "DOLConfigBridge.h"
#import "DOLPathsBridge.h"
#import "TVCheatsBridge.h"
#import "TVControllerMappingBridge.h"
