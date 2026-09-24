# App Group `group.com.joemattiello.icube`

The Top Shelf and Quick Look extensions read a snapshot the app writes into this
group. Automatic signing registers the group on first build when Xcode is allowed
to update provisioning (`-allowProvisioningUpdates`, or the Xcode UI). If a build
fails with "Provisioning profile doesn't include the com.apple.security.application-groups
entitlement", do the portal steps once:

1. developer.apple.com → Identifiers → App Groups → (+) → identifier
   `group.com.joemattiello.icube`, description "iCube".
2. Identifiers → App IDs → enable **App Groups** and tick the group on every shipping
   bundle id (see `appConfigs` in `Source/iOS/App/Project.swift`):
   `com.joemattiello.iCube`, `-debug`, `-debug-jb`, `-jb`, `-ts`,
   `-njb-patreon-beta`, `-patreon-beta-jb`, `-ts-patreon-beta`,
   and their extension ids (`<app id>.topshelf`, `<app id>.thumbnail`, `<app id>.preview`).
3. Regenerate any manual profiles. Automatic signing does this itself.

## Trap: wildcard profiles

A "Team Provisioning Profile: *" cannot carry App Groups. A tvOS build signed with
one installs and runs, the extension loads, and every tile shows a title with **no
artwork** because the process is not actually a member of the group. iFly hit this
(`Scripts/release.sh` there passes `-allowProvisioningUpdates` for that reason).
Check with:

    codesign -d --entitlements :- /path/to/iCube.app | grep -A2 application-groups

## Sideload / CI re-sign

`Project/Scripts/CreateIpa.sh` signs `PlugIns/*.appex` with
`Project/Entitlements/Extension.entitlements` before signing the app. AltStore and
SideStore re-sign everything again with the user's own team, which does register
App Groups automatically.
