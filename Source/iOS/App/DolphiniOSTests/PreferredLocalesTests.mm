// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#include "Core/Config/DefaultLocale.h"
#include "Core/IOS/FS/HostBackend/FS.h"
#include "Core/SysConf.h"
#include "DiscIO/Enums.h"
#include "PreferredLocales.h"

@interface PreferredLocalesTests : XCTestCase
@end

@implementation PreferredLocalesTests
- (void)testNewWiiConsoleUsesLocaleDefaultsAndPreservesStoredChoices
{
  NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSString* directory in @[ @"tmp", @"shared2/sys" ])
    [files createDirectoryAtPath:[root stringByAppendingPathComponent:directory]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  {
    auto fs = std::make_shared<IOS::HLE::FS::HostFileSystem>(root.UTF8String);
    const u8 chosenLanguage = Config::GetDefaultLanguage() == DiscIO::Language::English ? 2 : 1;
    const u8 chosenCountry = Config::GetDefaultCountry() == 49 ? 1 : 49;
    {
      SysConf console(fs);
      XCTAssertEqual(console.GetData<u8>("IPL.LNG", 255),
                     static_cast<u8>(Config::GetDefaultLanguage()));
      XCTAssertEqual(console.GetEntry("IPL.SADR")->bytes[0], Config::GetDefaultCountry());
      console.SetData<u8>("IPL.LNG", SysConf::Entry::Type::Byte, chosenLanguage);
      console.GetEntry("IPL.SADR")->bytes[0] = chosenCountry;
      XCTAssertTrue(console.Save());
    }
    {
      SysConf reopened(fs);
      XCTAssertEqual(reopened.GetData<u8>("IPL.LNG", 255), chosenLanguage);
      XCTAssertEqual(reopened.GetEntry("IPL.SADR")->bytes[0], chosenCountry);
    }
  }
  [files removeItemAtPath:root error:nil];
}

- (void)testRegionSettingWinsOverLanguageCountry
{
  for (NSString* country in @[ @"US", @"GB", @"JP", @"KR", @"AU" ])
  {
    const auto locales = DOLPreferredLocales(
        @[ @"en-US", @"fr-FR" ],
        [[NSLocale alloc] initWithLocaleIdentifier:[@"en_" stringByAppendingString:country]]);
    const std::vector<std::string> expected = {std::string("en-") + country.UTF8String,
                                               std::string("fr-") + country.UTF8String};
    XCTAssertTrue(locales == expected, @"%@", country);
  }
}

- (void)testChineseScriptAndPreferenceOrderArePreserved
{
  const auto locales = DOLPreferredLocales(@[ @"sv-SE", @"zh-Hant-TW", @"de-DE" ],
                                           [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]);
  const std::vector<std::string> expected = {"sv-US", "zh-Hant-US", "de-US"};
  XCTAssertTrue(locales == expected);
}

- (void)testChineseRegionImpliesScriptWhenUserRegionDiffers
{
  const auto locales = DOLPreferredLocales(@[ @"zh-TW", @"zh-CN", @"zh-SG" ],
                                           [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]);
  const std::vector<std::string> expected = {"zh-Hant-US", "zh-Hans-US", "zh-Hans-US"};
  XCTAssertTrue(locales == expected);
}

- (void)testChineseWithoutScriptUsesCurrentRegion
{
  const auto locales =
      DOLPreferredLocales(@[ @"zh" ], [[NSLocale alloc] initWithLocaleIdentifier:@"en_CN"]);
  XCTAssertTrue(locales == std::vector<std::string>{"zh-Hans-CN"});
}

- (void)testEmptyLanguageListUsesCurrentLocale
{
  const auto locales =
      DOLPreferredLocales(@[], [[NSLocale alloc] initWithLocaleIdentifier:@"ja_JP"]);
  XCTAssertTrue(locales == std::vector<std::string>{"ja-JP"});
}

- (void)testMissingRegionPreservesLanguageRegion
{
  const auto locales =
      DOLPreferredLocales(@[ @"pt-BR" ], [[NSLocale alloc] initWithLocaleIdentifier:@"en"]);
  XCTAssertTrue(locales == std::vector<std::string>{"pt-BR"});
}
@end
