// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// A slice of the live skin catalog (https://provenance-emu.com/skins/catalog.json, fetched
/// 2026-10-11): the one `gamecube` entry, four `n64` (one `.zip`, one with a raw space in its URL,
/// one in a pack with `groupId`, one with a Delta `gameTypeIdentifier`), a `gba` `.zip`, a Google
/// Drive link, an `unofficial`, a `threeDS`, a `gba` with a raw space. The two `test-` entries are
/// hand-written: a `wii` skin and a mixed-case `GameCube` with a date-only `lastUpdated`, which the
/// feed has for other systems but not for these.
///
/// A raw string so the feed's JSON escapes reach the decoder untouched.
enum SkinCatalogFixture {
  static let entryCount = 12
  static let gameCubePocketID = "ea60f2003d82ac9e"
  static let n64ZipID = "91f17a221e5c6a87"
  static let n64PackID = "15dd242edd355b11"
  static let n64SpaceURLID = "598c913900e17758"
  static let n64DeltaTypeID = "abe5e9e4ee7b0195"
  static let gbaZipID = "f3c67e2b3c9c1bc2"
  static let googleDriveID = "2a71bf5fa167d694"
  static let unofficialID = "e62e868cf559da9f"
  static let threeDSID = "f68e4aabb347bd7c"
  static let gbaSpaceURLID = "8e3871abb5910097"
  static let wiiID = "test-wii-remote"
  static let mixedCaseGameCubeID = "test-gamecube-dated"

  static var data: Data { Data(json.utf8) }

  static let json = #"""
  {
    "version": 2,
    "lastUpdated": "2026-10-04T05:11:24Z",
    "totalSkins": 1358,
    "skins": [
      {
        "author": "starvingartist",
        "gameTypeIdentifier": "public.aoshuang.game.ngc",
        "version": null,
        "thumbnailURL": null,
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": null,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": null,
        "groupOrder": null,
        "name": "GameCube Pocket",
        "downloadURL": "https://deltastyles.com/files/skins/760/gamecubepocket.manicskin",
        "systems": ["gamecube"],
        "source": "deltastyles.com",
        "id": "ea60f2003d82ac9e"
      },
      {
        "author": "bossmiller",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": null,
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": null,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": null,
        "groupOrder": null,
        "name": "Dpad with Joystick controls",
        "downloadURL": "https://deltastyles.com/files/skins/758/Dpad_Sub_for_Joystick_DPAD_ANALOG_MAPPING_FIXED_v2%202.zip",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "91f17a221e5c6a87"
      },
      {
        "author": "R3BEL",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/15dd242edd355b11.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2443,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": "deltastyles:551",
        "groupOrder": 1,
        "name": "[CRT GAMEPAD] [N64] [NO OVERSCAN]",
        "downloadURL": "https://deltastyles.com/files/skins/551/%5BCRT%20GAMEPAD%5D%20%5BN64%5D%20%5BNO%20OVERSCAN%5D.deltaskin",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "15dd242edd355b11"
      },
      {
        "author": "allgoodnobad",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/598c913900e17758.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 1652,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "8BitDo Micro Compatible N64 Skin",
        "downloadURL": "https://deltastyles.com/files/skins/459/8BitDo Micro SNES & N64 Skin.deltaskin",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "598c913900e17758"
      },
      {
        "author": "Classicallybrok3n",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/f3c67e2b3c9c1bc2.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 406,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "GAMEBOY ADVANCE MICRO",
        "downloadURL": "https://deltastyles.com/files/skins/490/gba_micro_working.zip",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "f3c67e2b3c9c1bc2"
      },
      {
        "author": "rythmic",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/2a71bf5fa167d694.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 683,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "Anime Icons: Luffy (One Piece)",
        "downloadURL": "https://drive.google.com/uc?export=download&id=1aiL5IBu_QHunenBsIC4-v3oorH1zb72l",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "2a71bf5fa167d694"
      },
      {
        "author": "masonkoleh",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/e62e868cf559da9f.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 736,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": "2026-03-15T00:05:34Z",
        "id": "e62e868cf559da9f",
        "downloadURL": "https://raw.githubusercontent.com/masonkoleh/deltaskins/HEAD/gba/skins/ahegaoGBA.deltaskin",
        "source": "masonkoleh/deltaskins",
        "name": "ahegaoGBA",
        "systems": ["unofficial"]
      },
      {
        "author": "JanZa",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/f68e4aabb347bd7c.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2518,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "3DS Controller",
        "downloadURL": "https://deltastyles.com/files/skins/538/3dscontroller.manicskin",
        "systems": ["threeDS"],
        "source": "deltastyles.com",
        "id": "f68e4aabb347bd7c"
      },
      {
        "author": "328yt",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/8e3871abb5910097.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2774,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "328 Black GBA for iPad",
        "downloadURL": "https://deltastyles.com/files/skins/328 Black GBA.deltaskin",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "8e3871abb5910097"
      },
      {
        "author": "masonkoleh",
        "gameTypeIdentifier": "com.rileytestut.delta.game.n64",
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/abe5e9e4ee7b0195.png",
        "screenshotURLs": [
          "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/abe5e9e4ee7b0195-landscape.png"
        ],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 3922,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": "2026-03-15T00:05:35Z",
        "id": "abe5e9e4ee7b0195",
        "downloadURL": "https://raw.githubusercontent.com/masonkoleh/deltaskins/HEAD/gba/skins/bleu.deltaskin",
        "source": "masonkoleh/deltaskins",
        "name": "Bleu N64",
        "systems": ["n64"]
      },
      {
        "id": "test-wii-remote",
        "name": "Test Wii Remote",
        "author": "iCube tests",
        "systems": ["wii"],
        "downloadURL": "https://example.com/skins/test-wii-remote.manicskin",
        "thumbnailURL": null,
        "source": "example.com",
        "tags": ["portrait"]
      },
      {
        "id": "test-gamecube-dated",
        "name": "Test GameCube Dated",
        "author": "iCube tests",
        "systems": ["GameCube"],
        "downloadURL": "https://example.com/skins/test-gamecube-dated.deltaskin",
        "thumbnailURL": null,
        "source": "owner/repo",
        "lastUpdated": "2025-09-23"
      }
    ]
  }
  """#
}
#endif
