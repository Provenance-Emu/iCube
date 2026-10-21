#!/usr/bin/env python3
# Copyright 2026 iCube Project
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run real core locale defaults on macOS, without rebuilding an xcframework.

Each case runs in a fresh process because Dolphin caches locale defaults.
Only Host input and the unused UI alert/translation hooks are supplied by the
probe; locale parsing, language support and country/region mapping are production.
"""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROBE = r'''
#include "Common/MsgHandler.h"
#include "Core/Config/DefaultLocale.h"
#include "DiscIO/Enums.h"
#include "PreferredLocales.h"
#include <cstdio>
#include <cstdlib>
static std::vector<std::string> test_locales;
std::vector<std::string> Host_GetPreferredLocales() { return test_locales; }
namespace Common {
bool MsgAlertFmtImpl(bool, MsgType, Log::LogType, const char *, int,
                     fmt::string_view, const fmt::format_args &) {
  std::abort();
}
std::string GetStringT(const char *text) { return text; }
} // namespace Common
int main(int argc, char **argv) {
  @autoreleasepool {
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (int i = 5; i < argc; ++i)
      [languages addObject:[NSString stringWithUTF8String:argv[i]]];
    test_locales = DOLPreferredLocales(
        languages,
        [[NSLocale alloc]
            initWithLocaleIdentifier:[NSString stringWithUTF8String:argv[1]]]);
    const int region = static_cast<int>(Config::GetDefaultRegion());
    const int wii = static_cast<int>(Config::GetDefaultLanguage());
    const int gc = Config::GetDefaultGameCubeLanguage();
    if (region != atoi(argv[2]) || wii != atoi(argv[3]) ||
        gc != atoi(argv[4])) {
      printf("FAIL: region=%d wii=%d gc=%d\n", region, wii, gc);
      return 1;
    }
    printf("PASS: %s region=%d wii=%d gc=%d country=%u\n", argv[1], region, wii,
           gc, Config::GetDefaultCountry());
  }
}
'''
CASES = [
    ("en_US", 1, 1, 0, ["en-US"]),
    ("en_GB", 2, 1, 0, ["en-US"]),
    ("ja_JP", 0, 0, 0, ["ja-JP"]),
    ("ko_KR", 4, 9, 0, ["ko-KR"]),
    ("de_DE", 2, 2, 1, ["de-DE"]),
    ("en_AU", 2, 1, 0, ["en-US"]),
    ("fr_US", 1, 3, 2, ["fr-FR"]),
    ("en_US", 1, 2, 1, ["sv-SE", "de-DE"]),
    ("en_US", 1, 8, 0, ["zh-TW"]),
    ("en_US", 1, 7, 0, ["zh-CN"]),
    ("en_US", 1, 7, 0, ["zh-SG"]),
    ("en_US", 1, 8, 2, ["zh-Hant-TW", "fr-FR"]),
    ("ja_JP", 0, 0, 0, []),
    ("en_CN", 0, 7, 0, ["zh"]),
    ("en_TW", 0, 8, 0, ["zh"]),
]


def main():
    with tempfile.TemporaryDirectory(prefix="icube-locale-") as temporary:
        folder = Path(temporary)
        source, binary = folder / "probe.mm", folder / "probe"
        source.write_text(PROBE)
        subprocess.run([
            "xcrun", "clang++", "-std=c++23", "-O1", "-DFMT_HEADER_ONLY",
            "-fobjc-arc", "-framework", "Foundation", "-liconv", "-Wl,-dead_strip",
            "-I", str(ROOT / "Source/iOS/Library"),
            "-I", str(ROOT / "Source/Core"),
            "-I", str(ROOT / "Externals/fmt/fmt/include"), str(source),
            str(ROOT / "Source/Core/Core/Config/DefaultLocale.cpp"),
            str(ROOT / "Source/Core/Common/StringUtil.cpp"),
            str(ROOT / "Source/Core/DiscIO/Enums.cpp"), "-o", str(binary),
        ], check=True)
        for locale, region, wii, gc, languages in CASES:
            subprocess.run([
                str(binary), locale, str(region), str(wii), str(gc), *languages,
            ], check=True)
    print(f"{len(CASES)} core locale scenarios passed")


if __name__ == "__main__":
    main()
