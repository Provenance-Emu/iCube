import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

MODULE = pathlib.Path(__file__).with_name('icube.py')
spec = importlib.util.spec_from_file_location('icube', MODULE)
icube = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icube)

class FastLoopTests(unittest.TestCase):
    def test_platform_and_hardware_guards(self):
        target = {'platform': 'tvos', 'kind': 'device', 'udid': 'test'}
        with self.assertRaises(ValueError): icube.validate_suite('portrait', target)
        with self.assertRaises(ValueError): icube.control_guard(target, False)
        icube.control_guard(target, True)

    def test_xctestrun_mutation_is_recursive_and_does_not_change_original(self):
        data = {'TestConfigurations': [{'TestTargets': [{'EnvironmentVariables': {'KEEP': 'yes'}}]}]}
        changed = icube.mutate_xctestrun(data, {'ICUBE_UI_ACTIONS': '[]'})
        self.assertEqual(changed['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables'], {'KEEP': 'yes', 'ICUBE_UI_ACTIONS': '[]'})
        self.assertNotIn('ICUBE_UI_ACTIONS', data['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables'])

    def test_signing_and_direct_runner(self):
        target = {'platform': 'ios', 'kind': 'simulator', 'udid': 'test'}
        flags = icube.signing_flags(target, None)
        self.assertIn('CODE_SIGNING_ALLOWED=YES', flags)
        self.assertNotIn('CODE_SIGNING_ALLOWED=NO', flags)
        cmd = icube.test_command(pathlib.Path('/tmp/cached.xctestrun'), target, ['iCubeTests/Foo/testBar'], pathlib.Path('/tmp/result'))
        self.assertIn('-xctestrun', cmd)
        self.assertNotIn('-workspace', cmd)
        self.assertIn('test-without-building', cmd)

    def test_fingerprint_detects_content_change(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'input'; path.write_text('one')
            first = icube.digest_paths([path]); path.write_text('two')
            self.assertNotEqual(first, icube.digest_paths([path]))

    def test_core_hash_rejects_changed_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)/'core'; path.write_text('core')
            rows = [{'binary': str(path), 'sha256': icube.file_hash(path)}]
            icube.validate_artifacts(rows)
            path.write_text('stale')
            with self.assertRaises(ValueError): icube.validate_artifacts(rows)

    def test_core_tree_or_dirty_state_invalidates_baseline(self):
        baseline = {'trees': 'accepted', 'artifacts': [{'binary':'unused','sha256':'hash'}]}
        with patch.object(icube, 'read_json', return_value=baseline), patch.object(icube, 'clean_core'), patch.object(icube, 'core_trees', return_value='changed'), patch.object(icube, 'validate_artifacts') as artifacts:
            with self.assertRaisesRegex(ValueError, 'Core inputs changed'): icube.validate_baseline()
            artifacts.assert_not_called()
        with patch.object(icube, 'read_json', return_value=baseline), patch.object(icube, 'clean_core', side_effect=ValueError('dirty')):
            with self.assertRaisesRegex(ValueError, 'dirty'): icube.validate_baseline()

    def test_po_edit_invalidates_app_source_but_tooling_edits_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); app=root/'Source/iOS/App'; app.mkdir(parents=True)
            swift=app/'View.swift'; swift.write_text('view')
            po=root/'Languages/po/en.po'; po.parent.mkdir(parents=True); po.write_text('first')
            tool=root/'Tools/dev-loop/README.md'; tool.parent.mkdir(parents=True); tool.write_text('first')
            def files(*args): return 'Source/iOS/App/View.swift'
            with patch.object(icube,'ROOT',root), patch.object(icube,'APP',app), patch.object(icube,'git',side_effect=files):
                before=icube.source_fingerprint(); tool.write_text('second')
                self.assertEqual(before,icube.source_fingerprint())
                po.write_text('second'); self.assertNotEqual(before,icube.source_fingerprint())

    def test_active_sdk_selects_matching_runfile_from_mixed_products(self):
        with tempfile.TemporaryDirectory() as directory:
            products=pathlib.Path(directory)
            old=products/'iCube (NJB)_iphonesimulator26.5-arm64.xctestrun'; old.touch()
            current=products/'iCube (NJB)_iphonesimulator27.1-arm64.xctestrun'; current.touch()
            target={'platform':'ios','kind':'simulator'}
            with patch.object(icube,'sdk_version',return_value='27.1'):
                self.assertEqual(icube.find_runfile(products,target),current)
                (products/'duplicate_iphonesimulator27.1-arm64.xctestrun').touch()
                with self.assertRaisesRegex(ValueError,'exactly one'): icube.find_runfile(products,target)

    def test_graph_changes_for_manifest_or_membership_but_not_swift_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); swift=root/'View.swift'; manifest=root/'Project.swift'
            swift.write_text('first'); manifest.write_text('manifest')
            paths=[swift,manifest]
            with patch.object(icube,'ROOT',root), patch.object(icube,'source_paths',return_value=paths):
                before=icube.graph_inputs(); swift.write_text('second')
                self.assertEqual(before,icube.graph_inputs())
                manifest.write_text('new manifest'); self.assertNotEqual(before,icube.graph_inputs())
                before=icube.graph_inputs(); paths.append(root/'Added.swift')
                self.assertNotEqual(before,icube.graph_inputs())

    def test_normalized_app_hash_compares_different_install_locations(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); a=root/'build'; b=root/'installed'; a.mkdir(); b.mkdir()
            for folder in (a,b):
                (folder/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':icube.DEV_BUNDLE}))
                (folder/'iCube').write_bytes(b'accepted')
            self.assertEqual(icube.app_fingerprint(a),icube.app_fingerprint(b))
            (b/'iCube').write_bytes(b'overwritten')
            self.assertNotEqual(icube.app_fingerprint(a),icube.app_fingerprint(b))

    def test_installed_simulator_overwrite_is_rejected(self):
        target={'kind':'simulator','platform':'ios','udid':'test'}
        record={'source':'source','core':{'accepted':True},'artifact':'accepted','app':'/build/app'}
        with patch.object(icube,'read_json',return_value=record), patch.object(icube,'source_fingerprint',return_value='source'), patch.object(icube,'validate_baseline',return_value={'accepted':True}), patch.object(icube,'app_fingerprint',side_effect=['accepted','overwritten']), patch.object(icube.subprocess,'check_output',return_value='/installed/app'):
            with self.assertRaisesRegex(ValueError,'Installed simulator DEV app differs'): icube.current_install(target,False)

    def test_physical_freshness_requires_explicit_unverified_install(self):
        with patch.object(icube,'read_json',return_value={}), patch.object(icube.subprocess,'check_output') as command:
            with self.assertRaisesRegex(ValueError,'installed-content verification'): icube.current_install({'kind':'device','udid':'device'},False)
            result=icube.current_install({'kind':'device','udid':'device'},True)
            self.assertEqual(result['freshness'],'unverified-existing-dev'); command.assert_not_called()

    def test_actions_runner_key_includes_schema_sdk_spec_and_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); source=root/'FastInteractionTests.swift'; schema=root/'FastInteractionSchema.swift'
            source.write_text('test'); schema.write_text('schema one')
            target={'kind':'simulator','platform':'ios'}
            with patch.object(icube,'runner_sources',return_value=[source,schema]), patch.object(icube,'gitless_xcode_version',return_value='Xcode test'), patch.object(icube,'sdk_version',return_value='27.1'), patch.object(icube,'sdk_path',return_value='/SDK/one'):
                key,inputs=icube.runner_identity(target,'actions',None)
                self.assertEqual(set(inputs['sources']),{'FastInteractionTests.swift','FastInteractionSchema.swift'})
                schema.write_text('schema two'); self.assertNotEqual(key,icube.runner_identity(target,'actions',None)[0])
                key=icube.runner_identity(target,'actions',None)[0]
                with patch.object(icube,'sdk_path',return_value='/SDK/two'):
                    self.assertNotEqual(key,icube.runner_identity(target,'actions',None)[0])
                with patch.object(icube,'runner_spec',return_value={'changed':'spec'}):
                    self.assertNotEqual(key,icube.runner_identity(target,'actions',None)[0])
                with patch.object(icube,'signing_flags',return_value=['changed-signing']):
                    self.assertNotEqual(key,icube.runner_identity(target,'actions',None)[0])

    def test_pin_core_is_explicit_preserves_provenance_and_still_checks_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); state=root/'state'; manifest=root/'candidate.json'
            binary=root/'proof/PVlibDolphin-ios.framework/PVlibDolphin-ios'; binary.parent.mkdir(parents=True); binary.write_bytes(b'accepted')
            alias=root/'build/xcframework'/binary.parent.name/binary.name; alias.parent.mkdir(parents=True); alias.write_bytes(b'accepted')
            stage={'status':'passed','source_commit':'accepted','build_number':'1'}
            manifest.write_text(__import__('json').dumps({'source_commit':'accepted','build_number':'1','platforms':{platform:{'validation':stage,'ipa_validation':stage} for platform in ('ios','tvos')}}))
            (root/'1-ios-package-core.json').write_text(__import__('json').dumps({'result':'passed','artifacts':[{'binary':str(binary),'sha256':icube.file_hash(binary)}]}))
            with patch.object(icube,'ROOT',root), patch.object(icube,'STATE',state), patch.object(icube,'core_trees',return_value='accepted-tree'), patch.object(icube,'clean_core',side_effect=ValueError('dirty')) as clean:
                with self.assertRaisesRegex(ValueError,'dirty'): icube.adopt_baseline(manifest)
                clean.reset_mock()
                baseline=icube.adopt_baseline(manifest,pin_core=True)
                clean.assert_not_called()
                self.assertEqual(baseline['policy'],'pinned-accepted-engine')
                self.assertEqual(baseline['source_commit'],'accepted')
                self.assertEqual(baseline['trees'],'accepted-tree')
                icube.validate_baseline(); clean.assert_not_called()
                alias.write_bytes(b'changed by another build')
                with self.assertRaisesRegex(ValueError,'Core artifact changed'): icube.validate_baseline()

    def test_pin_report_names_excluded_pending_core_work(self):
        baseline={'policy':'pinned-accepted-engine','source_commit':'accepted','trees':'old'}
        with patch.object(icube,'core_trees',return_value='new'), patch.object(icube,'git',side_effect=['Source/Core/Changed.cpp',' M Source/iOS/Library/Host.mm','']):
            report=icube.core_policy_report(baseline)
        self.assertEqual(report['freshness'],'current-app/pinned-engine')
        self.assertEqual(report['changed_since_accepted'],['Source/Core/Changed.cpp'])
        self.assertIn('Source/iOS/Library',report['excluded_from_ui_acceptance'])

    def test_pin_policy_changes_cache_identity(self):
        record={'inputs':{'core':{'policy':'strict-current-engine'}},'artifact':'app'}
        self.assertFalse(icube.cache_matches(record,{'core':{'policy':'pinned-accepted-engine'}},'app'))

    def test_app_source_paths_exclude_engine_library(self):
        with patch.object(icube,'git',return_value='Source/iOS/App/View.swift') as query:
            icube.source_paths()
        self.assertIn('Source/iOS/App',query.call_args.args)
        self.assertNotIn('Source/iOS',query.call_args.args)
        self.assertNotIn('Source/iOS/Library',query.call_args.args)

    def test_xctest_counts_reject_zero_and_failed_and_label_all_skips(self):
        with self.assertRaisesRegex(ValueError,'zero tests'): icube.test_result_counts({'totalTestCount':0})
        with self.assertRaisesRegex(ValueError,'failed tests'): icube.test_result_counts({'totalTestCount':2,'passedTests':1,'failedTests':1})
        counts,status=icube.test_result_counts({'totalTestCount':2,'skippedTests':2})
        self.assertEqual(status,'skipped'); self.assertEqual(counts['passed'],0)
        counts,status=icube.test_result_counts({'totalTestCount':3,'passedTests':2,'skippedTests':1})
        self.assertEqual(status,'passed'); self.assertEqual(counts,{'total':3,'passed':2,'failed':0,'skipped':1})

    def test_test_summary_is_saved_and_skips_are_never_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); log=root/'summary.log'
            log.write_text('{"totalTestCount":1,"passedTests":0,"skippedTests":1}')
            run=type('FakeRun',(),{'path':root,'metadata':{},'save':lambda self:None,'command':lambda self,*args:log})()
            icube.summarize_test_result(run,root/'result.xcresult')
            self.assertEqual(run.metadata['status'],'skipped')
            self.assertTrue((root/'summary.json').is_file())

    def test_busy_lock_fails_without_hidden_wait(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(icube,'STATE',pathlib.Path(directory)), patch.object(icube.fcntl,'flock',side_effect=BlockingIOError) as lock:
            with self.assertRaisesRegex(ValueError,'lane is busy'):
                with icube.lane_locks('build'): self.fail('busy lane yielded')
            self.assertTrue(lock.call_args.args[1]&icube.fcntl.LOCK_NB)

    def test_capture_uses_ui_read_lock_without_waiting_on_sdk(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(icube,'STATE',pathlib.Path(directory)), patch.object(icube.fcntl,'flock') as lock:
            with icube.lane_locks('capture'): pass
            self.assertEqual(lock.call_count,1)
            self.assertEqual(pathlib.Path(lock.call_args.args[0].name).name,'ui.lock')
            self.assertEqual(lock.call_args.args[1],icube.fcntl.LOCK_SH|icube.fcntl.LOCK_NB)

    def test_scoped_baseline_rejects_wrong_platform_or_kind(self):
        baseline={'source_commit':'accepted','policy':'pinned-accepted-engine','scope':{'platform':'tvos','kind':'simulator'},'artifacts':[{'binary':'unused'}]}
        with patch.object(icube,'read_json',return_value=baseline), patch.object(icube,'validate_artifacts') as artifacts:
            with self.assertRaisesRegex(ValueError,'scoped to'): icube.validate_baseline({'platform':'ios','kind':'simulator'})
            with self.assertRaisesRegex(ValueError,'scoped to'): icube.validate_baseline({'platform':'tvos','kind':'device'})
            artifacts.assert_not_called()
            icube.validate_baseline({'platform':'tvos','kind':'simulator'}); artifacts.assert_called_once()

    def test_target_scoped_adoption_ignores_other_slice_but_rejects_selected_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); state=root/'state'; manifest=root/'candidate.json'
            rows=[]
            for name in ('PVlibDolphin-ios-sim','PVlibDolphin-tvos-sim'):
                binary=root/'proof'/(name+'.framework')/name; binary.parent.mkdir(parents=True); binary.write_bytes(b'accepted')
                alias=root/'build/xcframework'/binary.parent.name/name; alias.parent.mkdir(parents=True); alias.write_bytes(b'accepted')
                rows.append({'binary':str(binary),'sha256':icube.file_hash(binary)})
            pathlib.Path(rows[0]['binary']).write_bytes(b'unrelated engine work rebuilt ios')
            stage={'status':'passed','source_commit':'accepted','build_number':'1'}
            manifest.write_text(__import__('json').dumps({'source_commit':'accepted','build_number':'1','platforms':{platform:{'validation':stage,'ipa_validation':stage} for platform in ('ios','tvos')}}))
            (root/'1-ios-package-core.json').write_text(__import__('json').dumps({'result':'passed','artifacts':rows}))
            target={'platform':'tvos','kind':'simulator'}
            with patch.object(icube,'ROOT',root), patch.object(icube,'STATE',state), patch.object(icube,'core_trees',return_value='accepted-tree'):
                with self.assertRaisesRegex(ValueError,'Core artifact changed'): icube.adopt_baseline(manifest,pin_core=True)
                baseline=icube.adopt_baseline(manifest,pin_core=True,target=target)
                self.assertEqual(baseline['scope'],target)
                self.assertTrue(all('tvos-sim' in item['binary'] for item in baseline['artifacts']))
                icube.validate_baseline(target)
                pathlib.Path(rows[1]['binary']).write_bytes(b'selected changed')
                with self.assertRaisesRegex(ValueError,'Core artifact changed'): icube.validate_baseline(target)

    def test_existing_dev_disclaims_unrelated_pin_without_validating_scope(self):
        configured={'policy':'pinned-accepted-engine','scope':{'platform':'tvos','kind':'simulator'}}
        target={'platform':'ios','kind':'simulator'}
        run=type('FakeRun',(),{'metadata':{}})()
        with patch.object(icube,'validate_baseline',side_effect=ValueError('scope mismatch')) as validate:
            icube.applicable_core_policy(run,configured,target,True,'test')
            validate.assert_not_called()
            self.assertNotIn('core_policy',run.metadata)
            self.assertIn('not validated',run.metadata['core_policy_applicability'])
            with self.assertRaisesRegex(ValueError,'scope mismatch'):
                icube.applicable_core_policy(run,configured,target,False,'test')
            validate.assert_called_once_with(target)

    def test_build_rejects_concurrent_swift_or_bridge_edits_without_cache_write(self):
        for suffix in ('.swift','.m','.mm'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root=pathlib.Path(directory); source=root/('View'+suffix); source.write_text('before')
                graph={'inputs':'graph','generated':'generated'}
                run=type('FakeRun',(),{'command':lambda self,*args:source.write_text('concurrent edit')})()
                with patch.object(icube,'ROOT',root), patch.object(icube,'STATE',root/'state'), patch.object(icube,'source_paths',return_value=[source]), patch.object(icube,'localization_digest',return_value='localization'), patch.object(icube,'validate_baseline',return_value={}), patch.object(icube,'record_core_policy'), patch.object(icube,'ensure_generated_project',return_value=graph), patch.object(icube,'gitless_xcode_version',return_value='Xcode'), patch.object(icube,'build_flags',return_value=[]), patch.object(icube,'app_path',return_value=root/'missing.app'), patch.object(icube,'write_json') as write:
                    with self.assertRaisesRegex(ValueError,'changed during xcodebuild'):
                        icube.build_app({'platform':'ios','kind':'simulator'},None,run)
                    write.assert_not_called()

    def test_nongenerated_fingerprint_allows_strings_but_detects_po_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); strings=root/'Localizable.strings'; strings.write_text('before')
            po=root/'Languages/po/en.po'; po.parent.mkdir(parents=True); po.write_text('before')
            with patch.object(icube,'ROOT',root), patch.object(icube,'source_paths',return_value=[strings]):
                before=icube.nongenerated_app_fingerprint(); strings.write_text('generated translation')
                self.assertEqual(before,icube.nongenerated_app_fingerprint())
                po.write_text('concurrent PO edit'); self.assertNotEqual(before,icube.nongenerated_app_fingerprint())

    def test_empty_phase_cache_run_still_records_total_elapsed(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(icube,'STATE',pathlib.Path(directory)), patch.object(icube.time,'monotonic',side_effect=[10.0,10.25,10.75]):
            run=icube.Run(); run.save()
            self.assertEqual(run.metadata['phases'],[])
            self.assertEqual(run.metadata['elapsed_seconds'],0.75)

    def test_candidate_adoption_rejects_partial_or_mismatched_acceptance(self):
        manifest = {'source_commit':'accepted', 'build_number':'1', 'platforms':{}}
        passed = {'status':'passed','source_commit':'accepted','build_number':'1'}
        for platform in ('ios','tvos'):
            manifest['platforms'][platform] = {'validation':dict(passed),'ipa_validation':dict(passed)}
        manifest['platforms']['tvos']['ipa_validation']['source_commit']='different'
        with patch.object(icube, 'read_json', return_value=manifest), patch.object(icube,'clean_core') as clean:
            with self.assertRaisesRegex(ValueError,'matching passed'): icube.adopt_baseline(pathlib.Path('/tmp/candidate.json'))
            clean.assert_not_called()

    def test_capture_stops_on_quota_before_screenshot(self):
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory)/'screen.log'
            log.write_text('{"rs":"1","ok":false,"error":{"code":"quota_exceeded"}}')
            run = type('FakeRun', (), {'path':pathlib.Path(directory)})()
            with patch.object(icube,'rocketsim_path',return_value='rocketsim'), patch.object(icube,'rocket_json',return_value=log) as command, patch.object(icube.subprocess,'run') as process:
                with self.assertRaisesRegex(ValueError,'quota_exceeded'):
                    icube.rocket_capture({'kind':'simulator','udid':'test'},run,True)
                self.assertEqual(command.call_count,1)
                process.assert_not_called()

    def test_build_flags_never_resolve_or_contact_device(self):
        target = {'platform':'tvos','kind':'device','udid':'physical'}
        flags = icube.build_flags(target, 'TEAM')
        self.assertIn('generic/platform=tvOS', flags)
        self.assertIn('Debug (Non-Jailbroken)', flags)
        self.assertIn('-disableAutomaticPackageResolution', flags)
        self.assertNotIn('-disablePackageRepositoryCache', flags)
        self.assertNotIn('-allowProvisioningUpdates', flags)
        self.assertNotIn('physical', ' '.join(flags))
        with self.assertRaises(ValueError): icube.signing_flags(target, None)

    def test_cache_requires_both_inputs_and_artifact(self):
        record = {'inputs':{'source':'one'}, 'artifact':'binary-one'}
        self.assertTrue(icube.cache_matches(record, {'source':'one'}, 'binary-one'))
        self.assertFalse(icube.cache_matches(record, {'source':'two'}, 'binary-one'))
        self.assertFalse(icube.cache_matches(record, {'source':'one'}, 'binary-two'))

    def test_v1_runfile_env_and_relative_paths_preserved(self):
        original = {'Suite': {'TestBundlePath':'__TESTROOT__/Runner.xctest', 'TestHostPath':'__TESTROOT__/Runner.app', 'EnvironmentVariables':{'KEEP':'yes'}}}
        changed = icube.mutate_xctestrun(original, {'ICUBE_ALLOW_DEVICE_CONTROL':'1'})
        self.assertEqual(changed['Suite']['TestBundlePath'], original['Suite']['TestBundlePath'])
        self.assertEqual(changed['Suite']['EnvironmentVariables']['ICUBE_ALLOW_DEVICE_CONTROL'], '1')
        self.assertEqual(original['Suite']['EnvironmentVariables'], {'KEEP':'yes'})

    def test_rocketsim_errors_fail_closed(self):
        with self.assertRaises(ValueError): icube.check_rocketsim({'rs':'1','ok':False,'error':{'code':'quota_exceeded'}})
        with self.assertRaises(ValueError): icube.check_rocketsim({'ok':True})
        self.assertEqual(icube.check_rocketsim({'rs':'1','ok':True,'data':{}}), {})

if __name__ == '__main__': unittest.main()
