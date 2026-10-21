// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>

// Keep language preference order, but use the user's Region setting for country/TV defaults.
// This is called during C++ static initialization, before the app has launched.
inline std::vector<std::string> DOLPreferredLocales(NSArray<NSString*>* languages, NSLocale* locale)
{
  @autoreleasepool
  {
    NSString* country = [locale objectForKey:NSLocaleCountryCode];
    NSArray<NSString*>* preferred = languages.count ? languages : @[ locale.localeIdentifier ];
    std::vector<std::string> result;
    for (NSString* identifier in preferred)
    {
      NSLocale* language = [[NSLocale alloc] initWithLocaleIdentifier:identifier];
      NSString* code = [language objectForKey:NSLocaleLanguageCode];
      if (!code.length)
        continue;
      NSMutableArray<NSString*>* parts = [NSMutableArray arrayWithObject:code];
      NSString* script = [language objectForKey:NSLocaleScriptCode];
      // Keep the Chinese writing system even when the Region setting replaces TW/CN/SG.
      if (!script.length && [code isEqualToString:@"zh"])
      {
        NSString* languageCountry = [language objectForKey:NSLocaleCountryCode];
        if (!languageCountry.length)
          languageCountry = country;
        script =
            ([languageCountry isEqualToString:@"CN"] || [languageCountry isEqualToString:@"SG"]) ?
                @"Hans" :
                @"Hant";
      }
      if (script.length)
        [parts addObject:script];
      NSString* region = country.length ? country : [language objectForKey:NSLocaleCountryCode];
      if (region.length)
        [parts addObject:region];
      result.emplace_back([parts componentsJoinedByString:@"-"].UTF8String);
    }
    return result;
  }
}
