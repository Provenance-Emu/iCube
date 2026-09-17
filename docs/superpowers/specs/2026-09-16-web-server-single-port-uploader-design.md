# Web server re-port: single port, data integrity, upload page

Date: 2026-09-16
Status: approved design, awaiting implementation plan
Scope: `Source/iOS/PVWebServer` (SPM package) and its consumers in `Source/iOS/App`

## 1. Context

iCube's upload server is a fork of iFly's `NativeWebServer`. The fork landed on
2026-06-02 (`9793cc4a12`, "replace GCDWebServer/PVWebServer with iFly's
NWListener upload server") as `ROMUploadServer.swift` (2,901 lines) behind the
`@objc(PVWebServer)` facade in `PVWebServer.swift` (230 lines). iFly kept
improving its server after the fork. The deltas that matter, in iFly commit
order:

| iFly commit | Date | What |
|---|---|---|
| `7a68d65c8` | 06-03 | WebDAV write access restored, web UI file management (`/move`, `/mkdir`), prevent sleep |
| `af713fc7d` | 06-08 | Folder-preserving drag and drop upload |
| `91dd7bb5f` | 06-11 | One listener, one port, sticky per-connection WebDAV vs browser detection |
| `cf81f14da` | 06-12 | Upload page extracted to `Resources/WebServer/*` templates, Steam-style transfer panel |
| `a302e97cb` | 06-13 | Page polls `/api/health` to show or hide the Live Stats link |
| `5f9fdc1b6` | 06-14 | Browser upload switched from multipart POST to raw `PUT /files/<path>` |
| `ac9670cc2` | 06-14 | Answer `Expect: 100-continue`, replace target before write, drop preallocate |
| `8839fca00` | 07-01 | Finder guest-mount hang: arm first read on `.ready`, establishment watchdog |
| `437c45160` | 07-01 | Keep-alive honoured on WebDAV file GET |
| `1e4a8bb85` | 07-01 | Audit: write failures surfaced, symlink-safe path guard, 22 unit tests |
| `7eb339c11` | 08-26 | Bonjour advertised through `NWListener.service` |

iCube today:

- Two `NWListener`s on two ports. HTTP on 80 (8080 on simulator), WebDAV on 81
  (8081). `isWebDAV` is fixed at accept time. No client detection.
- Upload page is inline Swift string interpolation at
  `ROMUploadServer.swift:2462` onward. Multipart `POST /upload`, three
  concurrent uploads, no folder drag and drop, no speed or ETA display.
- `SerialFileWriter.write` ignores write errors. A disk-full upload truncates
  the file and the client gets a success status.
- `resolvedPath(_:within:)` at `ROMUploadServer.swift:2078` is a lexical
  guard only. A symlink inside the sandbox can escape it.
- `Tests/PVWebServerTests` is Xcode boilerplate with no real tests.
- `WebUploadImportService.swift` (app side) routes every completed upload
  through `ZipImportHelper` and posts a snackbar. iFly has no equivalent. This
  stays as is.

## 2. Goals

1. One port serves both the browser upload UI and WebDAV, with Finder, rclone,
   Cyberduck, Windows WebClient, curl, Safari and Chrome all classified
   correctly per connection.
2. No upload can report success after a partial write. No client path can
   escape the ROM directory, lexically or through a symlink.
3. The upload page matches iFly: parallel raw PUT uploads, byte-weighted
   progress with speed and ETA, folder-preserving drag and drop, move and
   make-folder actions, and a feature probe so optional UI only appears when
   the server supports it.
4. Real unit tests in the package, runnable with `swift test`.
5. A throughput benchmark script and a `make webserver-bench` target.

## 3. Non-goals

- Anything from iFly's `DebugAPIRoutes*`, `/stats` page, or the Debug API
  Basic Auth scheme. iCube's debug API is a separate loopback-only server on
  port 8723 and is out of scope here.
- Pausing background I/O during emulation (iFly's `IOServiceRegistry`).
- Chunked or resumable upload protocols. iFly does not have them either.
- Changing the `PVWebServerFileUploadCompletedNotification` contract or the
  `@objc(PVWebServer)` facade signatures. Consumers keep compiling.

## 4. Design

### 4.1 Single listener with sticky client mode

`ROMUploadServer` keeps one `NWListener`. The listener tries ports in order
`80, 8080, 8000, 8888, 9000` on device and `8080, 8000, 8888, 9000` on
simulator, and records the port it bound. `httpPort` and `webDAVPort` collapse
into one `port`. The facade's `webDavURLString` returns the same URL as
`urlString`, and `isWebDavServerRunning` mirrors `isWWWUploadServerRunning`.

Each `ConnectionContext` gains `clientMode: ClientMode` with cases `unknown`,
`browser`, `webDAV`. Mode resolution per request, in this order, copied from
iFly's `resolveClientMode`:

1. Definitely browser: `PUT /files/…`, `POST /upload`, `POST /move`,
   `POST /mkdir`, `GET /`, `GET /api/…`, `GET /files/…`, `DELETE /files/…`
   with a browser user agent.
2. Definitely WebDAV: method is `PROPFIND`, `PROPPATCH`, `MKCOL`, `MOVE`,
   `COPY`, `LOCK`, or `UNLOCK`.
3. Sticky: if the connection already has a mode, reuse it. Keep-alive
   sockets from Finder pipeline many requests and must not flip mode.
4. WebDAV signal headers: `Depth`, `Translate`, `Destination`, `Lock-Token`,
   `Overwrite`, or an `If` header containing a lock token.
5. User agent: a WebDAV client allowlist (`webdavfs/`, `cyberduck/`,
   `transmit/`, `rclone/`, `davfs2/`, `microsoft-webdav-miniredir/`,
   `gvfs/`, `cadaver/`, `windowsexplorer/`, `curl/` is not on this list)
   returns WebDAV. `mozilla/`, `opera/`, or `applewebkit/` returns browser.
6. Method heuristic for headerless scripts: `OPTIONS` is WebDAV. `GET` or
   `HEAD` of anything other than `/` and `/files/…` is WebDAV. `DELETE`
   outside `/files/` is WebDAV. Everything else is browser.

The resolved mode is written back to the context. `routeRequest` takes the
mode instead of the accept-time flag. The custom-route table
(`CustomHandlerBlock`) is consulted only in browser mode, as today.

Bonjour: the listener's `service` advertises `_http._tcp` under the app
display name. A second `NWListener.Service` for `_webdav._tcp` is not possible
on one listener, so keep the `NetService` based advertiser for `_webdav._tcp`
on the same name and port. mDNSResponder coalesces them.

Connection establishment, from iFly `8839fca00` and `437c45160`:

- Arm the first `receive` in the `.ready` state handler, not immediately
  after `start`.
- Per-connection establishment watchdog of 12 seconds. If no complete request
  parses in that window, cancel the socket so `mount_webdav` retries. Disarm
  on the first parsed request.
- WebDAV file `GET` honours keep-alive by routing through the common finish
  path once the full `Content-Length` has been sent. Browser `GET /files/…`
  keeps `Connection: close`.

### 4.2 Data integrity

`SerialFileWriter` gains `failed: Bool` and `diskFull: Bool`, set when
`FileHandle.write(contentsOf:)` throws (`ENOSPC` maps to `diskFull`), and a
`close() throws` that surfaces the final error. Every upload path (streaming
PUT, chunked PUT, multipart POST) checks the writer on completion:

- Failure: delete the partial file, respond `507 Insufficient Storage` for
  disk full or `500` otherwise, log at error level, and do not post the
  completion notification.
- Truncation: if the socket reports EOF or error before `Content-Length`
  bytes arrived, treat as failure with the same cleanup.

`resolvedPath(_:within:)` is replaced by a new file
`WebServerPathSafety.swift`, copied from iFly (68 lines). It returns
`.ok(URL)`, `.lexicalEscape`, or `.symlinkEscape`. The symlink guard resolves
the deepest existing ancestor on both base and target, then re-appends the
non-existent tail, so a `PUT` to a new file under a symlinked directory is
still caught and the iOS `/var` to `/private/var` link does not cause false
rejections. Every rejection is logged with the reason.

Directory creation and open-for-write failures before a PUT are logged rather
than swallowed.

### 4.3 Upload page

Templates move out of the Swift string into package resources:

```
Source/iOS/PVWebServer/Sources/PVWebServer/Resources/
  upload-page.html
  upload-page.css
  upload-page.js
  nav-fragment.html
```

`Package.swift` declares `resources: [.process("Resources")]`. A new
`WebServerPageRenderer` loads templates from `Bundle.module` and substitutes
`{{PLACEHOLDER}}` tokens (`{{APP_NAME}}`, `{{IP}}`, `{{PORT_SUFFIX}}`,
`{{LISTING_JSON}}`, `{{NAV}}`). The renderer caches loaded templates after
first use.

The page is iFly's `upload-page.*` with iCube branding, adapted to these
server routes:

| Route | Behaviour |
|---|---|
| `GET /` | Render upload page for `?path=` subfolder |
| `GET /api/list?path=` | JSON listing, unchanged |
| `GET /api/health` | `{"ok":true,"app":"iCube","version":…,"features":{"move":true,"mkdir":true,"stats":false}}` |
| `PUT /files/<path>` | New. Streams body to disk like WebDAV PUT. Answers `Expect: 100-continue`. Replaces an existing target before writing. Creates intermediate folders |
| `POST /upload` | Multipart fallback, kept for old bookmarks and curl `-F` |
| `POST /move` | JSON `{from, to}` inside the sandbox |
| `POST /mkdir` | JSON `{path}` |
| `DELETE /files/<path>` | Unchanged |

Client behaviour in `upload-page.js`:

- One shared queue, four concurrent `XMLHttpRequest` PUTs.
- Folder drag and drop walks `webkitGetAsEntry` directories and uploads each
  file to its relative path. Wii and GameCube titles are usually single files,
  but Riivolution and texture pack folders benefit.
- Byte-weighted aggregate progress, exponential moving average speed, ETA,
  and a canvas speed chart.
- The page polls `/api/health` every 15 seconds and shows optional nav items
  only when the matching `features` flag is true. `stats` is false in iCube
  so the Live Stats link never appears. The hook stays so a future page can
  light up without a JS change.

### 4.4 Import handoff

Unchanged contract. On each successful upload the server posts
`PVWebServerFileUploadCompletedNotification` with the file path.
`WebUploadImportService` on the app side keeps its post-processor and summary
hooks. Failed uploads post nothing. Folder uploads post one notification per
file, which is what the service already handles.

### 4.5 App surface changes

- `SettingsRootView` and `LibraryWebImportView` display one URL. The WebDAV
  row becomes a Finder instruction: Connect to Server with the same URL.
- `SourcesView` keeps using `ipAddress` and `bonjourSeverURL` to filter out
  the device's own service.
- `TVRootView` still calls `startServers()` at launch.

### 4.6 Tests

`HTTPRequest`, `StreamingMultipartParser`, `ChunkedBodyReader`,
`SerialFileWriter`, and `WebServerPathSafety` become `internal` so
`@testable import PVWebServer` reaches them. Port iFly's 22 tests into
`Tests/PVWebServerTests/`:

- Request parsing: request line, method and header casing, missing version,
  malformed line, chunked and expect-continue flags, keep-alive, multipart
  boundary, percent-decoded query.
- Path safety: inside sandbox, empty path, dot-dot rejected, sibling prefix
  rejected, symlink escape rejected.
- Chunked decoding: single chunk, multiple chunks, split across feeds, hex
  size and trailer, invalid size.
- Multipart to disk: single file, subfolder preserved, traversal filename not
  written outside the directory, body split across feeds.

New tests for this port:

- Client mode resolution: one case per rule in 4.1, plus a sticky case where
  a WebDAV connection sends a headerless `GET`.
- `SerialFileWriter` failure surfacing with a handle that throws.
- `PUT /files/` route resolves through `WebServerPathSafety` and rejects a
  traversal.

Tests run with `cd Source/iOS/PVWebServer && swift test` on macOS. If the
`UIKit` import blocks a macOS test build, the tests run through the iCube app
test target instead. The implementation plan verifies which.

### 4.7 Benchmark

`Scripts/webserver_transfer_bench.sh` is ported to
`Source/iOS/App/Scripts/webserver_transfer_bench.sh` with the Bonjour service
name set to iCube's display name. It compares WebDAV PUT, browser PUT, and
multipart POST at 256 KB, 8 MB, and 64 MB. `Source/iOS/App/Makefile` gains
`webserver-bench`.

## 5. Error handling

- Port in use: fall through the port list. If every port fails, `startServers`
  returns false and logs the last error. The facade already returns `Bool`.
- Disk full or write failure: see 4.2. The client sees 507 or 500 and the
  partial file is gone.
- Path escape: 403 with a logged reason. No file system access happens before
  the guard passes.
- Connection never sends a request: cancelled by the 12 second watchdog.
- Missing template resource: the renderer falls back to a one-line HTML error
  page naming the missing file, so a packaging mistake is visible in the
  browser instead of a crash.

## 6. Validation gates before merge

Manual, on a device on the LAN, one URL:

1. Finder: Connect to Server as guest, browse, copy a file in, rename, delete.
2. rclone or Cyberduck: list and upload.
3. Safari and Chrome: drag a folder, watch four parallel uploads, confirm the
   files land and the library imports them.
4. curl: `curl -T file http://host/files/file.rvz` and `curl -F` to `/upload`.
5. Fill the disk with a large upload and confirm 507 plus no partial file.
6. `swift test` green. `swiftlint` clean on changed files.

## 7. Sequencing

Each step is a separate commit and leaves the app working:

1. `WebServerPathSafety.swift` and `SerialFileWriter` failure surfacing, with
   their tests. Smallest and most urgent.
2. Package resources, renderer, and the new page, still on two ports. Add
   `PUT /files/`, `/move`, `/mkdir`, `/api/health`.
3. Single listener with sticky client mode, port fallback, establishment
   watchdog, keep-alive GET. Remove the second listener. Update the facade and
   the two settings views.
4. Remaining ported tests, bench script, Makefile target.
