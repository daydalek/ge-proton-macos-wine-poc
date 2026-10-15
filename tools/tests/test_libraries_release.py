#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
import hashlib
import json
import importlib.util
from pathlib import Path
import plistlib
import tarfile
import tempfile
import io
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('libraries', ROOT / 'scripts/ci/build-libraries.py')
libraries = importlib.util.module_from_spec(spec)
spec.loader.exec_module(libraries)
spec = importlib.util.spec_from_file_location('privacy', ROOT / 'scripts/ci/prepare-libraries.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class LibrariesTests(unittest.TestCase):
    def archive(self, file, extra=None):
        files = {'Libraries/WhiskyWineVersion.plist': plistlib.dumps({'dxvkVersion': '1.10.3'}),
                 'Libraries/Wine/bin/wine': b'old-core', 'Libraries/user.reg': b'old-state'}
        for arch in ('x32', 'x64'):
            for dll in ('d3d11.dll', 'd3d10core.dll'):
                files[f'Libraries/DXVK/{arch}/{dll}'] = b'fixture-dll'
        if extra:
            files.update(extra)
        with tarfile.open(file, 'w:gz') as tf:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))

    def test_bootstrap_extracts_only_dxvk_and_component_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.archive(root / 'base.tar.gz')
            base = libraries.extract_dxvk(root / 'base.tar.gz', root / 'base')
            self.assertFalse((base / 'Wine').exists())
            self.assertFalse((base / 'user.reg').exists())
            self.assertTrue((base / 'DXVK/x64/d3d11.dll').exists())
            self.assertTrue((base / 'DXVK/x32/d3d10core.dll').exists())

    def test_bootstrap_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.archive(root / 'base.tar.gz', {'Libraries/DXVK/../../../escape': b'bad'})
            with self.assertRaises(ValueError):
                libraries.extract_dxvk(root / 'base.tar.gz', root / 'base')

    def test_checksums_cover_runtime_plist_and_original_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('Libraries.tar.gz', 'WhiskyWineVersion.plist', 'Libraries-static-check.json',
                         'Libraries-sources.tar.gz', 'Libraries-ffmpeg-capabilities.json'):
                (root / name).write_bytes(name.encode())
            (root / 'SHA256SUMS').write_text('stale')
            libraries.update_checksums(root)
            rows = (root / 'SHA256SUMS').read_text().splitlines()
            self.assertEqual(len(rows), 5)
            for row in rows:
                digest, name = row.split('  ')
                self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest())

    def test_ci_account_word_preserves_public_symbols_and_still_flags_paths(self):
        self.assertFalse(privacy.private_identifier(b'queue_runner', 'runner', hosted_ci=True))
        path = b'/' + b'Users/' + b'runner/job'
        self.assertTrue(privacy.private_identifier(path, 'runner', hosted_ci=True))
        self.assertTrue(privacy.private_identifier(b'private-account', 'private-account'))

    def test_cross_over_provenance_rejects_changed_modules_or_patches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage, project = root / 'stage', root / 'project'
            stage.mkdir()
            (project / 'configs').mkdir(parents=True)
            (project / 'configs/crossover-source-lock.json').write_text(json.dumps({'source_sha256': 'a' * 64}))
            record = {'core': 'crossover-ge-media', 'source_archive_sha256': 'a' * 64,
                      'compiled_modules': {}, 'patches': {}}
            for category, base, names in [('compiled_modules', stage, libraries.REQUIRED_MODULES),
                                          ('patches', project, libraries.REQUIRED_PATCHES)]:
                for name in names:
                    file = base / name
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_bytes(name.encode())
                    record[category][name] = hashlib.sha256(file.read_bytes()).hexdigest()
            marker = stage / '.wine-build-provenance.json'
            marker.write_text(json.dumps(record))
            self.assertEqual(libraries.validate_compiled_provenance(stage, project), record)
            for base, name in [(stage, libraries.REQUIRED_MODULES[0]), (project, libraries.REQUIRED_PATCHES[0])]:
                file = base / name
                original = file.read_bytes()
                file.write_bytes(b'changed')
                with self.assertRaises(ValueError):
                    libraries.validate_compiled_provenance(stage, project)
                file.write_bytes(original)
            del record['patches'][libraries.REQUIRED_PATCHES[-1]]
            marker.write_text(json.dumps(record))
            with self.assertRaises(ValueError):
                libraries.validate_compiled_provenance(stage, project)

    def test_archive_header_contains_anonymous_metadata(self):
        info = tarfile.TarInfo('Libraries/Wine/bin/wine')
        info.uid = 501
        info.gid = 20
        info.uname = 'local-user'
        info.gname = 'staff'
        info.pax_headers = {'atime': '1', 'SCHILY.xattr.test': 'private'}
        cleaned = privacy.safe_header(info)
        self.assertEqual((cleaned.uid, cleaned.gid, cleaned.uname, cleaned.gname, cleaned.pax_headers),
                         (0, 0, '', '', {}))


if __name__ == '__main__':
    unittest.main()
