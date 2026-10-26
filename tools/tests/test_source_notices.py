# SPDX-License-Identifier: LGPL-2.1-or-later
"""Preserve original notices and bind platform manifests to final source bytes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourceNoticeTests(unittest.TestCase):
    def test_latest_patch_date_labels_the_prepared_source(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            (source / 'example.c').write_text('/* Copyright 2026 Example */\nint example;\n')
            patches = []
            for day in (25, 26):
                patch = source / f'{day}.patch'
                patch.write_text(f'Modification date: 2026-10-{day}\n+++ b/example.c\n')
                patches.extend(['--patch', str(patch)])
            subprocess.run([sys.executable, str(ROOT / 'scripts/source-notices.py'),
                            '--source', str(source), *patches], check=True, capture_output=True)
            manifest = json.loads((source / 'MODIFICATIONS.json').read_text())
            self.assertEqual(manifest['date'], '2026-10-26')
            self.assertIn('modification notice: 2026-10-26', (source / 'example.c').read_text())

    def test_objective_c_notices_are_valid_comments(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            for name in ('cocoa_spatial.m', 'example.mm'):
                (source / name).write_text('/* SPDX-License-Identifier: LGPL-2.1-or-later */\nint example;\n')
            patch = source / 'changes.patch'
            patch.write_text('+++ b/cocoa_spatial.m\n+++ b/example.mm\n')
            subprocess.run([sys.executable, str(ROOT / 'scripts/source-notices.py'),
                            '--source', str(source), '--patch', str(patch)],
                           check=True, capture_output=True)
            for name in ('cocoa_spatial.m', 'example.mm'):
                text = (source / name).read_text()
                self.assertIn('/* GE macOS Wine PoC modification notice:', text)
                self.assertNotIn('# GE macOS', text)

    def test_linux_notices_preserve_authors_and_refresh_shared_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            original = '/* Copyright 2025 Example contributors */\nint example;\n'
            (source / 'example.c').write_text(original)
            (source / 'Makefile.in').write_text('SOURCES = example.c\n')
            patch = source / 'changes.patch'
            patch.write_text('+++ b/example.c\n+++ b/Makefile.in\n')
            command = [sys.executable, str(ROOT / 'scripts/source-notices.py'),
                       '--source', str(source), '--patch', str(patch)]
            subprocess.run(command, check=True, capture_output=True)
            initial = (source / 'example.c').read_text()
            self.assertTrue(initial.startswith('/* GE macOS Wine PoC modification notice: 2026-10-12;'))
            subprocess.run(command + ['--platform', 'linux', '--date', '2026-10-23'],
                           check=True, capture_output=True)
            subprocess.run(command, check=True, capture_output=True)
            current = (source / 'example.c').read_text()
            self.assertIn(original, current)
            self.assertEqual(current.count('GE macOS Wine PoC modification notice:'), 1)
            self.assertEqual(current.count('GE Wine Linux modification notice: 2026-10-23'), 1)
            for name in ('MODIFICATIONS.json', 'LINUX_MODIFICATIONS.json'):
                manifest = json.loads((source / name).read_text())
                for record in manifest['files']:
                    self.assertEqual(record['modification_date'], '2026-10-23')
                    self.assertEqual(record['sha256'], hashlib.sha256((source / record['file']).read_bytes()).hexdigest())
                record = next(item for item in manifest['files'] if item['file'] == 'example.c')
                self.assertEqual(record['original_copyright_notices'], ['Copyright 2025 Example contributors'])
            subprocess.run(command + ['--platform', 'linux', '--date', '2026-10-23'],
                           check=True, capture_output=True)
            self.assertEqual((source / 'example.c').read_text(), current)


if __name__ == '__main__':
    unittest.main()
