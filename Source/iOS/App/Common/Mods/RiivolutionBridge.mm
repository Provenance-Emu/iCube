// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "RiivolutionBridge.h"

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "Common/CommonTypes.h"
#include "Common/FileSearch.h"
#include "DiscIO/GameModDescriptor.h"
#include "DiscIO/RiivolutionParser.h"
#import "FoundationStringUtil.h"
#import "GameFilePtrWrapper.h"
#import "TVGameItem.h"
#include "UICommon/GameFile.h"

namespace {

// Riivolution keeps its settings per four-character game id, and only for standard ids.
constexpr size_t kShortGameIDLength = 4;
constexpr size_t kFullGameIDLength = 6;

std::string WithTrailingSlash(std::string path) {
  if (!path.empty() && path.back() != '/')
    path.push_back('/');
  return path;
}

bool HasStandardGameID(const std::string& game_id) {
  return game_id.size() == kShortGameIDLength || game_id.size() == kFullGameIDLength;
}

std::string ConfigPath(const std::string& sd_root, const std::string& game_id) {
  return WithTrailingSlash(sd_root) + "riivolution/config/" + game_id.substr(0, kShortGameIDLength) + ".xml";
}

// The id Riivolution's config file stores an option under.
std::string ConfigID(NSString* section, NSString* option_id, NSString* name) {
  if (option_id.length > 0)
    return FoundationToCppString(option_id);
  return FoundationToCppString(section) + FoundationToCppString(name);
}

NSString* ToNSString(const std::string& s) {
  return CppToFoundationString(s);
}

}  // namespace

@implementation RiivolutionOptionInfo
@end

@implementation RiivolutionPackInfo
@end

@implementation RiivolutionBridge

+ (NSArray<RiivolutionPackInfo*>*)packsForGameID:(NSString*)gameID
                                        revision:(NSInteger)revision
                                      discNumber:(NSInteger)discNumber
                                          sdRoot:(NSString*)sdRoot {
  const std::string game_id = FoundationToCppString(gameID);
  const std::string root = WithTrailingSlash(FoundationToCppString(sdRoot));

  std::optional<DiscIO::Riivolution::Config> config;
  if (HasStandardGameID(game_id))
    config = DiscIO::Riivolution::ParseConfigFile(ConfigPath(root, game_id));

  NSMutableArray<RiivolutionPackInfo*>* packs = [NSMutableArray array];
  for (const std::string& path : Common::DoFileSearch(root + "riivolution", ".xml")) {
    auto parsed = DiscIO::Riivolution::ParseFile(path);
    if (!parsed || !parsed->IsValidForGame(game_id, static_cast<u16>(revision), static_cast<u8>(discNumber)))
      continue;
    if (config)
      DiscIO::Riivolution::ApplyConfigDefaults(&*parsed, *config);

    NSMutableArray<RiivolutionOptionInfo*>* options = [NSMutableArray array];
    for (const auto& section : parsed->m_sections) {
      for (const auto& option : section.m_options) {
        RiivolutionOptionInfo* info = [RiivolutionOptionInfo new];
        info.sectionName = ToNSString(section.m_name);
        info.optionID = ToNSString(option.m_id);
        info.name = ToNSString(option.m_name);
        NSMutableArray<NSString*>* choices = [NSMutableArray array];
        for (const auto& choice : option.m_choices)
          [choices addObject:ToNSString(choice.m_name)];
        info.choices = choices;
        info.selectedChoice = option.m_selected_choice <= option.m_choices.size() ? option.m_selected_choice : 0;
        [options addObject:info];
      }
    }

    RiivolutionPackInfo* pack = [RiivolutionPackInfo new];
    pack.xmlPath = ToNSString(path);
    pack.rootPath = ToNSString(root);
    pack.options = options;
    [packs addObject:pack];
  }
  return packs;
}

+ (BOOL)saveSelectionsOfPacks:(NSArray<RiivolutionPackInfo*>*)packs gameID:(NSString*)gameID {
  const std::string game_id = FoundationToCppString(gameID);
  if (!HasStandardGameID(game_id))
    return NO;

  std::map<std::string, DiscIO::Riivolution::Config> configs;
  for (RiivolutionPackInfo* pack in packs) {
    auto& options = configs[FoundationToCppString(pack.rootPath)].m_options;
    for (RiivolutionOptionInfo* option in pack.options) {
      options.push_back(DiscIO::Riivolution::ConfigOption{
          ConfigID(option.sectionName, option.optionID, option.name), static_cast<u32>(option.selectedChoice)});
    }
  }

  BOOL ok = YES;
  for (const auto& [root, config] : configs)
    ok &= DiscIO::Riivolution::WriteConfigFile(ConfigPath(root, game_id), config);
  return ok;
}

+ (BOOL)writeDescriptorToPath:(NSString*)path
                     baseFile:(NSString*)baseFile
                  displayName:(NSString*)displayName
                        packs:(NSArray<RiivolutionPackInfo*>*)packs
                   pathMapper:(NSString* (^)(NSString* absolutePath))pathMapper {
  DiscIO::GameModDescriptor descriptor;
  descriptor.base_file = FoundationToCppString(pathMapper(baseFile));
  descriptor.display_name = FoundationToCppString(displayName);

  DiscIO::GameModDescriptorRiivolution riivolution;
  for (RiivolutionPackInfo* pack in packs) {
    BOOL anySelected = NO;
    for (RiivolutionOptionInfo* option in pack.options)
      anySelected |= option.selectedChoice > 0;
    if (!anySelected)
      continue;

    auto& patch = riivolution.patches.emplace_back();
    patch.xml = FoundationToCppString(pathMapper(pack.xmlPath));
    patch.root = FoundationToCppString(pathMapper(pack.rootPath));
    for (RiivolutionOptionInfo* option in pack.options) {
      auto& entry = patch.options.emplace_back();
      entry.section_name = FoundationToCppString(option.sectionName);
      if (option.optionID.length > 0)
        entry.option_id = FoundationToCppString(option.optionID);
      else
        entry.option_name = FoundationToCppString(option.name);
      entry.choice = static_cast<u32>(option.selectedChoice);
    }
  }
  if (!riivolution.patches.empty())
    descriptor.riivolution = std::move(riivolution);

  return DiscIO::WriteGameModDescriptorFile(FoundationToCppString(path), descriptor, true);
}

+ (nullable TVGameItem*)gameItemForDescriptorAtPath:(NSString*)path {
  auto game_file = std::make_shared<const UICommon::GameFile>(FoundationToCppString(path));
  if (!game_file->IsValid())
    return nil;
  GameFilePtrWrapper* wrapper = [GameFilePtrWrapper new];
  wrapper.gameFile = game_file;
  return [[TVGameItem alloc] initWithWrapper:wrapper];
}

@end
