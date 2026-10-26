# SPDX-License-Identifier: LGPL-2.1-or-later
"""Verify overlap-aware patching before mutating a prepared Wine source."""
import difflib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('apply_series', ROOT / 'scripts/apply-patch-series.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PatchSeriesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.initial = {'example.c': '/* SPDX-License-Identifier: LGPL-2.1-or-later */\nint value = 1;\n' +
                        ''.join(f'/* retained line {i} */\n' for i in range(20))}
        self.first = {**self.initial, 'example.c': self.initial['example.c'].replace('value = 1', 'value = 2'),
                      'new.m': '/* SPDX-License-Identifier: LGPL-2.1-or-later */\nint cocoa_value;\n'}
        self.last = {**self.first, 'example.c': self.first['example.c'].replace('value = 2', 'value = 3'),
                     'header.h': '/* SPDX-License-Identifier: LGPL-2.1-or-later */\nint header_value;\n'}
        self.patches = [self.patch('first.patch', self.initial, self.first),
                        self.patch('last.patch', self.first, self.last)]
        for name, text in self.initial.items():
            (self.source / name).write_text(text)
        (self.source / 'example.c').chmod(0o755)

    def patch(self, name, old, new):
        lines = []
        for path in sorted(set(old) | set(new)):
            if old.get(path) == new.get(path):
                continue
            lines.append(f'diff --git a/{path} b/{path}\n')
            if path not in old:
                lines.append('new file mode 100644\n')
            lines.extend(difflib.unified_diff(old.get(path, '').splitlines(True), new.get(path, '').splitlines(True),
                                            fromfile='a/' + path if path in old else '/dev/null',
                                            tofile='b/' + path if path in new else '/dev/null'))
        file = self.root / name
        file.write_text(''.join(lines))
        return file

    def notices(self, patches):
        args = [sys.executable, str(ROOT / 'scripts/source-notices.py'), '--source', str(self.source)]
        for patch in patches:
            args += ['--patch', str(patch)]
        subprocess.run(args, check=True, capture_output=True)

    def test_fresh_source_overlap_rebuild_and_executable_mode(self):
        self.assertEqual(module.apply_series(self.source, self.patches)[0], 0)
        self.assertEqual((self.source / 'example.c').stat().st_mode & 0o777, 0o755)
        self.notices(self.patches)
        before = {p.name: p.read_bytes() for p in self.source.iterdir() if p.is_file()}
        (self.source / '.ge-patch-series.json').unlink()
        self.assertEqual(module.apply_series(self.source, self.patches), (2, 0))
        self.assertEqual(module.apply_series(self.source, self.patches), (2, 0))
        for name, expected in before.items():
            if name != '.ge-patch-series.json':
                self.assertEqual((self.source / name).read_bytes(), expected)

    def test_appended_patch_preserves_generated_notices_and_local_edits(self):
        module.apply_series(self.source, self.patches[:1])
        self.notices(self.patches[:1])
        file = self.source / 'example.c'
        file.write_text(file.read_text() + '/* local change outside patch hunks */\n')
        self.assertEqual(module.apply_series(self.source, self.patches)[0], 1)
        self.assertIn('value = 3', file.read_text())
        self.assertIn('GE macOS Wine PoC modification notice:', file.read_text())
        self.assertTrue(file.read_text().endswith('/* local change outside patch hunks */\n'))
        self.notices(self.patches)
        self.assertEqual(module.apply_series(self.source, self.patches), (2, 0))

    def test_conflicting_source_is_preserved(self):
        module.apply_series(self.source, self.patches[:1])
        file = self.source / 'example.c'
        file.write_text(file.read_text().replace('value = 2', 'value = 999'))
        before = {p.name: p.read_bytes() for p in self.source.iterdir() if p.is_file()}
        with self.assertRaises(ValueError):
            module.apply_series(self.source, self.patches)
        self.assertEqual({p.name: p.read_bytes() for p in self.source.iterdir() if p.is_file()}, before)

    def test_patch_escape_is_rejected(self):
        patch = self.root / 'escape.patch'
        patch.write_text('--- a/../outside.c\n+++ b/../outside.c\n')
        with self.assertRaises(ValueError):
            module.apply_series(self.source, [patch])
