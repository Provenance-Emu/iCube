// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class TVGameItem;

NS_ASSUME_NONNULL_BEGIN

/// The container a disc image is stored in (`DiscIO::BlobType`, reduced to what the patch flow tells apart).
typedef NS_ENUM(NSInteger, DOLDiscContainer) {
  DOLDiscContainerPlain,  ///< ISO / GCM, byte-patchable as is.
  DOLDiscContainerRVZ,
  DOLDiscContainerWIA,
  DOLDiscContainerGCZ,
  DOLDiscContainerWBFS,
  DOLDiscContainerCISO,
  DOLDiscContainerOther,  ///< Split, TGC, NFS, directory, drive: none of these can be patched.
};

/// `DiscIO::Platform`, reduced.
typedef NS_ENUM(NSInteger, DOLDiscPlatform) {
  DOLDiscPlatformGameCube,
  DOLDiscPlatformTriforce,
  DOLDiscPlatformWii,
  DOLDiscPlatformWiiWAD,
  DOLDiscPlatformExecutable,  ///< DOL or ELF.
  DOLDiscPlatformUnknown,
};

/// What DiscIO knows about an image, without booting it.
@interface DOLDiscImageInfo : NSObject
@property(nonatomic, readonly) DOLDiscContainer container;
@property(nonatomic, readonly) DOLDiscPlatform platform;
@property(nonatomic, readonly, copy) NSString* gameID;
@property(nonatomic, readonly) NSInteger revision;
@property(nonatomic, readonly) NSInteger discNumber;
@property(nonatomic, readonly) BOOL isNKit;
/// Size of the plain ISO this image expands to. Only an estimate unless `plainSizeIsExact`.
@property(nonatomic, readonly) uint64_t plainSize;
@property(nonatomic, readonly) BOOL plainSizeIsExact;
/// Size of the file on disk.
@property(nonatomic, readonly) uint64_t fileSize;
@end

/// Lets the caller stop a conversion that is running on another thread.
@interface DOLDiscConversionToken : NSObject
@property(nonatomic, readonly) BOOL isCancelled;
- (void)cancel;
@end

/// Called from the converting thread. `fraction` is 0...1.
typedef void (^DOLDiscConversionProgress)(double fraction);

/// Thin ObjC++ face on DiscIO for the disc patching flow.
@interface DiscImageBridge : NSObject

/// Opens the image at `path` and reads its identity. nil when DiscIO cannot read it.
+ (nullable DOLDiscImageInfo*)inspectImageAtPath:(NSString*)path NS_SWIFT_NAME(inspectImage(atPath:));

/// The same facts for a library entry, taken from its cached `GameFile` (no disc IO).
+ (nullable DOLDiscImageInfo*)infoForGameItem:(TVGameItem*)item NS_SWIFT_NAME(info(forGameItem:));

/// Writes the plain ISO behind `sourcePath` to `destinationPath` (`DiscIO::ConvertToPlain`). On
/// failure or cancellation the partial destination is removed and NO is returned.
+ (BOOL)convertToPlainFrom:(NSString*)sourcePath
                        to:(NSString*)destinationPath
                     token:(DOLDiscConversionToken*)token
                  progress:(DOLDiscConversionProgress)progress
                     error:(NSError* _Nullable* _Nullable)error NS_SWIFT_NAME(convertToPlain(from:to:token:progress:));

/// Writes `sourcePath` as RVZ (`DiscIO::ConvertToWIAOrRVZ`): zstd level 5, 128 KiB blocks, the
/// defaults of Dolphin's own convert dialog. Failure and cancellation behave as for plain.
+ (BOOL)convertToRVZFrom:(NSString*)sourcePath
                      to:(NSString*)destinationPath
                   token:(DOLDiscConversionToken*)token
                progress:(DOLDiscConversionProgress)progress
                   error:(NSError* _Nullable* _Nullable)error NS_SWIFT_NAME(convertToRVZ(from:to:token:progress:));

/// A library item for a disc file that is not in the library (a cached patched copy), so the
/// emulation screen can boot it. nil when the file is not a valid game.
+ (nullable TVGameItem*)gameItemForPath:(NSString*)path NS_SWIFT_NAME(gameItem(forPath:));

@end

NS_ASSUME_NONNULL_END
