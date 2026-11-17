#!/usr/bin/env python3
"""Check a freshly built device core and optionally its archived, stripped/signed copy.

Unselected committed slices are generation scaffolding, not validated fresh cores.
This does not replace building the selected platform from the current checkout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


class IntegrityError(RuntimeError):
    pass


def tool(*arguments):
    try:
        return subprocess.check_output(['xcrun', *map(str, arguments)], text=True,
                                       stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as error:
        raise IntegrityError(f'Native tool failed: {arguments[0]}: {error}') from error


def binary_uuid(path):
    rows = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)',
                      tool('dwarfdump', '--uuid', path), re.MULTILINE)
    if len(rows) != 1 or rows[0][1] != 'arm64':
        raise IntegrityError(f'Expected exactly one arm64 UUID: {path}')
    return rows[0][0].upper()


def device_platform(path, expected):
    actual = re.findall(r'^\s*platform\s+(\S+)\s*$', tool('vtool', '-show-build', path), re.MULTILINE)
    if actual != [expected]:
        raise IntegrityError(f'Wrong Mach-O device platform for {path}: {actual}; expected {expected}')


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


REQUIRED_SLICES = {(platform, variant) for platform in ('ios', 'tvos') for variant in ('', 'simulator')}
# Only a checkout that built the Mac Catalyst core has this slice, so it may be absent.
MAC_SLICE = ('ios', 'maccatalyst')
# Archive platform -> (slice key, vtool platform, CMake build folder SDK, app-relative Frameworks folder).
ARCHIVE_PLATFORMS = {
    'ios': (('ios', ''), 'IOS', 'iphoneos', 'iCube.app/Frameworks'),
    'tvos': (('tvos', ''), 'TVOS', 'appletvos', 'iCube.app/Frameworks'),
    'mac': (MAC_SLICE, 'MACCATALYST', 'macosx', 'iCube.app/Contents/Frameworks'),
}


def slice_layout(key):
    """Name, xcframework identifier and binary path (inside the framework) of one slice."""
    platform, variant = key
    if key == MAC_SLICE:
        # A macOS framework keeps its binary under Versions/A.
        name = 'PVlibDolphin-maccatalyst'
        return name, 'ios-arm64-maccatalyst', f'{name}.framework/Versions/A/{name}'
    name = f'PVlibDolphin-{platform}' + ('-sim' if variant else '')
    return name, f'{platform}-arm64' + ('-simulator' if variant else ''), f'{name}.framework/{name}'


def scaffold(folder):
    xcf = folder / 'PVlibDolphin.xcframework'
    try:
        entries = plistlib.loads((xcf / 'Info.plist').read_bytes())['AvailableLibraries']
        found = {}
        for entry in entries:
            key = (entry['SupportedPlatform'], entry.get('SupportedPlatformVariant', ''))
            if (key not in REQUIRED_SLICES and key != MAC_SLICE) or key in found:
                raise IntegrityError('XCFramework must have exactly four distinct device/simulator slices '
                                     '(plus an optional Mac Catalyst one); duplicate/unknown entry')
            name, identifier, binary = slice_layout(key)
            if (entry['LibraryIdentifier'] != identifier or entry['LibraryPath'] != name + '.framework'
                    or entry['SupportedArchitectures'] != ['arm64']
                    or entry.get('BinaryPath', binary) != binary):
                raise IntegrityError(f'Unexpected XCFramework slice metadata: {entry}')
            alias = folder / binary
            packaged = xcf / identifier / binary
            if not alias.is_file() or not packaged.is_file():
                raise IntegrityError(f'missing generation scaffold binary for {identifier}')
            found[key] = (alias, packaged)
        if not REQUIRED_SLICES <= set(found):
            raise IntegrityError('XCFramework must retain all four generation scaffold slices')
        return found
    except (OSError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        raise IntegrityError(f'Invalid/missing XCFramework scaffold metadata: {error}') from error


def validate(root, platform, archive=None):
    if platform not in ARCHIVE_PLATFORMS:
        raise IntegrityError(f'Unsupported archive platform: {platform}')
    key, macho_platform, sdk, frameworks = ARCHIVE_PLATFORMS[platform]
    root = Path(root)
    slices = scaffold(root / 'build/xcframework')
    if key not in slices:
        raise IntegrityError('No Mac Catalyst core slice: build it with BuildiOSXCFramework.py -p MAC_CATALYST')
    alias, packaged = slices[key]
    digest = file_hash(alias)
    if digest != file_hash(packaged):
        raise IntegrityError(f'Fresh alias and selected packaged binary differ: {alias}, {packaged}')
    device_platform(alias, macho_platform)
    uuid = binary_uuid(alias)
    symbols = tool('nm', '-gjU', alias).splitlines()
    for owner, api in (('State', 'LoadAsAndWait'), ('MFiController', 'GetInputGate'),
                       ('MFiController', 'DisconnectInputGate'), ('MFiController', 'AreControlsNeutral')):
        # nm -gU excludes undefined references: the API must be exported by this binary.
        if not any(re.match(r'^_+ZN', symbol) and owner in symbol and api in symbol for symbol in symbols):
            raise IntegrityError(f'Selected device core does not export current API {owner}::{api}')
    candidates = sorted((root / f'build-{sdk}-Release/Source/iOS/Library').glob('*.dSYM'))
    matches = [path for path in candidates if binary_uuid(path) == uuid]
    if not matches:
        raise IntegrityError(f'No root {sdk} device dSYM matches core UUID {uuid}')
    result = dict(platform=platform, uuid=uuid, alias=str(alias), packaged=str(packaged),
                  sha256=digest, dsym=str(matches[0]))
    if archive is not None:
        embedded = Path(archive) / 'Products/Applications' / frameworks / slice_layout(key)[2]
        if not embedded.is_file():
            raise IntegrityError(f'Archived embedded core missing: {embedded}')
        device_platform(embedded, macho_platform)
        embedded_uuid = binary_uuid(embedded)
        if embedded_uuid != uuid:
            raise IntegrityError(f'Archived embedded core UUID {embedded_uuid} differs from fresh core/dSYM UUID {uuid}')
        # Xcode stripping and signing change bytes. UUID is the archive identity check.
        result.update(embedded=str(embedded), embedded_uuid=embedded_uuid)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=tuple(ARCHIVE_PLATFORMS))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.root, args.platform, args.archive), indent=2))
        return 0
    except (IntegrityError, OSError) as error:
        print(f'device-core: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
