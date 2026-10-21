"""Compile the production Foundation validator once; reject malformed UI plans before input."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class ActionSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        work = Path(cls.temporary.name)
        main = work / 'main.swift'
        main.write_text('''import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
do {
  let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  try FastInteractionSchema.validate(input["actions"] as! [[String: Any]], tvOS: input["tvOS"] as! Bool)
  print("accepted")
} catch { print("rejected: \\(error)"); exit(1) }
''')
        cls.executable = work / 'schema'
        subprocess.run(['xcrun', 'swiftc', str(Path(__file__).with_name('FastInteractionSchema.swift')),
                        str(main), '-o', str(cls.executable)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def check(self, actions, accepted=False, tvos=True):
        result = subprocess.run([str(self.executable)], input=json.dumps({'actions': actions, 'tvOS': tvos}),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stdout + result.stderr)

    def test_valid_tv_and_touch_plans(self):
        self.check([{'op': 'launch', 'arguments': ['-ICubePausePreview']},
                    {'op': 'remote', 'button': 'select', 'duration': 1.2},
                    {'op': 'assert', 'identifier': 'hud', 'focused': True, 'enabled': True, 'timeout': 3},
                    {'op': 'capture', 'name': 'hud', 'ax': True}], accepted=True)
        self.check([{'op': 'activate'}, {'op': 'tap', 'label': 'Settings'},
                    {'op': 'type', 'identifier': 'title', 'text': '', 'clear': True}], accepted=True, tvos=False)

    def test_malformed_late_condition_rejects_entire_plan(self):
        for field, value in [('enabled', 'false'), ('exists', 1), ('focused', 'true'),
                             ('value', 7), ('valueContains', False), ('timeout', '5'), ('timeout', True)]:
            self.check([{'op': 'launch'}, {'op': 'assert', 'identifier': 'known', field: value}])

    def test_platform_constraints_are_not_silently_ignored(self):
        self.check([{'op': 'assert', 'identifier': 'known', 'focused': True}], tvos=False)
        self.check([{'op': 'remote', 'button': 'menu'}], tvos=False)
        self.check([{'op': 'remote', 'button': 'unknown'}])

    def test_wrong_types_ranges_and_unknown_fields(self):
        for duration in ['long', True, 0, -1, 3.1]:
            self.check([{'op': 'remote', 'button': 'select', 'duration': duration}])
        for action in [{'op': 'capture', 'ax': 1}, {'op': 'launch', 'arguments': [3]},
                       {'op': 'capture', 'unexpected': True},
                       {'op': 'type', 'label': 'Title', 'text': 'Test', 'clear': 'true'}]:
            self.check([action])

    def test_ambiguous_missing_and_contradictory_selectors(self):
        self.check([{'op': 'tap', 'identifier': 'one', 'label': 'two'}])
        self.check([{'op': 'assert', 'identifier': ' '}])
        self.check([{'op': 'assert', 'identifier': 'missing', 'exists': False, 'enabled': False}])
        self.check([{'op': 'assert', 'identifier': 'missing', 'exists': False}], accepted=True)

    def test_empty_and_excessive_plans(self):
        self.check([])
        self.check([{'op': 'capture'}] * 101)


if __name__ == '__main__':
    unittest.main()
