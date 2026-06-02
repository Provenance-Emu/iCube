// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.mm

#import "DOLSettingsKeyBridge.h"
#import "DOLConfigBridge.h"

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DOLSettingType) {
  DOLSettingTypeBool,
  DOLSettingTypeInt,
  DOLSettingTypeFloat,
  DOLSettingTypeString,
};

typedef id _Nonnull (^DOLGetterBlock)(void);
typedef void (^DOLSetterBlock)(id value);

// One entry per settable key.
@interface DOLSettingEntry : NSObject
@property(nonatomic) DOLSettingType type;
@property(nonatomic) BOOL hotSwappable;
@property(nonatomic, copy) DOLGetterBlock getter;
@property(nonatomic, copy) DOLSetterBlock setter;
@end

@implementation DOLSettingEntry
@end

@implementation DOLSettingsKeyBridge

// MARK: - Value coercion helpers

static BOOL CoerceBool(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
  if ([v isKindOfClass:[NSString class]]) {
    NSString* s = [(NSString*)v lowercaseString];
    return [s isEqualToString:@"true"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
  }
  return NO;
}

static NSInteger CoerceInt(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString*)v integerValue];
  return 0;
}

static float CoerceFloat(id v) {
  if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
  if ([v isKindOfClass:[NSString class]]) return [(NSString*)v floatValue];
  return 0.0f;
}

static NSString* CoerceString(id v) {
  if ([v isKindOfClass:[NSString class]]) return v;
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v stringValue];
  return @"";
}

// MARK: - Key table

// The table is the single source of truth for which settings the debug API
// can read/write and how each is dispatched. To add a key, add one entry.
//
// hotSwappable classification rationale:
//  - Renderer backend, EFB internal-resolution scale, MMU, CPU core, fastmem,
//    RAM/MEM overrides, accurate CPU cache, dual-core (CPU thread), DSP thread,
//    backend multithreading, and shader-cache toggles are read at boot /
//    backend-init time. Changing them mid-run is a no-op until reboot -> tagged
//    boot-time (hotSwappable = NO). A sweep over any of these MUST reload the
//    save state / reboot the title.
//  - Per-frame render toggles and limiter/audio params (vsync, emulation speed,
//    volume, the perf-stat overlays, fog, widescreen hack, anisotropy*) are
//    consumed each frame and apply live -> hotSwappable = YES.
//    (*anisotropy is applied live by ThermalManager via resizeSurfaceNow, so
//     it's treated as hot-swappable here; if a future backend caches sampler
//     state at boot, reclassify it.)
//
// ASSUMPTION (could not verify against the running backend): the precise
// boot-time vs live behavior of each Config key is inferred from Dolphin
// semantics + how DOLConfigBridge/ThermalManager use them, not from a runtime
// probe. Joe should sanity-check the boot-time set against the actual core
// before trusting sweep deltas on borderline keys.

+ (NSDictionary<NSString*, DOLSettingEntry*>*)table {
  static NSDictionary<NSString*, DOLSettingEntry*>* table = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary<NSString*, DOLSettingEntry*>* t = [NSMutableDictionary dictionary];

    DOLSettingEntry* (^mk)(DOLSettingType, BOOL, DOLGetterBlock, DOLSetterBlock) =
      ^DOLSettingEntry*(DOLSettingType type, BOOL hot, DOLGetterBlock g, DOLSetterBlock s) {
        DOLSettingEntry* e = [DOLSettingEntry new];
        e.type = type;
        e.hotSwappable = hot;
        e.getter = g;
        e.setter = s;
        return e;
      };

    // ---- Boot-time (hotSwappable = NO) ----
    t[@"gfxBackend"] = mk(DOLSettingTypeString, NO,
      ^id{ return [DOLConfigBridge gfxBackend]; },
      ^(id v){ [DOLConfigBridge setGfxBackend:CoerceString(v)]; });

    t[@"gfxEfbScale"] = mk(DOLSettingTypeInt, NO,
      ^id{ return @([DOLConfigBridge gfxEfbScale]); },
      ^(id v){ [DOLConfigBridge setGfxEfbScale:CoerceInt(v)]; });

    t[@"mainCpuCore"] = mk(DOLSettingTypeInt, NO,
      ^id{ return @([DOLConfigBridge mainCpuCore]); },
      ^(id v){ [DOLConfigBridge setMainCpuCore:CoerceInt(v)]; });

    t[@"mainMMU"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainMMU]); },
      ^(id v){ [DOLConfigBridge setMainMMU:CoerceBool(v)]; });

    t[@"mainFastmem"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainFastmem]); },
      ^(id v){ [DOLConfigBridge setMainFastmem:CoerceBool(v)]; });

    t[@"mainCpuThread"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainCpuThread]); },
      ^(id v){ [DOLConfigBridge setMainCpuThread:CoerceBool(v)]; });

    t[@"mainDSPThread"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainDSPThread]); },
      ^(id v){ [DOLConfigBridge setMainDSPThread:CoerceBool(v)]; });

    t[@"mainAccurateCpuCache"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainAccurateCpuCache]); },
      ^(id v){ [DOLConfigBridge setMainAccurateCpuCache:CoerceBool(v)]; });

    t[@"mainRamOverrideEnable"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge mainRamOverrideEnable]); },
      ^(id v){ [DOLConfigBridge setMainRamOverrideEnable:CoerceBool(v)]; });

    t[@"gfxBackendMultithreading"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxBackendMultithreading]); },
      ^(id v){ [DOLConfigBridge setGfxBackendMultithreading:CoerceBool(v)]; });

    t[@"gfxShaderCache"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxShaderCache]); },
      ^(id v){ [DOLConfigBridge setGfxShaderCache:CoerceBool(v)]; });

    t[@"gfxWaitForShadersBeforeStarting"] = mk(DOLSettingTypeBool, NO,
      ^id{ return @([DOLConfigBridge gfxWaitForShadersBeforeStarting]); },
      ^(id v){ [DOLConfigBridge setGfxWaitForShadersBeforeStarting:CoerceBool(v)]; });

    // ---- Hot-swappable (hotSwappable = YES) ----
    t[@"gfxVSync"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxVSync]); },
      ^(id v){ [DOLConfigBridge setGfxVSync:CoerceBool(v)]; });

    t[@"mainEmulationSpeedPercent"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge mainEmulationSpeedPercent]); },
      ^(id v){ [DOLConfigBridge setMainEmulationSpeedPercent:CoerceInt(v)]; });

    t[@"audioVolume"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge audioVolume]); },
      ^(id v){ [DOLConfigBridge setAudioVolume:CoerceInt(v)]; });

    t[@"gfxWidescreenHack"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxWidescreenHack]); },
      ^(id v){ [DOLConfigBridge setGfxWidescreenHack:CoerceBool(v)]; });

    t[@"gfxDisableFog"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxDisableFog]); },
      ^(id v){ [DOLConfigBridge setGfxDisableFog:CoerceBool(v)]; });

    t[@"gfxEnhanceAnisotropySamples"] = mk(DOLSettingTypeInt, YES,
      ^id{ return @([DOLConfigBridge gfxEnhanceAnisotropySamples]); },
      ^(id v){ [DOLConfigBridge setGfxEnhanceAnisotropySamples:CoerceInt(v)]; });

    t[@"gfxShowFPS"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxShowFPS]); },
      ^(id v){ [DOLConfigBridge setGfxShowFPS:CoerceBool(v)]; });

    t[@"gfxHackSkipEfbCopyToRam"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxHackSkipEfbCopyToRam]); },
      ^(id v){ [DOLConfigBridge setGfxHackSkipEfbCopyToRam:CoerceBool(v)]; });

    t[@"gfxHackSkipXfbCopyToRam"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxHackSkipXfbCopyToRam]); },
      ^(id v){ [DOLConfigBridge setGfxHackSkipXfbCopyToRam:CoerceBool(v)]; });

    t[@"gfxCpuCull"] = mk(DOLSettingTypeBool, YES,
      ^id{ return @([DOLConfigBridge gfxCpuCull]); },
      ^(id v){ [DOLConfigBridge setGfxCpuCull:CoerceBool(v)]; });

    table = [t copy];
  });
  return table;
}

static NSString* TypeName(DOLSettingType type) {
  switch (type) {
    case DOLSettingTypeBool: return @"bool";
    case DOLSettingTypeInt: return @"int";
    case DOLSettingTypeFloat: return @"float";
    case DOLSettingTypeString: return @"string";
  }
  return @"string";
}

// MARK: - Public API

+ (NSDictionary<NSString*, NSDictionary<NSString*, id>*>*)snapshotAll {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSMutableDictionary<NSString*, NSDictionary<NSString*, id>*>* out =
    [NSMutableDictionary dictionaryWithCapacity:table.count];
  [table enumerateKeysAndObjectsUsingBlock:^(NSString* key, DOLSettingEntry* e, BOOL* stop) {
    out[key] = @{
      @"value" : e.getter(),
      @"type" : TypeName(e.type),
      @"hotSwappable" : @(e.hotSwappable),
    };
  }];
  return out;
}

+ (NSArray<NSString*>*)bootTimeKeys {
  NSDictionary<NSString*, DOLSettingEntry*>* table = [self table];
  NSMutableArray<NSString*>* keys = [NSMutableArray array];
  [table enumerateKeysAndObjectsUsingBlock:^(NSString* key, DOLSettingEntry* e, BOOL* stop) {
    if (!e.hotSwappable) [keys addObject:key];
  }];
  return [keys sortedArrayUsingSelector:@selector(compare:)];
}

+ (BOOL)isHotSwappable:(NSString*)key {
  DOLSettingEntry* e = [self table][key];
  return e != nil && e.hotSwappable;
}

+ (BOOL)isKnownKey:(NSString*)key {
  return [self table][key] != nil;
}

+ (BOOL)setKey:(NSString*)key value:(id)value {
  DOLSettingEntry* e = [self table][key];
  if (e == nil || value == nil) return NO;
  e.setter(value);
  return YES;
}

@end
