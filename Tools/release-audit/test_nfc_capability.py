#!/usr/bin/env python3
"""Run the production ObjC NFC probe and Swift cache without an app/core build."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
NFC = ROOT / "Source/iOS/App/Common/Ecosystem/NFC"
FIXTURE = pathlib.Path(__file__).parent / "fixtures/nfc-capability"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(f"Command failed ({result.returncode}): {args}\n"
                             f"{result.stdout}\n{result.stderr}")
    return result


class NFCCapabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        temp = pathlib.Path(cls.temp.name)
        bridge = temp / "Bridge.h"
        bridge.write_text(f'#import "{NFC / "DOLNFCCapability.h"}"\n'
                          f'#import "{FIXTURE / "Fixture.h"}"\n')
        objects = []
        for source in (NFC / "DOLNFCCapability.m", FIXTURE / "Fixture.m"):
            obj = temp / (source.stem + ".o")
            run("xcrun", "clang", "-fobjc-arc", "-fobjc-exceptions", "-fblocks",
                "-include", str(FIXTURE / "ProbePrefix.h"),
                "-I", str(FIXTURE), "-c", str(source), "-o", str(obj))
            objects.append(str(obj))
        cls.executable = str(temp / "nfc-test")
        run("xcrun", "swiftc", "-swift-version", "6", "-import-objc-header", str(bridge),
            str(NFC / "NonBlockingCapability.swift"), str(FIXTURE / "main.swift"),
            *objects, "-o", cls.executable)
        cls.unsupported = []
        for define in ("NFC_FIXTURE_SIMULATOR", "NFC_FIXTURE_TV"):
            obj = temp / (define + ".o")
            run("xcrun", "clang", "-fobjc-arc", "-fobjc-exceptions", "-fblocks",
                "-include", str(FIXTURE / "ProbePrefix.h"), "-D" + define,
                "-I", str(FIXTURE), "-c", str(NFC / "DOLNFCCapability.m"), "-o", str(obj))
            executable = str(temp / define)
            run("xcrun", "swiftc", "-swift-version", "6", "-import-objc-header", str(bridge),
                str(NFC / "NonBlockingCapability.swift"), str(FIXTURE / "main.swift"),
                str(obj), objects[1], "-o", executable)
            cls.unsupported.append(executable)

    def test_objc_exception_returns_false_and_is_cached(self):
        self.assertIn("PASS", run(self.executable, "0").stdout)

    def test_supported_phone_caches_true(self):
        self.assertIn("PASS", run(self.executable, "1").stdout)

    def test_unsupported_phone_caches_false(self):
        self.assertIn("PASS", run(self.executable, "2").stdout)

    def test_ipad_never_calls_nfc(self):
        self.assertIn("PASS", run(self.executable, "3").stdout)

    def test_stalled_probe_never_blocks_readers_or_caches_true_early(self):
        self.assertIn("PASS", run(self.executable, "4").stdout)

    def test_simulator_and_tv_never_call_nfc(self):
        for executable in self.unsupported:
            with self.subTest(executable=pathlib.Path(executable).name):
                self.assertIn("PASS", run(executable, "5").stdout)

    def test_real_device_and_simulator_sdk_compilers(self):
        # No fixture includes: verify the public SDK API, platform gates and Swift import.
        for sdk, target in (("iphoneos", "arm64-apple-ios16.0"),
                            ("iphonesimulator", "arm64-apple-ios16.0-simulator"),
                            ("appletvos", "arm64-apple-tvos16.0"),
                            ("appletvsimulator", "arm64-apple-tvos16.0-simulator")):
            with self.subTest(sdk=sdk):
                sdk_path = run("xcrun", "--sdk", sdk, "--show-sdk-path").stdout.strip()
                run("xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                    "-fobjc-arc", "-fobjc-exceptions", "-Werror", "-fsyntax-only",
                    str(NFC / "DOLNFCCapability.m"))
                check = pathlib.Path(self.temp.name) / "ProbeCheck.swift"
                check.write_text("let capability = NonBlockingCapability { DOLNFCReadingAvailable() }\n")
                run("xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-target", target,
                    "-sdk", sdk_path, "-import-objc-header", str(NFC / "DOLNFCCapability.h"),
                    str(NFC / "NonBlockingCapability.swift"), str(check))


if __name__ == "__main__":
    unittest.main()
