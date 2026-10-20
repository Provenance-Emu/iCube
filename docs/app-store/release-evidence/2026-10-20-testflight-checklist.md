# iOS and tvOS beta test checklist

Candidate build number: **1792472425**, version **1.0.0**. Both platforms are uploaded and VALID in App Store Connect, assigned to Internal and external beta groups; both internal and external states are IN_BETA_TESTING with Beta App Review APPROVED. See [processing status](2026-10-20-native/testflight-processing.json) and [blocker evidence](2026-10-20-release-blocker-fixes.md).

Use legally obtained disc images and a disposable save slot for failure/recovery checks. Record platform, hardware, OS, game, build, and exact steps for each failure.

- **Resolution/performance:** a fresh or reset configuration starts at 1× Native. Existing selections persist. Manual scales and Auto (Fit Window) remain available; dynamic resolution controls are absent. Compare the same scene on the reporting A14 iPad with Native selected.
- **tvOS navigation:** use the Siri Remote and a controller to open Import, View, Sort, Settings and pause screens; scroll to the last row, make a choice, dismiss with Back/Menu, and verify focus returns to a usable control.
- **Settings:** change settings, leave and return, relaunch, and confirm persistence. Test global reset with boot preferences and graphics changes. Open diagnostics and User Folder details; verify full path, Done, and iOS Copy. Confirm restricted store diagnostics remain usable.
- **Default ISO:** set a local disc from the library, inspect and clear it in General, then select it again and boot a homebrew launcher that requires an inserted disc. Move/remove the selected image and verify a useful unavailable-disc message. Ordinary disc launches should still work.
- **Disc change:** pause a two-disc GameCube game at its disc prompt, select the compatible second disc, resume, and continue. Verify Cancel leaves the current disc and pause state unchanged. Check unsupported or unavailable images cannot be selected.
- **Save states:** save and load each quick slot and a manual state; verify timestamp and thumbnail match the completed save. Quit with Save, relaunch and resume. On an induced write failure, confirm Retry, Cancel, and Quit Without Saving behave as labeled and the previous good state remains usable. Restart the same game while a save UI is open and verify stale actions cannot target the new session.
- **Sync:** on two installs, sync a disposable state and normal settings in both directions. Test conflicting edits, failed/offline resolution, account changes and sync interruption around game launch/stop. Offline trash restoration should survive relaunch. RetroAchievements login and DSU server configuration must remain local.
- **Library:** verify editing, scanning, deletion, sharing and Provenance interoperability separately. These remain release acceptance gates and are not proven by the save/settings fixes.

The beta is intended to collect device evidence. Passing this checklist does not automatically close the remaining release-plan gates.
