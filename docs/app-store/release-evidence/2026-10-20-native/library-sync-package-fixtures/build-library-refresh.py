from pathlib import Path
import subprocess
root=Path('/tmp/icube-library-release/library-refresh');root.mkdir(exist_ok=True)
s=Path('Source/iOS/App/Common/Swift/RemoteSourcesCoordinator.swift').read_text();s='@MainActor\n'+s[s.index('final class LibraryCoordinator:'):]
(root/'LibraryCoordinator.swift').write_text('import Foundation\nimport Combine\n'+s)
t=Path('Source/iOS/App/DolphiniOSTests/LibraryIdleDuringPlayTests.swift').read_text();start=t.index('@MainActor\nfinal class LibraryCoordinatorDeferralTests:');end=t.index('@MainActor\nfinal class LibrarySnapshotSchedulerTests:',start)
(root/'Tests.swift').write_text('import Foundation\nimport Combine\nimport XCTest\n'+t[start:end])
(root/'Adapters.swift').write_text('''import Foundation
import os
struct TVGameItem {}
enum TVLibraryBridge { static func currentGames()->[TVGameItem] { [] }; static func rescanLocalAndFetchMetadata(_ completion: @escaping ()->Void) { completion() } }
enum ICubeLog { static func logger(_ name:String)->Logger { Logger(subsystem:"LibraryRefreshAudit", category:name) } }
enum SentryTelemetryService { static func beginTrace(_ name:String,op:String,tags:[String:String])->Int { 0 }; static func finishTrace(_ value:Int) {} }
@MainActor enum LibraryMetadataService {
 static var warmingRequests = 0
 static func warmContentIdentities(for items:[TVGameItem]) { warmingRequests += 1 }
}
func L(_ value:String)->String {value}
''')
(root/'WarmTests.swift').write_text('''import Foundation
import XCTest
@MainActor final class LibraryWarmWiringTests: XCTestCase {
 func testIdleLibraryLoadRequestsWarm() {
  LibraryMetadataService.warmingRequests = 0
  let state = EmulationState(center:NotificationCenter())
  let subject = LibraryCoordinator(emulationState:state, gamesProvider:{[]})
  subject.loadCurrent()
  XCTAssertEqual(LibraryMetadataService.warmingRequests,1)
 }
 func testForcedFirstLoadDuringEmulationPublishesWithoutWarm() {
  LibraryMetadataService.warmingRequests = 0
  let state = EmulationState(center:NotificationCenter())
  state.setActive(true)
  var loads = 0
  let subject = LibraryCoordinator(emulationState:state, gamesProvider:{loads += 1; return []})
  subject.start()
  XCTAssertEqual(loads,1)
  XCTAssertEqual(LibraryMetadataService.warmingRequests,0)
 }
 func testDeferredReloadRequestsWarmAfterSessionEnds() {
  LibraryMetadataService.warmingRequests = 0
  let state = EmulationState(center:NotificationCenter())
  let subject = LibraryCoordinator(emulationState:state, gamesProvider:{[]})
  state.setActive(true)
  subject.loadCurrent()
  XCTAssertEqual(LibraryMetadataService.warmingRequests,0)
  state.setActive(false)
  XCTAssertEqual(LibraryMetadataService.warmingRequests,1)
 }
}
''')
dev=Path('/Applications/Xcode_27_1.app/Contents/Developer/Platforms/MacOSX.platform/Developer')
bundle=root/'LibraryRefresh.xctest';(bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
cmd=['xcrun','swiftc','-swift-version','5','-emit-library','-module-name','LibraryRefresh','-I',str(dev/'usr/lib'),'-L',str(dev/'usr/lib'),'-F',str(dev/'Library/Frameworks'),'-o',str(bundle/'Contents/MacOS/LibraryRefresh')]
for p in [dev/'usr/lib',dev/'Library/Frameworks']:cmd+=['-Xlinker','-rpath','-Xlinker',str(p)]
cmd+=list(map(str,root.glob('*.swift')))+['Source/iOS/App/Common/Services/EmulationState.swift']
with (root/'compile.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=f)
print('compile',r.returncode);raise SystemExit(r.returncode)
