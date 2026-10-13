# App Store Connect: App Review Information notes (iCube 1.0)

Paste the text between the rules into App Review Information > Notes. The field limit is 4000 characters; the text is 3935 including the placeholder (a real title line is about the same length; keep the total under 4000).

OWNER items before pasting:
- Fill the test title line (name, licence, public download URL). Check on a real device that it boots from a clean install and needs no Wii system files.
- Deploy the website branches first: `docs/privacy-crash-reports` (privacy page) and `docs/wii-system-files` (guide). Until then the two URLs show the old policy or a 404.
- Re-read the menu names in "How to test" against the final UI. They come from the current build and have not been screenshot-checked.
- The re-signed-install sentence is candid on purpose, because the source is public. You may shorten it. Do not replace it with "the app contains no JIT code": that is not true.
- The Web UI and WebDAV server starts on its own while the app is in the foreground and has no on/off switch or password (`ROMUploadServer.swift`: "Open LAN upload server: anonymous access"). The notes say so plainly; consider adding a toggle or a password before submission, since a reviewer may ask.
- Confirm there is no request logging or analytics on provenance-emu.com (GitHub Pages behind Cloudflare) before keeping the sentence about the skin catalog.

---

Thank you for reviewing iCube.

WHAT IT IS
iCube is an emulator for GameCube and Wii games on iPhone, iPad and Apple TV (guideline 4.7), built on the open source Dolphin emulator. The app contains no games, BIOS or console firmware. Users import their own game files through the Files app (iPhone, iPad) or over local Wi-Fi (all devices). iCube does not offer to download games or console system software. Wii system files come from the user's own console (guide: https://icube-emu.com/guide/wii-system-files/); GameCube games and homebrew do not need them.
iCube has no accounts of its own and no purchases, so no demo account is needed. The only sign-in is optional RetroAchievements (see Network use), off by default.

HOW TO TEST WITH A FREELY DISTRIBUTABLE TITLE
Test title: [OWNER: pick a freely distributable homebrew title + public URL. Name, licence and download URL go here.]
iPhone or iPad:
1. Save the file to the Files app (unzip it if it is a .zip).
2. In iCube choose Import Game and pick it, then tap it in the library to play.
Apple TV:
1. Open Settings > Sync & Network > Web UI & WebDAV, which shows a web address on the local network.
2. On a computer on the same Wi-Fi, open that address in a browser and drop the file onto the page.

NO JIT, NO DOWNLOADED CODE
- An App Store install runs Dolphin's interpreter CPU core only, with a software vertex loader. The app requests no JIT or dynamic-code-signing entitlement and generates no executable code at runtime.
- The open source Dolphin code includes a JIT recompiler. It is inactive and its settings are hidden unless the device's owner re-signs the app with debugging entitlements, which an App Store install cannot do.
- The app downloads no executable code or game software. There is no debug server in this build.

NETWORK USE
- Web UI and WebDAV server, for importing files from a computer on the same network. It starts when the app is in the foreground (the Local Network prompt appears at launch) and stops while a game runs, except during an upload. It has no password, so anyone on the same network can reach it while it runs. It is not reachable from the internet. Nearby Devices uses Bonjour on the same network to hand a game off to another iCube.
- Cheats: user-applied memory patches (text lists of addresses and values) fetched for the game's ID from a public code database (codes.rc24.xyz), or typed in. They are data, not app code.
- Skins (iPhone, iPad): optional touch-control skins from a catalog of static files on GitHub Pages (provenance-emu.com) and GitHub. A skin is images (PDF, PNG) plus a JSON layout file, with no code.
- Help pages: Markdown text from our public GitHub repository (raw.githubusercontent.com/Provenance-Emu/icube-wiki), with a bundled fallback. Documentation, not code.
- Covers: optional GameTDB box art, off by default.
- RetroAchievements (optional, off by default, Settings > Achievements): sign-in sends the username and password once to retroachievements.org, which returns a token. The password is not stored; the username and token stay in the app's settings file on the device (not the Keychain). With achievements on, the game's identifier and progress go to retroachievements.org.
- Crash reports: anonymous crash and performance reports go to Sentry, on by default, off in Settings > Privacy > Share Crash Reports. They are designed to exclude game names and file paths. Policy: https://icube-emu.com/privacy/

LICENCE AND SOURCE
Free software under the GNU General Public License (version 2 or later, like Dolphin). Source: https://github.com/Provenance-Emu/iCube

TRADEMARKS
"GameCube" and "Wii" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own. The app ships no Nintendo logos or artwork. Optional cover download shows box art only for games in the user's own library.

Contact: git@joemattiello.com

---
