#!/usr/bin/env python3
"""Incremental, opt-in DEV build and native test loop. Python standard library only."""
import argparse
import copy
from contextlib import contextmanager
import fcntl
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'Source/iOS/App'
STATE = ROOT / 'build/dev-loop'
DEV_BUNDLE = 'com.joemattiello.iCube-debug'
CORE_PATHS = ['Source/Core', 'Source/iOS/Library', 'CMake', 'CMakeLists.txt', 'Source/CMakeLists.txt', 'Source/iOS/CMakeLists.txt', 'BuildiOSXCFramework.py', 'Externals']
SUITES = {
    'settings': ('tvos', 'TVSettingsInteractionAuditTests.swift', 'TVSettingsInteractionAuditTests'),
    'library': ('tvos', 'TVLibraryEditingAuditTests.swift', 'TVLibraryEditingAuditTests'),
    'pause-exit': ('ios', 'IOSPauseExitAuditTests.swift', 'IOSPauseExitAuditTests'),
    'portrait': ('ios', 'PlayControlsPortraitAuditTests.swift', 'PlayControlsPortraitAuditTests'),
    'physical-play': ('ios', 'PhysicalPlayControlsSmokeTests.swift', 'PhysicalPlayControlsSmokeTests'),
    'actions': ('both', 'FastInteractionTests.swift', 'FastInteractionTests'),
}

def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default

def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)

def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): digest.update(block)
    return digest.hexdigest()

def digest_paths(paths):
    digest = hashlib.sha256()
    files = []
    for path in paths:
        if path.is_dir(): files.extend(p for p in path.rglob('*') if p.is_file())
        elif path.is_file(): files.append(path)
    for path in sorted(set(files)):
        digest.update(str(path).encode()); digest.update(file_hash(path).encode())
    return digest.hexdigest()

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()

def core_trees(commit):
    return git('ls-tree', commit, '--', *CORE_PATHS)

def clean_core():
    if git('status', '--porcelain', '--untracked-files=all', '--', *CORE_PATHS):
        raise ValueError('Core inputs have dirty/untracked files. Build and accept the core explicitly first.')
    # A dirty nested submodule must not be hidden by a superproject setting.
    dirty = git('submodule', 'foreach', '--quiet', '--recursive', 'git status --porcelain --untracked-files=all')
    if dirty: raise ValueError('A submodule has dirty/untracked inputs; cannot reuse accepted core.')

def validate_artifacts(rows):
    if not rows: raise ValueError('No accepted core artifacts')
    for row in rows:
        path = Path(row['binary'])
        if not path.is_file() or file_hash(path) != row['sha256']:
            raise ValueError('Core artifact changed or missing: ' + str(path))

def adopt_baseline(manifest_path, pin_core=False, target=None):
    manifest = read_json(manifest_path)
    if not manifest: raise ValueError('Missing candidate manifest')
    for platform in ('ios', 'tvos'):
        item = manifest['platforms'][platform]
        for stage in ('validation', 'ipa_validation'):
            accepted=item.get(stage,{})
            if accepted.get('status')!='passed' or accepted.get('source_commit')!=manifest['source_commit'] or str(accepted.get('build_number'))!=str(manifest['build_number']):
                raise ValueError('Both platforms need matching passed archive and IPA validation')
    commit = manifest['source_commit']
    if not pin_core:
        clean_core()
        if core_trees(commit) != core_trees('HEAD'): raise ValueError('Accepted and current core input trees differ')
    proof = read_json(manifest_path.parent / (str(manifest['build_number']) + '-ios-package-core.json'))
    if not proof or proof.get('result') != 'passed': raise ValueError('Missing passed packaged-core proof')
    rows = proof['artifacts']
    scope=None
    if target is not None:
        scope={'platform':target['platform'],'kind':target['kind']}
        selected='PVlibDolphin-'+target['platform']+('-sim' if target['kind']=='simulator' else '')
        rows=[row for row in rows if Path(row['binary']).name==selected]
        if len(rows)!=1: raise ValueError('Accepted proof must contain exactly one selected core slice: '+selected)
    validate_artifacts(rows)
    # The app phase consumes the top-level framework aliases, rather than proof paths.
    aliases = []
    for row in rows:
        binary = Path(row['binary']); alias = ROOT/'build/xcframework'/binary.parent.name/binary.name
        if not alias.is_file() or file_hash(alias) != row['sha256']:
            raise ValueError('Current core slice alias differs from accepted proof: ' + str(alias))
        aliases.append({'binary':str(alias), 'sha256':row['sha256']})
    value = {'source_commit': commit, 'trees':core_trees(commit), 'artifacts': rows + aliases,
             'policy':'pinned-accepted-engine' if pin_core else 'strict-current-engine', 'scope':scope}
    write_json(STATE/'core-baseline.json', value)
    return value

def validate_baseline(target=None):
    baseline = read_json(STATE/'core-baseline.json')
    if not baseline: raise ValueError('Run prepare --core-baseline ACCEPTED_MANIFEST before fast app builds')
    scope=baseline.get('scope')
    if scope and (target is None or any(scope[key]!=target.get(key) for key in ('platform','kind'))):
        raise ValueError('Accepted core baseline is scoped to '+str(scope)+'; adopt the matching target core before reuse')
    if baseline.get('policy')!='pinned-accepted-engine':
        clean_core()
        if core_trees('HEAD') != baseline['trees']: raise ValueError('Core inputs changed since accepted baseline')
    validate_artifacts(baseline['artifacts'])
    return baseline

def core_policy_report(baseline):
    pinned=baseline.get('policy')=='pinned-accepted-engine'
    report={'policy':baseline.get('policy','strict-current-engine'), 'scope':baseline.get('scope'), 'accepted_source_commit':baseline['source_commit'],
            'freshness':'current-app/pinned-engine' if pinned else 'current-app/current-engine'}
    if pinned:
        report.update({'excluded_from_ui_acceptance':CORE_PATHS,
                       'accepted_core_trees':baseline['trees'], 'current_core_trees':core_trees('HEAD'),
                       'changed_since_accepted':git('diff','--name-only',baseline['source_commit'],'--',*CORE_PATHS).splitlines(),
                       'dirty_or_untracked_core':git('status','--porcelain','--untracked-files=all','--',*CORE_PATHS).splitlines(),
                       'dirty_submodules':git('submodule','foreach','--quiet','--recursive','git status --porcelain --untracked-files=all').splitlines()})
        print('PINNED ACCEPTED ENGINE '+baseline['source_commit']+': UI-only verification; pending core changes are EXCLUDED.')
        print(json.dumps(report,indent=2))
    return report

def applicable_core_policy(run,configured,target,existing_dev,command):
    if configured.get('policy')!='pinned-accepted-engine': return
    if existing_dev and command in ('test','launch'):
        run.metadata['core_policy_applicability']='not validated: --existing-dev disclaims installed app and engine freshness'
    else: record_core_policy(run,validate_baseline(target))

def record_core_policy(run,baseline):
    run.metadata['core_policy']=core_policy_report(baseline)
    run.save()

def source_paths():
    names = git('ls-files', '--cached', '--others', '--exclude-standard', '--', 'Source/iOS/App', 'Data/Sys').splitlines()
    return [ROOT/name for name in names if Path(name).suffix.lower() not in ('.md', '.rst')]

def source_fingerprint():
    digest = hashlib.sha256(digest_paths(source_paths()).encode())
    # PO files are outside Source/iOS, but their contents affect generated app strings.
    digest.update(localization_digest().encode())
    return digest.hexdigest()

def nongenerated_app_fingerprint():
    # Only .strings are expected generator outputs. Swift/ObjC/bridge files,
    # storyboards, XIBs, PO inputs and regeneration scripts must stay stable.
    paths=[path for path in source_paths() if path.suffix!='.strings']
    paths += list((ROOT/'Languages/po').rglob('*'))
    return digest_paths(paths)

def graph_inputs():
    paths = source_paths()
    manifests = [p for p in paths if p.name in ('Project.swift', 'Tuist.swift', 'Package.swift', 'Package.resolved') or p.suffix == '.xcconfig' or 'ProjectDescriptionHelpers' in p.parts]
    digest = hashlib.sha256(digest_paths(manifests).encode())
    # Existing source/resource content edits don't alter the generated file list.
    digest.update('\n'.join(sorted(str(p.relative_to(ROOT)) for p in paths)).encode())
    return digest.hexdigest()

def generated_project_digest():
    paths = [APP/'iCube.xcodeproj/project.pbxproj', APP/'iCube.xcworkspace/contents.xcworkspacedata']
    paths += list((APP/'iCube.xcodeproj/xcshareddata').rglob('*'))
    paths += list((APP/'iCube.xcworkspace/xcshareddata').rglob('*'))
    return digest_paths([p for p in paths if p.is_file()])

def ensure_generated_project(run):
    current = {'inputs': graph_inputs(), 'generated': generated_project_digest()}
    if read_json(STATE/'project-graph.json') != current or not (APP/'iCube.xcodeproj/project.pbxproj').is_file():
        run.command('project-generate', ['tuist', 'generate', '--no-open', '--path', str(APP)])
        if not (APP/'iCube.xcodeproj/project.pbxproj').is_file(): raise ValueError('Tuist did not produce the app project')
        current = {'inputs': graph_inputs(), 'generated': generated_project_digest()}
        write_json(STATE/'project-graph.json', current)
    return current

def localization_digest():
    paths = list((ROOT/'Languages/po').rglob('*'))
    names = git('ls-files', '--cached', '--others', '--exclude-standard', '--', 'Source/iOS/App').splitlines()
    paths += [ROOT/name for name in names if Path(name).suffix in ('.storyboard', '.xib', '.strings')]
    paths += list((APP/'Project/Scripts').glob('*Strings*'))
    return digest_paths(paths)

def validate_suite(suite, target):
    if suite == 'unit':
        if target['platform'] != 'ios': raise ValueError('Unit target supports iOS only')
        return
    platform = SUITES[suite][0]
    if platform not in ('both', target['platform']): raise ValueError('Suite does not support target platform')
    if suite == 'physical-play' and target['kind'] != 'device': raise ValueError('physical-play requires a device')
    if suite == 'portrait' and target['kind'] != 'simulator': raise ValueError('portrait is simulator-only')

def control_guard(target, allowed):
    if target['kind'] == 'device' and not allowed:
        raise ValueError('Physical operations require --allow-device-control; prepare/build need no hardware control')

def destination(target):
    platform = 'iOS' if target['platform'] == 'ios' else 'tvOS'
    return 'platform=' + platform + (' Simulator' if target['kind'] == 'simulator' else '') + ',id=' + target['udid']

def signing_flags(target, team):
    if target['kind'] == 'simulator':
        return ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=']
    if not team: raise ValueError('Device build requires explicit --team DEVELOPMENT_TEAM')
    return ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_STYLE=Automatic', 'DEVELOPMENT_TEAM=' + team]

def derived_path(target):
    suffix = target['platform'] + ('' if target['kind'] == 'simulator' else '-device')
    return APP/('build-Xcode-' + suffix)

def packages_path():
    existing = ROOT/'build/release-audit/2026-10-20-library/packages'
    return existing if existing.is_dir() else STATE/'packages'

def build_flags(target, team):
    # Generic destinations compile without contacting hardware.
    platform = 'iOS' if target['platform'] == 'ios' else 'tvOS'
    if target['kind'] == 'simulator': platform += ' Simulator'
    return ['-configuration', 'Debug (Non-Jailbroken)', '-destination', 'generic/platform=' + platform,
            '-derivedDataPath', str(derived_path(target)), '-clonedSourcePackagesDirPath', str(packages_path()),
            '-onlyUsePackageVersionsFromResolvedFile', '-disableAutomaticPackageResolution',
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', '-jobs', '2', '-showBuildTimingSummary'] + signing_flags(target, team)

def mutate_xctestrun(data, environment):
    result = copy.deepcopy(data)
    def visit(value):
        if isinstance(value, dict):
            # v1 targets have TestBundlePath; v2 targets may expose BlueprintName.
            if 'TestBundlePath' in value or 'BlueprintName' in value or 'EnvironmentVariables' in value:
                value.setdefault('EnvironmentVariables', {}).update(environment)
            for key, child in list(value.items()):
                if key != 'EnvironmentVariables': visit(child)
        elif isinstance(value, list):
            for child in value: visit(child)
    visit(result)
    return result

def test_command(runfile, target, only, result):
    return ['xcodebuild', 'test-without-building', '-xctestrun', str(runfile), '-destination', destination(target),
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES',
            '-maximum-test-execution-time-allowance', '180', '-resultBundlePath', str(result)] + ['-only-testing:' + name for name in only]

def test_result_counts(summary):
    counts={key:int(summary.get(field,0)) for key,field in (('total','totalTestCount'),('passed','passedTests'),('failed','failedTests'),('skipped','skippedTests'))}
    if counts['total']<=0: raise ValueError('XCTest ran zero tests; check --only selection')
    if counts['failed']>0: raise ValueError(f"XCTest reported {counts['failed']} failed tests")
    if counts['passed']==0:
        if counts['skipped']>0: return counts,'skipped'
        raise ValueError('XCTest reported no passing or skipped tests')
    return counts,'passed'

def summarize_test_result(run,result_path):
    log=run.command('test-summary',['xcrun','xcresulttool','get','test-results','summary','--path',str(result_path)])
    summary=json.loads(log.read_text()); write_json(run.path/'summary.json',summary)
    # Save counts before validation so a zero/failing selection remains auditable.
    run.metadata['test_counts']={key:int(summary.get(field,0)) for key,field in (('total','totalTestCount'),('passed','passedTests'),('failed','failedTests'),('skipped','skippedTests'))}
    run.save()
    counts,status=test_result_counts(summary)
    run.metadata['test_counts']=counts; run.metadata['status']=status; run.save()
    print('XCTest '+status+': '+json.dumps(counts))

@contextmanager
def lane_locks(command):
    handles=[]
    try:
        requests=[]
        if command not in ('capture','inspect'): requests.append(('sdk.lock',fcntl.LOCK_EX))
        if command in ('install','launch','test','capture','inspect'):
            requests.append(('ui.lock',fcntl.LOCK_SH if command in ('capture','inspect') else fcntl.LOCK_EX))
        for name,mode in requests:
            handle=(STATE/name).open('a'); handles.append(handle)
            try: fcntl.flock(handle,mode|fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError(f'Local {name} lane is busy; retry after the active operation finishes (nothing queued)')
        yield
    finally:
        for handle in reversed(handles): handle.close()

class Run:
    def __init__(self):
        self.start=time.monotonic()
        self.path = STATE/'runs'/(time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
        self.path.mkdir(parents=True)
        self.metadata = {'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'phases':[]}
        self.save()
    def save(self):
        self.metadata['elapsed_seconds']=round(time.monotonic()-self.start,3)
        write_json(self.path/'timings.json', self.metadata)
    def command(self, name, command, env=None):
        log = self.path/(name + '.log'); start=time.monotonic()
        with log.open('wb') as stream:
            result=subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
        self.metadata['phases'].append({'phase':name,'command':command,'elapsed_seconds':round(time.monotonic()-start,3),'exit_code':result.returncode,'log':str(log)})
        self.save()
        if result.returncode: raise ValueError(f'{name} failed ({result.returncode}); see {log}')
        return log

def app_path(target):
    sdk = ('iphone' if target['platform']=='ios' else 'appletv') + ('simulator' if target['kind']=='simulator' else 'os')
    return derived_path(target)/'Build/Products'/('Debug (Non-Jailbroken)-'+sdk)/'iCube.app'

def tree_fingerprint(path):
    digest = hashlib.sha256()
    for item in sorted(p for p in path.rglob('*') if p.is_file()):
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(file_hash(item).encode())
    return digest.hexdigest()

def app_fingerprint(path):
    info=path/'Info.plist'
    if not info.is_file(): raise ValueError('Missing built DEV app: '+str(path))
    metadata=plistlib.loads(info.read_bytes())
    if metadata.get('CFBundleIdentifier') != DEV_BUNDLE: raise ValueError('Refusing non-DEV app bundle')
    return tree_fingerprint(path)

def products_fingerprint(target):
    return digest_paths([derived_path(target)/'Build/Products'])

def cache_matches(record, signature, artifact):
    return record.get('inputs') == signature and record.get('artifact') == artifact

def build_app(target, team, run):
    baseline=validate_baseline(target); record_core_policy(run,baseline); graph=ensure_generated_project(run); fingerprint=source_fingerprint()
    key=target['platform']+'-'+target['kind']; record_path=STATE/('app-'+key+'.json')
    record=read_json(record_path,{})
    app=app_path(target)
    xcode=gitless_xcode_version()
    signature={'source':fingerprint,'graph':graph,'core':baseline,'xcode':xcode,'developer_dir':os.environ.get('DEVELOPER_DIR'),'team':team,'flags':build_flags(target,team)}
    if app.exists() and cache_matches(record,signature,app_fingerprint(app)) and record.get('products')==products_fingerprint(target):
        print('Reusing verified DEV app: '+str(app)); return record
    previous=read_json(STATE/('localization-'+key+'.json'),{})
    env=dict(os.environ,DOL_SKIP_CORE_BUILD='1',ICUBE_FAST_DEV='1')
    normal=previous.get('digest') != localization_digest()
    env['ICUBE_FAST_DEV_SKIP_LOCALIZATION']='0' if normal else '1'
    stable_inputs=nongenerated_app_fingerprint()
    action='build-for-testing' if target['platform']=='ios' else 'build'
    run.command('app-build',['xcodebuild',action,'-workspace',str(APP/'iCube.xcworkspace'),'-scheme','iCube (NJB)']+build_flags(target,team),env)
    if nongenerated_app_fingerprint()!=stable_inputs:
        raise ValueError('App source/build inputs changed during xcodebuild; rerun build before caching or installing')
    if not normal and source_fingerprint()!=fingerprint:
        raise ValueError('App localization changed during xcodebuild with regeneration disabled; rerun build')
    # A generator introducing new resource paths needs a fresh Tuist graph before acceptance.
    if graph_inputs()!=graph['inputs']:
        raise ValueError('App source/resource membership changed during build; rerun build to regenerate the project graph')
    if normal: write_json(STATE/('localization-'+key+'.json'),{'digest':localization_digest()})
    # Only the normal localization pass may rewrite committed .strings outputs.
    signature['source']=source_fingerprint()
    signature['graph']={'inputs':graph_inputs(),'generated':generated_project_digest()}
    write_json(STATE/'project-graph.json',signature['graph'])
    record={'inputs':signature,'artifact':app_fingerprint(app),'app':str(app),'products':products_fingerprint(target)}
    write_json(record_path,record)
    return record

def gitless_xcode_version():
    return subprocess.check_output(['xcodebuild','-version'],text=True).strip()

def runner_source(suite):
    return Path(__file__).with_name('FastInteractionTests.swift') if suite=='actions' else ROOT/'Tools/release-audit'/SUITES[suite][1]

def runner_sources(suite):
    sources=[runner_source(suite)]
    if suite=='actions': sources.append(Path(__file__).with_name('FastInteractionSchema.swift'))
    for source in sources:
        if not source.is_file(): raise ValueError('Missing UI suite source '+str(source))
    return sources

def runner_spec(target):
    platform='iOS' if target['platform']=='ios' else 'tvOS'
    return {'name':'ICubeFastUI','settings':{'GENERATE_INFOPLIST_FILE':'YES','PRODUCT_BUNDLE_IDENTIFIER':'com.joemattiello.audit.fast-ui'},'targets':{'ICubeFastUI':{'type':'bundle.ui-testing','platform':platform,'deploymentTarget':'17.0','sources':['Tests']}},'schemes':{'ICubeFastUI':{'build':{'targets':{'ICubeFastUI':['test']}},'test':{'targets':['ICubeFastUI']}}}}

def runner_identity(target,suite,team):
    sources=runner_sources(suite); sdk=sdk_name(target)
    inputs={'sources':{source.name:file_hash(source) for source in sources}, 'xcode':gitless_xcode_version(),
            'developer_dir':os.environ.get('DEVELOPER_DIR'), 'platform':target['platform'],'kind':target['kind'],
            'sdk':sdk,'sdk_version':sdk_version(sdk),'sdk_path':sdk_path(sdk),
            'spec':runner_spec(target),'signing':signing_flags(target,team),
            'build_flags':['build-for-testing','-jobs','2']}
    key=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()[:20]
    return key,inputs

def prepare_runner(target,suite,team,run):
    validate_suite(suite,target)
    if suite=='unit':
        build_app(target,team,run)
        return find_runfile(derived_path(target)/'Build/Products',target)
    key,inputs=runner_identity(target,suite,team)
    folder=STATE/'runners'/key; record=read_json(folder/'runner.json',{})
    if record and Path(record['xctestrun']).exists() and record.get('artifact')==digest_paths([folder/'derived/Build/Products']):
        return Path(record['xctestrun'])
    folder.mkdir(parents=True,exist_ok=True); (folder/'Tests').mkdir(exist_ok=True)
    for source in runner_sources(suite): shutil.copy2(source,folder/'Tests'/source.name)
    spec=runner_spec(target); platform='iOS' if target['platform']=='ios' else 'tvOS'
    write_json(folder/'project.json',spec)
    run.command('harness-generate',['xcodegen','generate','--spec',str(folder/'project.json'),'--project',str(folder)])
    generic='generic/platform='+platform+(' Simulator' if target['kind']=='simulator' else '')
    run.command('harness-build',['xcodebuild','build-for-testing','-project',str(folder/'ICubeFastUI.xcodeproj'),'-scheme','ICubeFastUI','-destination',generic,'-derivedDataPath',str(folder/'derived'),'-jobs','2']+signing_flags(target,team))
    runfile=find_runfile(folder/'derived/Build/Products',target)
    write_json(folder/'runner.json',{'xctestrun':str(runfile),'artifact':digest_paths([folder/'derived/Build/Products']),'inputs':inputs})
    return runfile

def sdk_name(target):
    return ('iphone' if target['platform']=='ios' else 'appletv') + ('simulator' if target['kind']=='simulator' else 'os')

@lru_cache(maxsize=4)
def sdk_version(sdk):
    return subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version'],text=True).strip()

@lru_cache(maxsize=4)
def sdk_path(sdk):
    return subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()

def find_runfile(products,target):
    sdk=sdk_name(target); version=sdk_version(sdk)
    pattern=re.compile(re.escape(sdk+version)+r'(?:-|\.xctestrun$)')
    paths=[path for path in products.glob('*.xctestrun') if pattern.search(path.name)]
    if len(paths)!=1: raise ValueError(f'Expected exactly one {sdk} {version} .xctestrun in {products}; run prepare first')
    return paths[0]


def current_install(target,existing):
    record=read_json(STATE/'installs'/(target['udid']+'.json'),{})
    if existing:
        print('Using explicit --existing-dev; installed binary freshness is unverified')
        return {'freshness':'unverified-existing-dev'}
    if target['kind']=='device':
        raise ValueError('Physical installed-content verification is unavailable; use explicit --existing-dev to record unverified device freshness')
    baseline=validate_baseline(target)
    if record.get('source')!=source_fingerprint() or record.get('core')!=baseline:
        raise ValueError('No verified current DEV install for target. Build/install first, or explicitly pass --existing-dev')
    app=Path(record['app'])
    if record.get('artifact')!=app_fingerprint(app): raise ValueError('Installed build record no longer matches local artifact; install again')
    actual=subprocess.check_output(['xcrun','simctl','get_app_container',target['udid'],DEV_BUNDLE,'app'],text=True).strip()
    installed=Path(actual)
    if not actual or app_fingerprint(installed)!=record['artifact']:
        raise ValueError('Installed simulator DEV app differs from recorded build; install again or explicitly use --existing-dev')
    return dict(record, freshness='current-app/pinned-engine' if baseline.get('policy')=='pinned-accepted-engine' else 'verified-installed-content')

def check_rocketsim(envelope):
    if envelope.get('rs') != '1': raise ValueError('RocketSim did not return rs/1')
    if envelope.get('ok') is not True:
        error=envelope.get('error',{}); context=envelope.get('context',{})
        raise ValueError('RocketSim '+str(error.get('code'))+': '+str(error.get('message',''))+' '+str(error.get('recovery_suggestion',''))+' '+str(context))
    return envelope.get('data',{})

def rocketsim_path():
    candidates=[shutil.which('rocketsim'),'/opt/homebrew/bin/rocketsim','/usr/local/bin/rocketsim',str(Path.home()/'.local/bin/rocketsim'),'/Applications/RocketSim.app/Contents/Resources/CLI/rocketsim',str(Path.home()/'Applications/RocketSim.app/Contents/Resources/CLI/rocketsim')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate,os.X_OK):
            path=Path(candidate).resolve()
            if str(path).endswith('Contents/Helpers/rocketsim'): path=path.parent.parent/'Resources/CLI/rocketsim'
            if os.access(path,os.X_OK): return str(path)
    raise ValueError('RocketSim CLI unavailable. Install via RocketSim Settings → CLI & Agent.')

def rocket_json(run, name, command):
    log = run.path/(name + '.log'); start = time.monotonic()
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    log.write_bytes(result.stdout)
    (run.path/(name + '-stderr.log')).write_bytes(result.stderr)
    run.metadata['phases'].append({'phase':name, 'command':command, 'elapsed_seconds':round(time.monotonic()-start,3), 'exit_code':result.returncode, 'log':str(log)})
    run.save()
    # rs/1 error details must remain visible even when CLI exits nonzero.
    parsed = False
    for raw in (result.stdout, result.stderr):
        if raw.lstrip().startswith(b'{'):
            parsed = True
            check_rocketsim(json.loads(raw))
    if result.returncode or not parsed:
        raise ValueError('RocketSim failed; see ' + str(log))
    return log

def rocket_capture(target,run,capture):
    if target['kind']!='simulator': raise ValueError('RocketSim capture/inspect supports registered simulators only')
    cli=rocketsim_path()
    log=rocket_json(run,'screen',[cli,'screen','--udid',target['udid']])
    envelope=json.loads(log.read_text()); check_rocketsim(envelope)
    preview=envelope.get('context',{}).get('preview_url')
    if not preview:
        log=rocket_json(run,'preview',[cli,'preview','--udid',target['udid']]); env=json.loads(log.read_text()); data=check_rocketsim(env); preview=data.get('url')
    if preview: print('Live preview: '+preview)
    # Stop on any rs/1 error, including quota_exceeded. Never fall back to simctl capture.
    log=rocket_json(run,'accessibility',[cli,'elements','--agent','--agent-mode','nav','--udid',target['udid']])
    ax=json.loads(log.read_text()); check_rocketsim(ax); write_json(run.path/'accessibility.json',ax)
    if capture:
        start=time.monotonic(); cmd=[cli,'screenshot','--udid',target['udid']]
        result=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        run.metadata['phases'].append({'phase':'screenshot','command':cmd,'elapsed_seconds':round(time.monotonic()-start,3),'exit_code':result.returncode}); run.save()
        # Raw captures carry rs/1 errors on stderr rather than stdout.
        for raw in (result.stderr,result.stdout):
            if raw.lstrip().startswith(b'{'):
                check_rocketsim(json.loads(raw))
        if result.returncode or not result.stdout.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError('RocketSim capture failed: '+result.stderr.decode(errors='replace'))
        (run.path/'screen.png').write_bytes(result.stdout)
    run.metadata['preview_url']=preview; run.save()

def parser():
    p=argparse.ArgumentParser(description=__doc__); sub=p.add_subparsers(dest='command',required=True)
    targets=sub.add_parser('target').add_subparsers(dest='target_action',required=True)
    add=targets.add_parser('add'); add.add_argument('name'); add.add_argument('--udid',required=True); add.add_argument('--platform',choices=['ios','tvos'],required=True); add.add_argument('--kind',choices=['simulator','device'],required=True)
    targets.add_parser('list')
    for name in ('prepare','build','install','launch','test','capture','inspect'):
        q=sub.add_parser(name); q.add_argument('--target'); q.add_argument('--team'); q.add_argument('--allow-device-control',action='store_true'); q.add_argument('--existing-dev',action='store_true')
        if name in ('prepare','test'): q.add_argument('--suite',choices=['unit']+list(SUITES),default='unit' if name=='test' else None)
        if name=='prepare':
            q.add_argument('--core-baseline',type=Path); q.add_argument('--pin-core',action='store_true',help='Explicit UI-only reuse of an accepted engine while core source work differs')
        if name=='test':
            group=q.add_mutually_exclusive_group(required=True); group.add_argument('--only',action='append'); group.add_argument('--all',action='store_true'); q.add_argument('--actions'); q.add_argument('--env',action='append',default=[],metavar='KEY=VALUE')
    return p

def main(argv=None):
    args=parser().parse_args(argv); STATE.mkdir(parents=True,exist_ok=True)
    registry_path=STATE/'targets.json'; registry=read_json(registry_path,{})
    if args.command=='target':
        if args.target_action=='add':
            if not args.udid or any(x in args.udid for x in '/\\\n'): raise ValueError('Invalid explicit UDID')
            registry[args.name]={'udid':args.udid,'platform':args.platform,'kind':args.kind}; write_json(registry_path,registry)
        print(json.dumps(registry,indent=2)); return
    # Capture can inspect during compilation, but cannot overlap UI test/control mutations.
    with lane_locks(args.command):
        run=Run()
        try:
            if args.command=='prepare' and args.pin_core and not args.core_baseline: raise ValueError('--pin-core requires --core-baseline ACCEPTED_MANIFEST')
            if args.command=='prepare' and args.core_baseline:
                if args.target and args.target not in registry: raise ValueError('Register the selected baseline target first')
                baseline=adopt_baseline(args.core_baseline.resolve(),args.pin_core,registry.get(args.target))
                record_core_policy(run,baseline)
                print('Accepted core baseline recorded')
                if not args.target or args.suite is None:
                    run.metadata['status']='passed'; return
            if args.target not in registry: raise ValueError('Register/select an explicit target with target add and --target')
            target=registry[args.target]; run.metadata['target']=target
            if args.command not in ('prepare','build'): control_guard(target,args.allow_device_control)
            if args.command in ('install','test','launch'):
                configured=read_json(STATE/'core-baseline.json',{})
                applicable_core_policy(run,configured,target,args.existing_dev,args.command)
            if args.command=='prepare': prepare_runner(target,args.suite or 'unit',args.team,run)
            elif args.command=='build': build_app(target,args.team,run)
            elif args.command=='install':
                record=read_json(STATE/('app-'+target['platform']+'-'+target['kind']+'.json'),{})
                baseline=validate_baseline(target); app=app_path(target)
                if record.get('inputs',{}).get('source')!=source_fingerprint() or record.get('inputs',{}).get('core')!=baseline or record.get('artifact')!=app_fingerprint(app) or record.get('inputs',{}).get('graph')!={'inputs':graph_inputs(),'generated':generated_project_digest()}: raise ValueError('Build current DEV app before install')
                if target['kind']=='simulator': command=['xcrun','simctl','install',target['udid'],str(app)]
                else: command=['xcrun','devicectl','device','install','app','--device',target['udid'],str(app)]
                run.command('install',command)
                write_json(STATE/'installs'/(target['udid']+'.json'),{'source':source_fingerprint(),'core':baseline,'artifact':record['artifact'],'app':str(app)})
            elif args.command=='launch':
                run.metadata['install']=current_install(target,args.existing_dev)
                command=['xcrun','simctl','launch',target['udid'],DEV_BUNDLE] if target['kind']=='simulator' else ['xcrun','devicectl','device','process','launch','--device',target['udid'],DEV_BUNDLE]
                run.command('launch',command)
            elif args.command=='test':
                validate_suite(args.suite,target); run.metadata['install']=current_install(target,args.existing_dev)
                if args.suite=='unit':
                    app_record=read_json(STATE/('app-'+target['platform']+'-'+target['kind']+'.json'),{})
                    if app_record.get('inputs',{}).get('source')!=source_fingerprint() or app_record.get('products')!=products_fingerprint(target): raise ValueError('Prepare current unit products before testing')
                    runfile=find_runfile(derived_path(target)/'Build/Products',target); test_target='iCubeTests'
                else:
                    key,_=runner_identity(target,args.suite,args.team)
                    folder=STATE/'runners'/key; record=read_json(folder/'runner.json',{})
                    if not record or record.get('artifact')!=digest_paths([folder/'derived/Build/Products']): raise ValueError('Prepare this suite first; cached runner missing or changed')
                    runfile=Path(record['xctestrun']); test_target='ICubeFastUI'
                env={}
                for entry in args.env:
                    key,separator,value=entry.partition('=')
                    if not separator or not key.startswith('ICUBE_'): raise ValueError('--env permits explicit ICUBE_* test preflights only')
                    env[key]=value
                if args.actions:
                    if args.suite!='actions': raise ValueError('--actions requires --suite actions')
                    raw=args.actions
                    if not raw.lstrip().startswith(('[','{')): raw=Path(raw).read_text()
                    actions=json.loads(raw)
                    if not isinstance(actions,list) or not all(isinstance(action,dict) for action in actions): raise ValueError('Actions JSON must be an array of dictionaries')
                    env['ICUBE_UI_ACTIONS']=raw
                if args.suite=='actions' and 'ICUBE_UI_ACTIONS' not in env: raise ValueError('actions suite requires --actions JSON or file')
                if target['kind']=='device': env['ICUBE_ALLOW_DEVICE_CONTROL']='1'
                # Keep copied runfile alongside original so __TESTROOT__ paths remain valid.
                copied=runfile.with_name('fast-'+run.path.name+'.xctestrun')
                with runfile.open('rb') as stream: data=plistlib.load(stream)
                with copied.open('wb') as stream: plistlib.dump(mutate_xctestrun(data,env),stream)
                only=[test_target+'/'+name if not name.startswith(test_target+'/') else name for name in (args.only or [])]
                try:
                    run.command('test',test_command(copied,target,only,run.path/'result.xcresult'))
                    summarize_test_result(run,run.path/'result.xcresult')
                finally: copied.unlink(missing_ok=True)
            else: rocket_capture(target,run,args.command=='capture')
            run.metadata.setdefault('status','passed')
        except Exception as error:
            run.metadata['status']='failed'; run.metadata['error']=str(error); raise
        finally:
            run.save(); print('Run evidence: '+str(run.path))

if __name__=='__main__':
    try: main()
    except (ValueError, subprocess.CalledProcessError, FileNotFoundError, KeyError) as error:
        print('error: '+str(error),file=sys.stderr); sys.exit(1)
