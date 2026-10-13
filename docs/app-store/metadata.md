# App Store Connect metadata: iCube 1.0 (iOS and tvOS)

Paste-ready text. One app record covers iPhone, iPad and Apple TV, so the same text is used for both platforms.
Counts are characters, measured with `printf '%s' "$field" | LC_ALL=en_US.UTF-8 wc -m` (no trailing newline).

Status legend: **OWNER** lines need a decision or a check before submission.

## App information

| Field | Limit | Count | Value |
|---|---|---|---|
| Name | 30 | 5 | `iCube` |
| Subtitle | 30 | 22 | `Play the games you own` |
| Bundle ID | | | `com.joemattiello.iCube` |
| Primary category | | | Entertainment (matches `LSApplicationCategoryType` = `public.app-category.entertainment` in `Source/iOS/App/Project.swift`). **OWNER:** Games is the other plausible choice. |
| Copyright | | | `2026 Joseph Mattiello` **OWNER:** confirm the legal name or entity |

Name and subtitle contain no third-party marks. "iCube" is the app's own name.

## Promotional text (155 of 170)

```
Touch controls, game controller support, save states and screen filters for the game discs you already own. iCube includes no games and no system software.
```

## Keywords (95 of 100)

```
emulator,retro,classic,controller,gamepad,touch,save state,shader,filter,homebrew,cheats,webdav
```

- Comma-separated with no spaces after commas; the one internal space is inside the phrase `save state`.
- No trademarks of others (no GameCube, Wii, Nintendo, Dolphin, or any other console or emulator name). Apple indexes the name and subtitle too, so those words are not repeated here.

## Description (1777 of 4000)

Use this text when iCloud Sync does **not** ship in 1.0. If Task 14 ships iCloud Sync, use the variant in the next section.

```
iCube plays GameCube and Wii games that you own on iPhone, iPad and Apple TV. It is built on the open source Dolphin emulator and made for touch screens, game controllers and the big screen.

BRING YOUR OWN GAMES
iCube does not include any games or system software. You add games from your own discs, and a Wii needs system files from your own console. iCube never downloads games, and it does not download Nintendo system software. Step-by-step guides are in the Help section of the app and on icube-emu.com.

PLAY YOUR WAY
• Touch controls designed for iPhone and iPad, plus skins you can install
• Works with popular Bluetooth and USB game controllers, with per-player mapping
• Point and aim in Wii games with touch or device motion
• Pause menu with save states, quick settings and fast-forward
• Cheat codes: apply codes from a public code database or add your own
• Screen filters with live previews

YOUR LIBRARY, YOUR WAY
• Import through the Files app on iPhone and iPad
• Import from a computer over Wi-Fi with the built-in web page or WebDAV, which is also the way to add games on Apple TV
• Browse games stored on a WebDAV server
• Game grid or list, with search
• Hand a game off to another nearby device running iCube
• Available in English and Japanese

PRIVACY
iCube has no accounts, no ads and no tracking. Anonymous crash and performance reports help us fix bugs and can be turned off in Settings > Privacy. Reports are designed to leave out your games and file names.

OPEN SOURCE
iCube is free software under the GNU General Public License. Source code: github.com/Provenance-Emu/iCube

"GameCube" and "Wii" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own.
```

Notes on the description:
- **OWNER: "Available in English and Japanese" is generous.** `ja.lproj/Core.strings` has 4,496 entries and about 2,350 of them (roughly half) are still the English text (key equals value), so Japanese users see a mix. Either drop the line from both descriptions, or have the Japanese strings translated first.
- GameCube and Wii appear only descriptively ("plays GameCube and Wii games that you own"), as the spec (WS3) allows. They never appear in the name, subtitle, keywords or promotional text.
- The trademark disclaimer is copied verbatim from the app: `Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings` line 5115 (the string shown in About, `AboutView.swift` lines 144-148, where it is split across two lines).
- It says "iCube does not include any games or system software" in the Bring Your Own Games section.
- It does not mention JIT, the Wii System Update, StikDebug or sideloading. It does not give shader counts.
- Every feature line was checked against code (see the task report). The Files-app import, Web UI / WebDAV import, Nearby Devices hand-off, cheats, skins (iOS only), screen filters and pause menu all ship in the App Store build.

### Variant with iCloud Sync (1868 of 4000)

Only if **OWNER** Task 14 ships iCloud Sync. It adds one line after the hand-off line; everything else is identical.

```
iCube plays GameCube and Wii games that you own on iPhone, iPad and Apple TV. It is built on the open source Dolphin emulator and made for touch screens, game controllers and the big screen.

BRING YOUR OWN GAMES
iCube does not include any games or system software. You add games from your own discs, and a Wii needs system files from your own console. iCube never downloads games, and it does not download Nintendo system software. Step-by-step guides are in the Help section of the app and on icube-emu.com.

PLAY YOUR WAY
• Touch controls designed for iPhone and iPad, plus skins you can install
• Works with popular Bluetooth and USB game controllers, with per-player mapping
• Point and aim in Wii games with touch or device motion
• Pause menu with save states, quick settings and fast-forward
• Cheat codes: apply codes from a public code database or add your own
• Screen filters with live previews

YOUR LIBRARY, YOUR WAY
• Import through the Files app on iPhone and iPad
• Import from a computer over Wi-Fi with the built-in web page or WebDAV, which is also the way to add games on Apple TV
• Browse games stored on a WebDAV server
• Game grid or list, with search
• Hand a game off to another nearby device running iCube
• Sync saves, save states and settings across your devices through your own iCloud account
• Available in English and Japanese

PRIVACY
iCube has no accounts, no ads and no tracking. Anonymous crash and performance reports help us fix bugs and can be turned off in Settings > Privacy. Reports are designed to leave out your games and file names.

OPEN SOURCE
iCube is free software under the GNU General Public License. Source code: github.com/Provenance-Emu/iCube

"GameCube" and "Wii" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own.
```

## What's New in this version

App Store Connect does not show a "What's New" field for the first version of an app, so nothing is pasted for 1.0 itself. This text is ready for TestFlight "What to Test" and for reuse as the 1.0.1 starting point (282 of 4000):

```
Welcome to iCube 1.0.

- Play GameCube and Wii games you own on iPhone, iPad and Apple TV
- Touch controls, game controller support, save states and screen filters
- Import games with the Files app or over Wi-Fi
- Optional anonymous crash reports, off any time in Settings > Privacy
```

## URLs

| Field | URL | Status checked 2026-10-13 |
|---|---|---|
| Support URL | `https://icube-emu.com/support/` | Page exists (`src/app/support/page.tsx`), HTTP 200 live |
| Marketing URL | `https://icube-emu.com/` | HTTP 200 live |
| Privacy Policy URL | `https://icube-emu.com/privacy/` | Page exists, HTTP 200 live, but the live copy is the OLD policy (mentions Bugsnag). **OWNER:** deploy the website branch `docs/privacy-crash-reports` before submitting. |
| Help guide cited in review notes | `https://icube-emu.com/guide/wii-system-files/` | Exists only on the unpushed website branch `docs/wii-system-files` (Task 9). **OWNER:** push and deploy before submitting. |

### OWNER: the marketing and support URLs land on sideload-oriented pages

Both URLs are live and would be opened by App Review. Today they show wording that does not fit an App Store listing, and could prompt questions about JIT and about how games are obtained. I did not edit these pages, because sideloading is your other distribution channel and the change is your call. Recommended before submission: an App Store-specific landing page for the Marketing URL (for example `/app-store/`), and a support page or section for the Support URL without JIT or ROM wording. The lines (website repo `~/Workspace/Provenance/iCube/icube-emu.github.io`, file:line):

| File:line | Text |
|---|---|
| `src/app/page.tsx:6` | meta description "Download iCube and play classic Nintendo GameCube and Wii games..." |
| `src/app/page.tsx:39-40` | "brings classic Nintendo GameCube and Wii games to your Apple devices... No JIT required." |
| `src/app/page.tsx:17-18, 43-55` | AltStore and SideStore badges ("Download from") |
| `src/app/page.tsx:85` | stat tile `['No JIT', 'Required']` |
| `src/app/page.tsx:99` and `src/components/DownloadSection.tsx:16-43` | "iCube isn't on the App Store. You can sideload it...", SideStore and Sideloadly links, "to enable JIT on iOS/iPadOS" (becomes false once listed) |
| `src/app/support/page.tsx:7` | meta description "...FAQs, JIT setup, ..." |
| `src/app/support/page.tsx:68` | "drag and drop ROM/ISO files" |
| `src/components/Footer.tsx:36` | "TestFlight Beta" link |
| `src/app/guide/importing/page.tsx:46-47` | "enable the web server" (fixed on the website branch; the server starts by itself) |

## Homebrew test title (for the review notes)

**OWNER: pick a freely distributable homebrew title + public URL.** Put it into `review-notes.md` where marked.

I could not confirm a prebuilt, freely licensed GameCube or Wii homebrew game that boots on its own, so I am not naming one. Requirements for the pick: a prebuilt `.dol`, `.elf` or disc image that boots without any other file, a licence that allows redistribution, a stable public download URL, and no emulator-within-an-emulator (a reviewer would ask about it under 4.7). Ways to get one:
- A small game from the Games list at wiibrew.org whose page states a free licence; check that the download is a prebuilt `.dol`.
- Build one of the example programs from `https://github.com/devkitPro/wii-examples` (source only, so it has to be built and hosted somewhere stable, for example on icube-emu.com). Confirm the licence of the example you pick first.

## Other App Store Connect fields

| Field | Suggested answer |
|---|---|
| Version | 1.0 (`MARKETING_VERSION` 1.0.0 in `Project.swift`) |
| Sign-in required for review | No (the app has no accounts) |
| Review contact | **OWNER** (name, phone, `git@joemattiello.com`) |
| Export compliance | `ITSAppUsesNonExemptEncryption` is set in `Info.plist` and `Info-TV.plist`; answer per the submission checklist (standard encryption only) |
| Age rating | **OWNER** answers the questionnaire. The app itself ships no games or media; the content depends on what the user imports. Answer for the app as delivered, and keep the answers consistent with the review notes. |
| Price | **OWNER** |
| Phased release | **OWNER** (spec WS8 suggests on) |
