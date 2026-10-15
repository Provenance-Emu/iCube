// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

@class TVGameItem;

NS_ASSUME_NONNULL_BEGIN

/// One Riivolution option as the XML declares it, plus the choice currently selected.
@interface RiivolutionOptionInfo : NSObject

@property (nonatomic, copy) NSString* sectionName;
/// The XML's option id; empty when the XML gives none, in which case section + option name identify it.
@property (nonatomic, copy) NSString* optionID;
@property (nonatomic, copy) NSString* name;
/// Choice names. A selection of 0 means the option is off; selection n picks `choices[n - 1]`.
@property (nonatomic, copy) NSArray<NSString*>* choices;
@property (nonatomic) NSUInteger selectedChoice;

@end

/// One parsed Riivolution XML: where it lives, its virtual SD root, and its options.
@interface RiivolutionPackInfo : NSObject

@property (nonatomic, copy) NSString* xmlPath;
/// The virtual SD root, with a trailing slash: the folder that holds `riivolution/`.
@property (nonatomic, copy) NSString* rootPath;
@property (nonatomic, copy) NSArray<RiivolutionOptionInfo*>* options;

@end

/// Thin bridge to DiscIO's Riivolution parser and the GameMod descriptor writer. Everything that can be
/// decided without the core (paths, naming, merging packs) lives in Swift.
@interface RiivolutionBridge : NSObject

/// Every XML under `<sdRoot>/riivolution/` that applies to the game, with the selections saved in
/// `riivolution/config/<ID4>.xml` already applied. Reads and parses files: call off the main thread.
+ (NSArray<RiivolutionPackInfo*>*)packsForGameID:(NSString*)gameID
                                        revision:(NSInteger)revision
                                      discNumber:(NSInteger)discNumber
                                          sdRoot:(NSString*)sdRoot;

/// Writes the packs' current selections to `<root>/riivolution/config/<ID4>.xml`, one file per SD root,
/// exactly as desktop Dolphin does. Returns NO if a file could not be written.
+ (BOOL)saveSelectionsOfPacks:(NSArray<RiivolutionPackInfo*>*)packs gameID:(NSString*)gameID;

/// Writes a GameMod descriptor (`.json`) booting `baseFile` with the packs' selections. `pathMapper` turns each
/// absolute path (base file, XML, SD root) into the string stored in the descriptor.
+ (BOOL)writeDescriptorToPath:(NSString*)path
                     baseFile:(NSString*)baseFile
                  displayName:(NSString*)displayName
                        packs:(NSArray<RiivolutionPackInfo*>*)packs
                   pathMapper:(NSString* (^)(NSString* absolutePath))pathMapper;

/// A library item for the mod descriptor at `path`, or nil if the core cannot read it or its base disc.
+ (nullable TVGameItem*)gameItemForDescriptorAtPath:(NSString*)path;

@end

NS_ASSUME_NONNULL_END
