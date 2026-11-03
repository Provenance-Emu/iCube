#!/usr/bin/env python3
"""Run the production library sizing helper and its XCTest suite on the host, without the core."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Source/iOS/App'


def main():
    developer = Path(os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer / 'Platforms/MacOSX.platform/Developer'
    libraries, frameworks = platform / 'usr/lib', platform / 'Library/Frameworks'
    view = (APP / 'Common/Swift/TVLibraryView.swift').read_text()
    layout = view[view.index('enum LibraryLayout {'):view.index('\nprivate final class KeyInputView')]
    tests = (APP / 'DolphiniOSTests/LibraryGridSizingTests.swift').read_text().replace('@testable import iCube', '')
    with tempfile.TemporaryDirectory(prefix='icube-grid-sizing-') as directory:
        folder = Path(directory)
        (folder / 'LibraryLayout.swift').write_text('import Foundation\n' + layout)
        (folder / 'Tests.swift').write_text(tests)
        (folder / 'main.swift').write_text('import XCTest\nlet suite = LibraryGridSizingTests.defaultTestSuite\nsuite.run()\nexit(suite.testRun!.hasSucceeded ? 0 : 1)\n')
        result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-I', str(libraries), '-L', str(libraries), '-F', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(libraries), '-Xlinker', '-rpath', '-Xlinker', str(frameworks), str(folder / 'LibraryLayout.swift'), str(folder / 'Tests.swift'), str(folder / 'main.swift'), '-o', str(folder / 'tests')])
        if result.returncode:
            return result.returncode
        return subprocess.run([str(folder / 'tests')]).returncode


if __name__ == '__main__':
    raise SystemExit(main())
