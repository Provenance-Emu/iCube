# Emulation Server: companion apps (installed-app detection and store links)

Date: 2026-11-15. Status: draft for the Emulation Server (`emulator-content-server`) repo. Written
from the iCube side; the facts about that repo below were read from its `codex/home-pairing-qr`
checkout at `78c1932` and should be rechecked there before work starts.

## Goal

A person who runs Emulation Server on a Mac should see which of our apps (iCube, Provenance, iFly,
Virtual Jaguar) are on that Mac, open them from the server's menu, and get an install link for the
ones that are missing. Store links change as apps are approved, so they come from one file in a
GitHub repo instead of a desktop release.

## What exists today (read, not assumed)

- The desktop app is `apps/tray`: Tauri 2, Rust in `src-tauri/src`, Svelte in `src`. Bundle id
  `org.provenance.contentserver.tray`. It ships for macOS, Windows and Linux.
- The native menu is built in `main.rs` (`install_startup_menu`): Open library, status, CLI tools,
  Quit. The status window is `Panel.svelte` (sections: Servers, Local service, Command-line tools).
- The library window (`LibraryWindow.svelte`) hosts the web UI from `apps/web`; its side menu is the
  `<aside class="library-sidebar">` in `LibraryShell.svelte`.
- `desktop_update.rs` already shells out with timeouts and reads bundle plists (`plist`, `run`).
- Nothing in the repo detects installed apps or links to an app by URL scheme today (grep for
  `NSWorkspace`, `urlForApplication`, `MenuBarExtra`, `icube://` and friends: no hits).

## Design

### 1. App catalog file

One JSON file, fetched from GitHub and also bundled as the fallback.

```json
{
  "schema": 1,
  "updated": "2026-11-15",
  "apps": [
    {
      "id": "icube",
      "name": "iCube",
      "summary": "GameCube and Wii",
      "systems": ["gamecube", "wii"],
      "bundleIds": ["com.joemattiello.iCube"],
      "urlSchemes": ["dolphinios"],
      "links": {
        "macAppStore": null,
        "iosAppStore": null,
        "tvosAppStore": null,
        "testFlight": null,
        "website": "https://icube-emu.com"
      }
    }
  ]
}
```

- `bundleIds` is a list because one app can appear under several: the iPad app running on Apple
  silicon keeps its iOS id, a Catalyst build may use the same id or `maccatalyst.<id>`, and a
  TestFlight or debug build can differ. The first match wins.
- A `null` link means "not available yet"; the UI shows no install action for it.
- Where the file lives: proposed `catalog/apps.json` on the default branch of the server repo,
  read from `raw.githubusercontent.com`. **Owner decision:** this repo, or a small dedicated one.
- Identifiers to confirm in each app's repo before the first publish: iCube
  `com.joemattiello.iCube`, scheme `dolphinios` (read from iCube's Info.plist); Provenance
  `org.provenance-emu.provenance`, scheme `provenance`; iFly and Virtual Jaguar are not known to
  me. Leave an app out of the file until its ids are confirmed.

Fetch rules (tray, Rust): HTTPS GET with an `If-None-Match` ETag, at launch and at most once a day;
5 s timeout; body capped at 64 KB; cached copy kept in the app's data directory; on any failure use
the cache, then the bundled copy. The request carries no identifier beyond a generic user agent.

The file is untrusted input. Validate before use: `schema == 1`; at most 16 apps; `id` matches
`[a-z0-9-]{1,32}`; names and summaries are plain text with a length cap and are rendered as text,
never as HTML; bundle ids match `[A-Za-z0-9.-]{1,128}`; every link is `https` and its host is on a
fixed allow-list (`apps.apple.com`, `testflight.apple.com`, plus the apps' own sites listed in
code). An entry that fails validation is dropped; a file that fails as a whole is ignored.

### 2. Detection (macOS only)

New Rust module `companion_apps.rs` with one Tauri command, `companion_apps()`, that returns, for
each catalog entry, `{ id, installed, kind, path }`.

- Lookup is by bundle id through Launch Services (`NSWorkspace
  urlForApplicationWithBundleIdentifier:` via the `objc2` crates, or
  `mdfind "kMDItemCFBundleIdentifier == '<id>'"` with the existing `run` helper and a timeout if a
  new dependency is unwanted). The bundle id comes from the validated catalog and is passed as one
  argument, never interpolated into a shell string.
- `kind` is read from the bundle that was found:
  - `ipad`: the bundle has a `Wrapper/` directory (how macOS installs an iPhone/iPad app).
  - `catalyst`: no wrapper, and `Contents/Info.plist` has `UIDeviceFamily`.
  - `mac`: neither.
- **To verify on a real Mac before building on it:** that Launch Services resolves an installed
  iPad app by its iOS bundle id, and that the `Wrapper/` test holds on the current macOS. If the
  lookup fails for iPad apps, fall back to scanning `/Applications/*.app/Wrapper/*.app/Info.plist`.
- The command takes no arguments from the webview. It returns paths only for display; opening an
  app goes through a second command, `open_companion_app(id)`, which looks the id up again and
  runs `open -b <bundle id>`. The webview can never ask to open an arbitrary path or bundle.
- Windows and Linux: the command returns every entry as `installed: false, kind: null`. The UI
  then shows store links only.
- Detection results stay on the Mac. They are not sent to the server, logged to a remote service,
  or included in any API response.

Re-run detection when the menu is about to open and when the library window gains focus; it is a
handful of Launch Services lookups.

### 3. Menu bar menu

A group between the status item and Quit:

```
Apps
  Open iCube                      (installed)
  Open Provenance                 (installed, iPad app)
  Get iFly on the App Store       (not installed, link known)
```

- Installed: "Open <name>", with "(iPad app)" appended for `kind == ipad`.
- Not installed with a link: "Get <name> on the App Store" (or "Join the <name> beta" for a
  TestFlight link); opens the link in the default browser through the opener plugin.
- Not installed with no link: the item is left out. If nothing is left, the group is left out.
- Link choice on macOS: `macAppStore`, else `iosAppStore` (an iPad app that allows Mac installs
  resolves there on Apple silicon), else `testFlight`, else `website`.

The native menu is rebuilt from Rust, so the items work even when the hidden webview fails to
load (the reason `install_startup_menu` exists).

### 4. Library side menu

A short "Apps" block at the bottom of the library sidebar, shown only inside the desktop app's
library window, where detection is available. Same three states as the menu. In a plain browser
the web UI cannot detect anything, so the block is not shown there in this version (see open
questions).

`apps/web` stays free of Tauri imports: the tray passes the list in through the same bridge it
uses for other desktop-only capabilities, and the web component renders nothing when no list is
provided.

## Not in this version

- Deep links that hand a server or a game to an app ("Open this game in iCube", "Add this server
  to iCube"). The pairing flow already exists; wiring a scheme into it is its own piece of work and
  needs each app to define the URL.
- Detection from a phone or tablet browser.
- Windows or Linux detection.
- Showing app versions or update prompts.

## Tests

- Catalog validation (TypeScript or Rust, wherever parsing lives): valid file; wrong schema; too
  many apps; bad id; non-https link; link host off the allow-list; HTML in a name; oversize body.
- Fetch fallback order: fresh, 304 with cache, network failure with cache, network failure without
  cache (bundled copy).
- `kind` classification from fixture bundle directories (wrapper present, Catalyst plist, plain
  Mac plist).
- Menu model: the pure function from (catalog, detection) to menu items, for each of the three
  states and the empty group.
- `open_companion_app` refuses an id that is not in the catalog.

## Open questions for the owner

1. Which repo holds `apps.json`?
2. In a plain browser on the same Mac, should the side menu list the apps with install links only
   (no "Open"), or stay hidden as proposed?
3. Should a TestFlight link be shown publicly, or only the App Store link once it exists?
4. Confirm the bundle ids and URL schemes for iFly and Virtual Jaguar, and whether any app ships a
   Catalyst build under a `maccatalyst.` id.
