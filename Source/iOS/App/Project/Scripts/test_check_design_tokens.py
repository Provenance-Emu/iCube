#!/usr/bin/env python3
"""Unit tests for check_design_tokens.py. Run: python3 -m unittest Project/Scripts/test_check_design_tokens.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_design_tokens as cdt  # noqa: E402


class CountTests(unittest.TestCase):
    def count(self, text, path="Common/Swift/Foo.swift"):
        return cdt.count_violations(text, path)

    def test_flags_each_pattern(self):
        for line in [
            '.font(.system(size: 20))',
            '.font(.headline)',
            '.font(.caption2)',
            'Font.custom("X", size: 3)',
            'RoundedRectangle(cornerRadius: 12)',
            '.stroke(c, lineWidth: 2)',
            'Color(red: 0.1, green: 0.2, blue: 0.3)',
            'Color.cyan.opacity(0.5)',
            '.buttonStyle(.borderedProminent)',
        ]:
            self.assertEqual(self.count(line), 1, line)

    def test_ignores_tokens_and_variables(self):
        for line in [
            'RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue)',
            '.stroke(c, lineWidth: width)',
            '.font(icube.font(.body))',
            'Color.clear',
            'Color.white.opacity(0.2)',
        ]:
            self.assertEqual(self.count(line), 0, line)

    def test_ignores_comments_and_allow_marker(self):
        self.assertEqual(self.count('// .font(.headline)'), 0)
        self.assertEqual(self.count('/* Color.cyan */ let x = 1'), 0)
        self.assertEqual(self.count('.font(.headline) // design-lint: allow system menu label'), 0)

    def test_navigationTitle_only_in_tvOS_code(self):
        text = '\n'.join([
            '.navigationTitle("A")',          # shared code: not flagged
            '#if os(tvOS)',
            '.navigationTitle("B")',          # flagged
            '#else',
            '.navigationTitle("C")',          # iOS branch: not flagged
            '#endif',
        ])
        self.assertEqual(self.count(text), 1)
        self.assertEqual(self.count('.navigationTitle("A")', "Common/Swift/TVFoo.swift"), 1)
        self.assertEqual(self.count('#if !os(tvOS)\n.navigationTitle("A")\n#endif', "Common/Swift/TVFoo.swift"), 0)

    def test_exempt_paths(self):
        self.assertTrue(cdt.is_exempt("Common/Swift/MenuKit/ICubeDesign+Focus.swift"))
        self.assertTrue(cdt.is_exempt("Common/Swift/Debug/DebugAPIRoutes.swift"))
        self.assertTrue(cdt.is_exempt("Common/Swift/MotionDebugView.swift"))
        self.assertFalse(cdt.is_exempt("Common/Swift/GameGridItem.swift"))


class RatchetTests(unittest.TestCase):
    def test_compare(self):
        worse, better = cdt.compare({"a.swift": 3, "new.swift": 1}, {"a.swift": 2, "gone.swift": 4})
        self.assertEqual(worse, {"a.swift": (2, 3), "new.swift": (0, 1)})
        self.assertEqual(better, {"gone.swift": (4, 0)})


if __name__ == "__main__":
    unittest.main()
