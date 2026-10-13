# App Store Connect: App Review Information notes (iCube 1.0)

Paste the text between the rules into App Review Information > Notes. The field limit is 4000 characters; the text is 3658.

OWNER items before pasting:
- Fill the test title line (name, licence, public download URL). Check on a real device that it boots from a clean install and needs no Wii system files.
- Deploy the website branches first: `docs/privacy-crash-reports` (privacy page) and `docs/wii-system-files` (guide). Until then the two URLs show the old policy or a 404.
- Re-read the menu names in "How to test" against the final UI. They come from the current build and have not been screenshot-checked.
- The re-signed-install sentence is candid on purpose, because the source is public. You may shorten it. Do not replace it with "the app contains no JIT code": that is not true.
- The Web UI and WebDAV server starts on its own while the app is in the foreground (there is no on/off switch), which is why the notes describe it that way. See the task report.

---

Thank you for reviewing iCube.

WHAT IT IS
iCube is an emulator for GameCube and Wii games on iPhone, iPad and Apple TV (guideline 4.7), built on the open source Dolphin emulator. The app contains no games, no BIOS and no console firmware or system software. Users add games from their own discs, by importing files through the Files app (iPhone, iPad) or over their local Wi-Fi (iPhone, iPad, Apple TV). iCube does not offer to download games or console system software, and 1.0 has no online system update. Wii system files are supplied by the user from their own console (guide: https://icube-emu.com/guide/wii-system-files/). GameCube games and homebrew do not need them.
No account, sign-in, in-app purchase or subscription is needed, so there is no demo account.

HOW TO TEST WITH A FREELY DISTRIBUTABLE TITLE
Test title: [OWNER: pick a freely distributable homebrew title + public URL. Name, licence and download URL go here.]
iPhone or iPad:
1. Download the file in Safari to the Files app (unzip it first if it is a .zip).
2. In iCube choose Import Game and pick the file in Files. The title appears in the library; tap it to play.
Apple TV:
1. Open Settings > Sync & Network > Web UI & WebDAV, which shows a web address on the local network. Allow the local network permission on first use.
2. On a computer on the same Wi-Fi, open that address in a browser and drop the file onto the page. The title appears in the Apple TV library.
Pausing a game opens the pause menu with save states, fast-forward and settings.

NO JIT, NO DOWNLOADED CODE
- An App Store install runs Dolphin's interpreter CPU core only, with a software vertex loader. The app requests no JIT or dynamic-code-signing entitlement and generates no executable code at runtime.
- The open source Dolphin code includes a JIT recompiler. In this build it is inactive and its settings are hidden, unless the process is re-signed with debugging entitlements by the device's owner. That is not possible for an App Store install.
- The app downloads no executable code and no game software. All code is in the signed binary.
- There is no debug or developer server in this build.

NETWORK USE
- Web UI and WebDAV server: imports files from a computer on the same local network. It runs while the app is in the foreground and stops while a game is running. It is not reachable from the internet.
- Nearby Devices: Bonjour discovery for handing a game off to another device running iCube on the same network.
- Cheats: user-applied memory patches (text lists of addresses and values), fetched for the game's ID from a public code database (codes.rc24.xyz) or typed in by the user. They are data and are not run as app code.
- Skins (iPhone and iPad): optional touch-control skins from a public catalog. A skin is an archive of images (PDF or PNG) and a JSON layout file. It contains no code.
- Game covers: box art from GameTDB. Off by default.
- Crash reports: anonymous crash and performance reports go to Sentry. They are on by default and can be turned off in Settings > Privacy > Share Crash Reports. They contain no game names or file names. Policy: https://icube-emu.com/privacy/

LICENCE AND SOURCE
iCube is free software under the GNU General Public License (version 2 or later, like the Dolphin project). Complete source: https://github.com/Provenance-Emu/iCube

TRADEMARKS
"GameCube" and "Wii" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own. The app and its listing use no Nintendo logos or artwork; platform names only describe what is emulated.

Contact: git@joemattiello.com

---
