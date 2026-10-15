// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DiscImageBridge.h"

#import <atomic>
#import <memory>
#import <optional>
#import <string>

#import "DiscIO/Blob.h"
#import "DiscIO/DiscUtils.h"
#import "DiscIO/Enums.h"
#import "DiscIO/Volume.h"
#import "UICommon/GameFile.h"

#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"

static NSString* const DOLDiscImageErrorDomain = @"DOLDiscImageBridge";

/// `DiscIO::WIARVZCompressionType::Zstd` (DiscIO/WIABlob.h). That header drags in the zstd and lzma
/// compressors, which the app target has no include path for, and Blob.h declares the enum opaquely
/// with a fixed underlying type, so naming the value is all that is needed.
static constexpr unsigned int kWIARVZZstd = 5;
/// The level Dolphin's convert dialog preselects for zstd.
static constexpr int kRVZCompressionLevel = 5;

static DOLDiscContainer ContainerForBlobType(DiscIO::BlobType type) {
  switch (type) {
    case DiscIO::BlobType::PLAIN:
      return DOLDiscContainerPlain;
    case DiscIO::BlobType::RVZ:
      return DOLDiscContainerRVZ;
    case DiscIO::BlobType::WIA:
      return DOLDiscContainerWIA;
    case DiscIO::BlobType::GCZ:
      return DOLDiscContainerGCZ;
    case DiscIO::BlobType::WBFS:
      return DOLDiscContainerWBFS;
    case DiscIO::BlobType::CISO:
      return DOLDiscContainerCISO;
    default:
      return DOLDiscContainerOther;
  }
}

static DOLDiscPlatform PlatformForVolumeType(DiscIO::Platform platform) {
  switch (platform) {
    case DiscIO::Platform::GameCubeDisc:
      return DOLDiscPlatformGameCube;
    case DiscIO::Platform::Triforce:
      return DOLDiscPlatformTriforce;
    case DiscIO::Platform::WiiDisc:
      return DOLDiscPlatformWii;
    case DiscIO::Platform::WiiWAD:
      return DOLDiscPlatformWiiWAD;
    case DiscIO::Platform::ELFOrDOL:
      return DOLDiscPlatformExecutable;
    default:
      return DOLDiscPlatformUnknown;
  }
}

@interface DOLDiscImageInfo ()
- (instancetype)initWithContainer:(DOLDiscContainer)container
                         platform:(DOLDiscPlatform)platform
                           gameID:(NSString*)gameID
                         revision:(NSInteger)revision
                       discNumber:(NSInteger)discNumber
                           isNKit:(BOOL)isNKit
                        plainSize:(uint64_t)plainSize
                 plainSizeIsExact:(BOOL)plainSizeIsExact
                         fileSize:(uint64_t)fileSize;
@end

@implementation DOLDiscImageInfo

- (instancetype)initWithContainer:(DOLDiscContainer)container
                         platform:(DOLDiscPlatform)platform
                           gameID:(NSString*)gameID
                         revision:(NSInteger)revision
                       discNumber:(NSInteger)discNumber
                           isNKit:(BOOL)isNKit
                        plainSize:(uint64_t)plainSize
                 plainSizeIsExact:(BOOL)plainSizeIsExact
                         fileSize:(uint64_t)fileSize {
  self = [super init];
  if (self) {
    _container = container;
    _platform = platform;
    _gameID = [gameID copy];
    _revision = revision;
    _discNumber = discNumber;
    _isNKit = isNKit;
    _plainSize = plainSize;
    _plainSizeIsExact = plainSizeIsExact;
    _fileSize = fileSize;
  }
  return self;
}

@end

@implementation DOLDiscConversionToken {
  std::atomic<bool> _cancelled;
}

- (BOOL)isCancelled {
  return _cancelled.load();
}

- (void)cancel {
  _cancelled.store(true);
}

@end

@implementation DiscImageBridge

+ (nullable DOLDiscImageInfo*)inspectImageAtPath:(NSString*)path {
  std::unique_ptr<DiscIO::BlobReader> reader = DiscIO::CreateBlobReader(std::string(path.UTF8String));
  if (!reader)
    return nil;
  const uint64_t fileSize = reader->GetRawSize();
  std::unique_ptr<DiscIO::Volume> volume = DiscIO::CreateVolume(std::move(reader));
  if (!volume)
    return nil;

  const std::optional<u16> revision = volume->GetRevision();
  const std::optional<u8> discNumber = volume->GetDiscNumber();
  return [[DOLDiscImageInfo alloc]
      initWithContainer:ContainerForBlobType(volume->GetBlobType())
               platform:PlatformForVolumeType(volume->GetVolumeType())
                 gameID:[NSString stringWithUTF8String:volume->GetGameID().c_str()] ?: @""
               revision:revision.value_or(0)
             discNumber:discNumber.value_or(0)
                 isNKit:volume->IsNKit()
              plainSize:volume->GetDataSize()
       plainSizeIsExact:volume->GetDataSizeType() == DiscIO::DataSizeType::Accurate
               fileSize:fileSize];
}

+ (nullable DOLDiscImageInfo*)infoForGameItem:(TVGameItem*)item {
  const std::shared_ptr<const UICommon::GameFile> file = item.wrapper.gameFile;
  if (!file || !file->IsValid())
    return nil;
  return [[DOLDiscImageInfo alloc]
      initWithContainer:ContainerForBlobType(file->GetBlobType())
               platform:PlatformForVolumeType(file->GetPlatform())
                 gameID:[NSString stringWithUTF8String:file->GetGameID().c_str()] ?: @""
               revision:file->GetRevision()
             discNumber:file->GetDiscNumber()
                 isNKit:file->IsNKit()
              plainSize:file->GetVolumeSize()
       plainSizeIsExact:file->GetVolumeSizeType() == DiscIO::DataSizeType::Accurate
               fileSize:file->GetFileSize()];
}

/// Opens the source, runs `convert`, and removes the destination unless it succeeded.
+ (BOOL)runConversionFrom:(NSString*)sourcePath
                       to:(NSString*)destinationPath
                    token:(DOLDiscConversionToken*)token
                 progress:(DOLDiscConversionProgress)progress
                    error:(NSError* _Nullable*)error
                  convert:(bool (^)(DiscIO::BlobReader*, const std::string&, const std::string&,
                                    const DiscIO::CompressCB&))convert {
  const std::string source(sourcePath.UTF8String);
  const std::string destination(destinationPath.UTF8String);
  std::unique_ptr<DiscIO::BlobReader> reader = DiscIO::CreateBlobReader(source);
  if (!reader) {
    if (error)
      *error = [NSError errorWithDomain:DOLDiscImageErrorDomain
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey : @"The disc image could not be opened."}];
    return NO;
  }

  const DiscIO::CompressCB callback = [token, progress](const std::string&, float percent) {
    progress(percent);
    return !token.isCancelled;
  };
  const bool ok = convert(reader.get(), source, destination, callback);
  if (!ok) {
    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];
    if (error) {
      NSString* reason = token.isCancelled ? @"The conversion was cancelled."
                                           : @"The disc image could not be converted. Check that the device has enough free space.";
      *error = [NSError errorWithDomain:DOLDiscImageErrorDomain
                                   code:token.isCancelled ? 2 : 3
                               userInfo:@{NSLocalizedDescriptionKey : reason}];
    }
  }
  return ok;
}

+ (BOOL)convertToPlainFrom:(NSString*)sourcePath
                        to:(NSString*)destinationPath
                     token:(DOLDiscConversionToken*)token
                  progress:(DOLDiscConversionProgress)progress
                     error:(NSError* _Nullable*)error {
  return [self runConversionFrom:sourcePath
                              to:destinationPath
                           token:token
                        progress:progress
                           error:error
                         convert:^bool(DiscIO::BlobReader* reader, const std::string& source,
                                       const std::string& destination, const DiscIO::CompressCB& callback) {
                           return DiscIO::ConvertToPlain(reader, source, destination, callback);
                         }];
}

+ (BOOL)convertToRVZFrom:(NSString*)sourcePath
                      to:(NSString*)destinationPath
                   token:(DOLDiscConversionToken*)token
                progress:(DOLDiscConversionProgress)progress
                   error:(NSError* _Nullable*)error {
  return [self runConversionFrom:sourcePath
                              to:destinationPath
                           token:token
                        progress:progress
                           error:error
                         convert:^bool(DiscIO::BlobReader* reader, const std::string& source,
                                       const std::string& destination, const DiscIO::CompressCB& callback) {
                           return DiscIO::ConvertToWIAOrRVZ(
                               reader, source, destination, true,
                               static_cast<DiscIO::WIARVZCompressionType>(kWIARVZZstd), kRVZCompressionLevel,
                               DiscIO::GCZ_RVZ_PREFERRED_BLOCK_SIZE, callback);
                         }];
}

+ (nullable TVGameItem*)gameItemForPath:(NSString*)path {
  auto file = std::make_shared<const UICommon::GameFile>(std::string(path.UTF8String));
  if (!file->IsValid())
    return nil;
  GameFilePtrWrapper* wrapper = [[GameFilePtrWrapper alloc] init];
  wrapper.gameFile = file;
  return [[TVGameItem alloc] initWithWrapper:wrapper];
}

@end
