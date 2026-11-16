# apple-app-site-association (universal links for icube-emu.com)

`apple-app-site-association` in this folder is the file that lets iOS and iPadOS open
`https://icube-emu.com/play?id=<game id>` in iCube. It is **not deployed**: the website lives in its own
repository (`icube-emu.github.io`) and publishing it is the site owner's step.

What the app does with a link: `Common/Services/UniversalLinkRouter.swift` maps it onto
`dolphinios://play?id=<game id>`, the route `URLRouterService` already serves. Anything else on the domain is
ignored by the app. Keep the file's `components` equal to the routes `UniversalLinkRouter` maps (today only
`/play`), so the app is never handed a link it ignores.

## Contents

- Team ID `S32Z3HMYVQ` (`DEVELOPMENT_TEAM` in `Source/iOS/App/Project.swift`), bundle id
  `com.joemattiello.iCube` (the App Store configurations). Other configurations (debug, TrollStore, beta) have
  other bundle ids and no associated-domains entitlement, so they never claim these links.
- The app side is already in place: `applinks:icube-emu.com` in `Source/iOS/App/DolphiniOS/iCube AppStore.entitlements`.
  `www.icube-emu.com` is not entitled; a link on `www` opens Safari unless that host also serves this file and the
  entitlement gets a second line.

## Where and how to host it

- URL: `https://icube-emu.com/.well-known/apple-app-site-association` (no file extension).
- HTTPS with a valid certificate, status 200, **no redirects** (a redirect to `www` or to another host fails
  validation), body is the JSON above, served as `application/json` (the file is under 128 KB).
- GitHub Pages: Jekyll skips dot-folders, so add an empty `.nojekyll` to the site root (or `include: [".well-known"]`
  in `_config.yml`). Pages serves an extensionless file as `application/octet-stream`; if the site is behind
  Cloudflare, a Transform Rule can set `Content-Type: application/json` for that path. Check the real headers with
  `curl -sI https://icube-emu.com/.well-known/apple-app-site-association`.
- Add a `/play` page to the site for people without the app (link to the App Store); it is also what Safari shows
  when a link is opened from a context that does not hand it to the app.

## Verifying

- Apple's CDN fetches the file, caches it, and devices update from the CDN, which can take hours or days. See what
  it has: `curl https://app-site-association.cdn-apple.com/a/v1/icube-emu.com`.
- For a development build, append `?mode=developer` to the associated-domain entry (`applinks:icube-emu.com?mode=developer`)
  and enable Settings > Developer > Associated Domains Development on the device; this bypasses the CDN. Do not
  ship that form.
- On a device with the app installed: paste `https://icube-emu.com/play?id=<id of a game in the library>` into Notes
  and tap it (typing it into Safari's address bar never opens an app). Long-press the link: the menu should offer "Open in iCube".

## Owner steps

1. Enable the **Associated Domains** capability on the App ID `com.joemattiello.iCube` in the developer portal
   (and regenerate the provisioning profiles; automatic signing does this itself). The entitlement is already in
   the AppStore entitlements file, so a profile without the capability fails to sign.
2. Publish this file at the URL above (with `.nojekyll`), plus the `/play` fallback page.
3. Test on a device as described under Verifying.
