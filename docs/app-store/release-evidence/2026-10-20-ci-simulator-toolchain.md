# CI simulator toolchain diagnosis — 2026-10-20

Status: **runner repair blocked by administrator privileges**. The final idle check passed and authorized first-launch setup was attempted, but component installation was denied. This is separate from the local metadata-test fixture initializer compile error, which root corrected locally.

## Observed failure

[Unit Tests run 39389325127](https://github.com/Provenance-Emu/iCube/actions/runs/39389325127), job `118516749380`, source `e1b860e9567ee438025b47f7a90199fe246de871`, failed before compilation or test execution. `xcodebuild` reported installed CoreSimulator `1171.7.0` older than required build `1174.9.2`, disabled simulator support, then could not resolve destination `860B302F-AA25-4CA4-B8AA-C64B1D72FAAB`. Exit was xcodebuild 70 → make/process 2. The failed step contains no Swift compiler error.

The workflow's simulator picker successfully read that iPhone 18 Pro UDID from `simctl`, but Xcode's DVT rejected the incompatible CoreSimulator installation. The same compatibility error was already present during project generation. Merely selecting another listed UDID does not repair this framework mismatch.

Raw scratch evidence:

- `/tmp/icube-unit-tests-39389325127-job118516749380.log` — failed step, compatibility error at lines 30–40 and destination failure at 158.
- `/tmp/icube-unit-tests-39389325127-full.log` — actual Xcode version at 69–70, earlier generation error at 894–905, simulator selection at 985–988.
- `/tmp/icube-runner-toolchains-2026-10-20.txt` — read-only SSH inventory and first-launch check.

Reproduce log retrieval with explicit repository selection (`gh` otherwise selected upstream Dolphin in this checkout):

```sh
gh run view 39389325127 --repo Provenance-Emu/iCube --job 118516749380 --log-failed
```

## Verified runner inventory

Read-only SSH through existing `studio-runner` configuration reached hostname `Mac`, matching the CI runner machine. Application directories, user Applications directories and Spotlight inventory found only `/Applications/Xcode.app`, version **27.1**, build **27A9275**. `xcode-select -p` selects its `Contents/Developer` directory. Repository variable `XCODE_PATH` is absent, so the workflow's self-hosted fallback resolves to that installation; the nominal `XCODE_VERSION: 26.3` environment value applies to the hosted selection path and does not pin this self-hosted Xcode.

The installed system CoreSimulator framework plist reports **1171.7**. The runtime image registry lists iOS **27.0 (24A434)** and tvOS **27.0 (24J360)**; runtime images use cryptex-backed paths, so an empty `/Library/Developer/CoreSimulator/Volumes` does not establish that no runtime is installed. No older usable Xcode/runtime pair was verified.

Read-only `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -checkFirstLaunchStatus` returned **69**, indicating pending first-launch setup. Completing the selected Xcode's setup is the proposed alignment; an older installed Xcode pin is not available from this inventory.

## Repair authorization and idle gates

Root authorized selected-Xcode `-runFirstLaunch` (noninteractive, `sudo -n` only if needed), conditional on the shared host being idle. No process kills, manual global service restarts or new runtime installation were authorized or performed.

The first check found iCube runner `21` idle but Provenance runner `23` busy, with live Provenance worker PID `74592` restoring its build cache. [Provenance Build and Upload run 39391782771](https://github.com/Provenance-Emu/Provenance/actions/runs/39391782771) was active. Component setup was withheld because it affects the shared host.

The requested single recheck at **08:40 UTC** found Provenance runner `23` idle, but **iCube runner `21` busy**, running [Unit Tests 39394980637](https://github.com/Provenance-Emu/iCube/actions/runs/39394980637) at `d8bcdee056a1973390c18858e29603362595275e`. Process inventory showed live iCube `Runner.Worker` PID `12696` and `xcodebuild test` PID `14843`, targeting the same simulator UDID. Setup was again withheld. Evidence: `/tmp/icube-runner-processes-before-firstlaunch-2026-10-20.txt` and `/tmp/icube-runner-processes-recheck-2026-10-20.txt`.

Root's disk preflight at `d8bcdee056` reported 14.83GiB free and no abandoned iCube core intermediates; no cleanup was performed by this investigation.

The final requested check at **08:49:39 UTC** found both online runners `21` and `23` reporting `busy: false`, no active iCube workflow, and no remote `Runner.Worker`, `xcodebuild`, `xcbuild`, compiler or test processes. Evidence: `/tmp/icube-runner-processes-final-recheck-2026-10-20.txt`. The idle condition was satisfied.

Authorized nonprivileged setup was then attempted with the selected Xcode:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -runFirstLaunch
```

It printed `Install Started`, then `Install Failed: Authorization is required to install the packages.` A subsequent `-checkFirstLaunchStatus` still exited **69**. The authorized noninteractive elevation attempt:

```sh
sudo -n /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -runFirstLaunch
```

failed immediately with `sudo: a password is required` (exit 1). No password prompt was opened or bypassed. Scratch logs: `/tmp/icube-runner-firstlaunch-2026-10-20.log` and `/tmp/icube-runner-firstlaunch-sudo-2026-10-20.log`. Administrator-authorized runner maintenance is now required; retrying identical unprivileged commands cannot complete setup.

## Remaining verification

An administrator must complete the selected-Xcode first-launch setup while both repository runners are idle. Record its exit/output, confirm `-checkFirstLaunchStatus` succeeds and the installed CoreSimulator version meets the selected Xcode requirement, then confirm the intended UDID is eligible in `xcodebuild -showdestinations` for the generated iCube scheme. Do not substitute `simctl list` alone. Rerun CI only after destination eligibility is established. No setup success, destination eligibility or CI test pass is claimed here.
