#!/usr/bin/env python3
"""Run the actual Foundation remote-navigation tests without SwiftPM setup."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]

def main():
    developer = Path(os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['xcode-select','-p'],text=True).strip())
    platform = developer/'Platforms/MacOSX.platform/Developer'
    libraries, frameworks = platform/'usr/lib', platform/'Library/Frameworks'
    app = ROOT/'Source/iOS/App'
    with tempfile.TemporaryDirectory(prefix='icube-remote-performance-') as directory:
        folder=Path(directory)
        source=(app/'DolphiniOSTests/RemotePerformanceNavigationTests.swift').read_text()
        (folder/'Tests.swift').write_text(source.replace('@testable import iCube',''))
        (folder/'main.swift').write_text('import XCTest\nlet suite = RemotePerformanceNavigationTests.defaultTestSuite\nsuite.run()\nexit(suite.testRun!.hasSucceeded ? 0 : 1)\n')
        command=['xcrun','swiftc','-swift-version','5','-I',str(libraries),'-L',str(libraries),'-F',str(frameworks),
          '-Xlinker','-rpath','-Xlinker',str(libraries),'-Xlinker','-rpath','-Xlinker',str(frameworks)]
        command += [str(app/'Common/Swift/Performance'/(name+'.swift')) for name in ('RemotePerformanceNavigation','SiriRemoteMenuAction')]
        command += [str(folder/'Tests.swift'),str(folder/'main.swift'),'-o',str(folder/'tests')]
        compiled=subprocess.run(command)
        return compiled.returncode or subprocess.run([str(folder/'tests')]).returncode

if __name__ == '__main__':
    raise SystemExit(main())
