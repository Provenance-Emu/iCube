"""Integrity regressions using real package files and captured Apple-tool output shapes."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

CHECK = Path(__file__).with_name('check_device_core.py')
UUID = '12345678-1234-1234-1234-123456789ABC'
OTHER_UUID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
SYMBOLS = '''__ZN5State13LoadAsAndWaitERNS_6SystemENSt3__112basic_stringIcEE
__ZN6ciface3iOS13MFiController12GetInputGateEP12GCController
__ZN6ciface3iOS13MFiController19DisconnectInputGateEP12GCController
__ZN6ciface3iOS13MFiController18AreControlsNeutralEP12GCController
'''


class DeviceCoreTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CHECK.is_file(), 'Device-core integrity guard is not implemented')
        spec = importlib.util.spec_from_file_location('check_device_core', CHECK)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'build/xcframework'
        self.xcf = self.folder / 'PVlibDolphin.xcframework'
        self.entries = []
        for platform in ('ios', 'tvos'):
            for simulator in (False, True):
                suffix = '-sim' if simulator else ''
                name = f'PVlibDolphin-{platform}{suffix}'
                identifier = f'{platform}-arm64' + ('-simulator' if simulator else '')
                entry = dict(LibraryIdentifier=identifier, LibraryPath=name + '.framework',
                             BinaryPath=f'{name}.framework/{name}', SupportedPlatform=platform,
                             SupportedArchitectures=['arm64'])
                if simulator:
                    entry['SupportedPlatformVariant'] = 'simulator'
                self.entries.append(entry)
                for binary in (self.folder / f'{name}.framework/{name}',
                               self.xcf / identifier / f'{name}.framework/{name}'):
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b'fresh core')
        self.write_info()
        self.platforms = {}
        self.uuids = {}
        self.symbols = SYMBOLS
        for sdk in ('iphoneos', 'appletvos'):
            dsym = self.root / f'build-{sdk}-Release/Source/iOS/Library/libdolphin.dylib.dSYM'
            dsym.mkdir(parents=True)
        self.mock_tool = mock.patch.object(self.guard.subprocess, 'check_output', side_effect=self.tool)
        self.mock_tool.start()
        self.addCleanup(self.mock_tool.stop)

    def write_info(self):
        self.xcf.mkdir(parents=True, exist_ok=True)
        (self.xcf / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': self.entries}))

    def tool(self, args, **kwargs):
        tool, path = args[1], Path(args[-1])
        if tool == 'nm':
            return self.symbols
        if tool == 'vtool':
            default = 'TVOS' if 'tvos' in path.name else 'IOS'
            return f'{path}:\nLoad command 7\n      cmd LC_BUILD_VERSION\n platform {self.platforms.get(path, default)}\n    minos 17.0\n      sdk 26.2\n'
        if tool == 'dwarfdump':
            return f'UUID: {self.uuids.get(path, UUID)} (arm64) {path}\n'
        raise AssertionError(f'Unexpected external tool: {args}')

    def alias(self, platform='ios'):
        return self.folder / f'PVlibDolphin-{platform}.framework/PVlibDolphin-{platform}'

    def assert_rejected(self, message, platform='ios', **kwargs):
        with self.assertRaisesRegex(self.guard.IntegrityError, message):
            self.guard.validate(self.root, platform, **kwargs)

    def test_both_device_platforms_accept_matching_fresh_core(self):
        for platform in ('ios', 'tvos'):
            with self.subTest(platform=platform):
                result = self.guard.validate(self.root, platform)
                self.assertEqual(result['uuid'], UUID)
                self.assertEqual(result['platform'], platform)

    def test_stale_selected_packaged_binary_is_rejected(self):
        target = self.xcf / 'ios-arm64/PVlibDolphin-ios.framework/PVlibDolphin-ios'
        target.write_bytes(b'old core with old APIs')
        self.assert_rejected('alias.*packaged')

    def test_missing_scaffold_entry_is_rejected_before_generation(self):
        self.entries.pop()
        self.write_info()
        self.assert_rejected('four.*slices')

    def test_duplicate_device_metadata_cannot_replace_simulator(self):
        self.entries[-1] = self.entries[0].copy()
        self.write_info()
        self.assert_rejected('duplicate|four.*slices')

    def test_unexpected_architecture_or_path_is_rejected(self):
        self.entries[0]['LibraryPath'] = '../foreign.framework'
        self.write_info()
        self.assert_rejected('metadata')
        self.entries[0]['LibraryPath'] = 'PVlibDolphin-ios.framework'
        self.entries[0]['SupportedArchitectures'] = ['x86_64']
        self.write_info()
        self.assert_rejected('metadata')

    def test_missing_unselected_scaffold_binary_is_rejected(self):
        (self.xcf / 'tvos-arm64-simulator/PVlibDolphin-tvos-sim.framework/PVlibDolphin-tvos-sim').unlink()
        self.assert_rejected('missing.*scaffold')

    def test_simulator_or_other_device_macho_is_rejected(self):
        for wrong in ('IOSSIMULATOR', 'TVOS', '7'):
            self.platforms[self.alias()] = wrong
            self.assert_rejected('device platform')

    def test_missing_current_native_api_is_rejected_individually(self):
        for api in ('LoadAsAndWait', 'GetInputGate', 'DisconnectInputGate', 'AreControlsNeutral'):
            self.symbols = '\n'.join(row for row in SYMBOLS.splitlines() if api not in row)
            self.assert_rejected(api)

    def test_stale_or_missing_root_device_dsym_is_rejected(self):
        dsym = self.root / 'build-iphoneos-Release/Source/iOS/Library/libdolphin.dylib.dSYM'
        self.uuids[dsym] = OTHER_UUID
        self.assert_rejected('dSYM.*UUID')
        dsym.rmdir()
        self.assert_rejected('dSYM')

    def test_matching_embedded_uuid_allows_strip_or_sign_byte_changes(self):
        archive = self.root / 'iCube.xcarchive'
        embedded = archive / 'Products/Applications/iCube.app/Frameworks/PVlibDolphin-ios.framework/PVlibDolphin-ios'
        embedded.parent.mkdir(parents=True)
        embedded.write_bytes(b'different bytes after Xcode signing and stripping')
        result = self.guard.validate(self.root, 'ios', archive=archive)
        self.assertEqual(result['embedded_uuid'], UUID)
        self.uuids[embedded] = OTHER_UUID
        self.assert_rejected('embedded.*UUID', archive=archive)

    def test_missing_or_wrong_platform_embedded_core_is_rejected(self):
        archive = self.root / 'iCube.xcarchive'
        self.assert_rejected('embedded.*missing', archive=archive)
        embedded = archive / 'Products/Applications/iCube.app/Frameworks/PVlibDolphin-ios.framework/PVlibDolphin-ios'
        embedded.parent.mkdir(parents=True)
        embedded.write_bytes(b'embedded')
        self.platforms[embedded] = 'IOSSIMULATOR'
        self.assert_rejected('device platform', archive=archive)

    def test_empty_or_multiple_architecture_uuid_output_fails_closed(self):
        for output in ('', f'UUID: {UUID} (x86_64) binary\n',
                       f'UUID: {UUID} (arm64) binary\nUUID: {OTHER_UUID} (arm64) binary\n'):
            with mock.patch.object(self.guard.subprocess, 'check_output', return_value=output):
                self.assert_rejected('UUID|device platform')

    def test_native_tool_failure_fails_closed(self):
        with mock.patch.object(self.guard.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'xcrun')):
            self.assert_rejected('tool')


class WorkflowDeviceBuildTests(unittest.TestCase):
    def run_build_step(self, platform, fail_script=''):
        workflow = CHECK.parents[2] / '.github/workflows/testflight.yml'
        lines = workflow.read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if 'name: Build PVlibDolphin xcframework' in line)
        run = next(i for i in range(start, len(lines)) if lines[i].strip() == 'run: |')
        body = []
        for line in lines[run + 1:]:
            if line.strip() and not line.startswith('          '):
                break
            body.append(line[10:])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            calls = path / 'calls'
            stub = path / 'python3'
            stub.write_text('#!' + os.sys.executable + '\nimport json, os, sys\n'
                            'with open(os.environ["CALLS"], "a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                            'sys.exit(7 if sys.argv[1] == os.environ.get("FAIL_SCRIPT") else 0)\n')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=str(path) + ':/usr/bin:/bin', CALLS=str(calls),
                       FAIL_SCRIPT=fail_script, DOL_ARCHIVE_PLATFORM=platform)
            result = subprocess.run(['/bin/bash', '-c', '\n'.join(body)], cwd=path, env=env,
                                    capture_output=True, text=True)
            return result.returncode, [json.loads(row) for row in calls.read_text().splitlines()] if calls.exists() else []

    def test_each_archive_job_builds_only_its_device_then_validates(self):
        for platform, core in [('ios', 'OS64'), ('tvos', 'TVOS')]:
            status, calls = self.run_build_step(platform)
            self.assertEqual(status, 0)
            self.assertEqual(calls, [['BuildiOSXCFramework.py', '--platforms', core],
                                     ['Tools/release-audit/check_device_core.py', '--platform', platform]])

    def test_core_build_or_guard_failure_stops_step(self):
        for failing in ('BuildiOSXCFramework.py', 'Tools/release-audit/check_device_core.py'):
            status, calls = self.run_build_step('ios', failing)
            self.assertEqual(status, 7)
            self.assertEqual(len(calls), 1 if failing == 'BuildiOSXCFramework.py' else 2)


if __name__ == '__main__':
    unittest.main()
