from pathlib import Path
import subprocess,sys
base=Path('/tmp/icube-library-release'); mode=sys.argv[1]
out=base/'native'/mode;out.mkdir(parents=True,exist_ok=True)
dev=Path('/Applications/Xcode_27_1.app/Contents/Developer/Platforms/MacOSX.platform/Developer')
def run(cmd, log):
 with (out/log).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=f)
 if r.returncode:print(log,'failed');raise SystemExit(r.returncode)
for module in ['PVSyncRules','PVCloudSync']:
 files=list((base/module/'Sources'/module).glob('*.swift'))
 if module=='PVSyncRules' and mode=='red':
  baseline=out/'SyncClassifier.swift';baseline.write_text(subprocess.check_output(['git','-C',str(base/module),'show','223d78c829e9456b7f135cca5b594d62f1c63d63:Sources/PVSyncRules/SyncClassifier.swift'],text=True));files=[baseline if f.name=='SyncClassifier.swift' else f for f in files]
 cmd=['xcrun','swiftc','-swift-version','5','-enable-testing','-emit-library','-emit-module','-module-name',module,'-I',str(out),'-L',str(out),'-o',str(out/f'lib{module}.dylib'),'-emit-module-path',str(out/f'{module}.swiftmodule')]
 if module=='PVCloudSync':cmd+=['-lPVSyncRules']
 run(cmd+list(map(str,files)),f'{module}-compile.log')
for module in ['PVSyncRules','PVCloudSync']:
 bundle=out/f'{module}Tests.xctest';(bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
 cmd=['xcrun','swiftc','-swift-version','5','-emit-library','-module-name',module+'Tests','-I',str(out),'-L',str(out),'-lPVSyncRules','-lPVCloudSync','-I',str(dev/'usr/lib'),'-L',str(dev/'usr/lib'),'-F',str(dev/'Library/Frameworks'),'-o',str(bundle/'Contents/MacOS'/f'{module}Tests')]
 for p in [out,dev/'usr/lib',dev/'Library/Frameworks']:cmd+=['-Xlinker','-rpath','-Xlinker',str(p)]
 run(cmd+list(map(str,(base/module/'Tests'/f'{module}Tests').glob('*.swift'))),f'{module}-test-compile.log')
 with (out/f'{module}-tests.log').open('w') as log:r=subprocess.run(['xcrun','xctest',str(bundle)],stdout=log,stderr=log)
 print(module,'test exit',r.returncode)
