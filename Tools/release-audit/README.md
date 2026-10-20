# Release artifact checks

`check_resolution_core.py` verifies a packaged Dolphin xcframework or an embedded `.framework` after adaptive internal resolution was removed. It checks every supplied slice, requires the iOS/tvOS device and simulator slices for an xcframework, identifies the normal resolution symbol, and rejects retired controller/bootstrap/config content. Catalyst is inspected when included.

```sh
python3 Tools/release-audit/check_resolution_core.py build/xcframework/PVlibDolphin.xcframework
python3 Tools/release-audit/check_resolution_core.py /absolute/path/to/iCube.app/Frameworks/PVlibDolphin-ios.framework
```

Output records binary paths, sizes and SHA-256 hashes. Missing files/slices, `nm` errors, unidentified cores and retired content fail with exit 1. The old simulator core fails this check; rebuilding only the Swift app is insufficient. Use the actual embedded framework name from the app bundle.

This establishes artifact contents, not gameplay behavior. Still check a legacy config with adaptive enable set, stable fixed resolution across load/thermal changes, manual/fit-window options, and CPU/VI classification on a device.
