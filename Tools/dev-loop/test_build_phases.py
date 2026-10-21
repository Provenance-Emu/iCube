"""Exercise the real build-phase guards with isolated command stubs, never the network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'Source/iOS/App/Project/Scripts'


class BuildPhaseTests(unittest.TestCase):
    def run_phase(self, script, configuration, *, fast=True):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary = work / 'bin'
            binary.mkdir()
            python = work / 'venv/bin/python3'
            python.parent.mkdir(parents=True)
            log = work / 'calls'
            for path in [binary / 'sentry-cli', binary / 'bartycrouch', python]:
                path.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ICUBE_PHASE_TEST_LOG"\n')
                path.chmod(0o755)
            (binary / 'uname').write_text('#!/bin/sh\necho x86_64\n')
            (binary / 'uname').chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + ':/usr/bin:/bin', PROJECT_DIR=str(work),
                       CONFIGURATION=configuration, ICUBE_PHASE_TEST_LOG=str(log),
                       ICUBE_FAST_DEV='1' if fast else '0',
                       ICUBE_FAST_DEV_SKIP_LOCALIZATION='1' if fast else '0',
                       DWARF_DSYM_FOLDER_PATH=str(work / 'symbols'))
            result = subprocess.run(['/bin/bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return log.read_text() if log.exists() else ''

    def test_debug_fast_does_not_regenerate_storyboards(self):
        self.assertEqual(self.run_phase((SCRIPTS / 'UpdateStoryboardStrings.sh').read_text(),
                                        'Debug (Non-Jailbroken)'), '')

    def test_release_ignores_localization_shortcut(self):
        self.assertIn('update -x', self.run_phase((SCRIPTS / 'UpdateStoryboardStrings.sh').read_text(),
                                                'Release (AppStore)'))

    def test_normal_debug_still_regenerates_storyboards(self):
        self.assertIn('update -x', self.run_phase((SCRIPTS / 'UpdateStoryboardStrings.sh').read_text(),
                                                'Debug (Non-Jailbroken)', fast=False))

    def test_core_and_transfer_wrappers_honor_debug_only_shortcut(self):
        for name in ['UpdateCoreStrings.sh', 'TransferCoreStringsToStoryboard.sh']:
            script = (SCRIPTS / name).read_text()
            self.assertEqual(self.run_phase(script, 'Debug (Non-Jailbroken)'), '')
            self.assertIn('.py', self.run_phase(script, 'Release (AppStore)'))
            self.assertIn('.py', self.run_phase(script, 'Debug (Non-Jailbroken)', fast=False))

    def test_fast_debug_skips_sentry_but_release_keeps_upload(self):
        text = (ROOT / 'Source/iOS/App/Project.swift').read_text()
        start = text.index('script: """', text.index('let uploadDsymScript')) + len('script: """')
        script = text[start:text.index('""",', start)]
        self.assertEqual(self.run_phase(script, 'Debug (Non-Jailbroken)'), '')
        self.assertIn('debug-files upload', self.run_phase(script, 'Release (AppStore)'))
        self.assertIn('debug-files upload', self.run_phase(script, 'Debug (Non-Jailbroken)', fast=False))

    def test_existing_polib_does_not_call_pip(self):
        calls = self.run_phase((SCRIPTS / 'SetUpPython.sh').read_text(), 'Debug (Non-Jailbroken)')
        self.assertNotIn('-m pip', calls)


if __name__ == '__main__':
    unittest.main()
