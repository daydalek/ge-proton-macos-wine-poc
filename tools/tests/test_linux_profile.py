# SPDX-License-Identifier: LGPL-2.1-or-later
"""Verify Linux keeps shared compatibility patches and rejects stale binaries."""
import importlib.util
import json
from pathlib import Path
import sys
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/linux'))
from build import patch_plan, sha256_file

spec = importlib.util.spec_from_file_location('linux_package', ROOT / 'scripts/linux/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class LinuxProfileTests(unittest.TestCase):
    def test_legacy_and_media_repairs_remain_enabled(self):
        plan = {entry['path']: entry for entry in patch_plan()}
        for name in ('i386-hotpatch-prologue', 'kernelbase-legacy-directory-info', 'winedmo-repeated-seek'):
            self.assertTrue(plan['patches/crossover/' + name + '.patch']['applied'])
        self.assertTrue(plan['patches/wine-ge/wine-upstream-syscall-wrappers.patch']['applied'])
        self.assertTrue(plan['patches/wine-ge/command-line-append.patch']['applied'])
        excluded = {name for name, entry in plan.items() if not entry['applied']}
        self.assertEqual(excluded, {'patches/crossover/steam-auto-args.patch',
                                    'patches/crossover/wined3d-backend-selection.patch'})

    def test_stale_module_and_patch_provenance_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            module = stage / 'ntdll.dll'
            module.write_bytes(b'compiled image')
            record = {'patches': patch_plan(), 'compiled_modules': {'ntdll.dll': sha256_file(module)}}
            manifest = stage / 'build-provenance.json'
            manifest.write_text(json.dumps(record))
            self.assertEqual(package.validate_provenance(stage), record)
            module.write_bytes(b'replaced image')
            with self.assertRaisesRegex(ValueError, 'module changed'):
                package.validate_provenance(stage)
            record['patches'] = []
            manifest.write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, 'patch provenance'):
                package.validate_provenance(stage)

    def test_elf_scan_rejects_external_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'external').symlink_to('/etc/passwd')
            with self.assertRaisesRegex(ValueError, 'external symlink'):
                package.validate_elf(root, {})

    def test_pe_scan_rejects_mixed_architecture_modules(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for arch, machine in (('i386', 0x14c), ('x86_64', 0x8664)):
                for name in ('ntdll', 'kernelbase', 'quartz', 'winedmo', 'wow64win'):
                    if name == 'wow64win' and arch == 'i386':
                        continue
                    path = root / 'lib/wine' / (arch + '-windows') / (name + '.dll')
                    path.parent.mkdir(parents=True, exist_ok=True)
                    image = bytearray(128)
                    image[:2] = b'MZ'
                    struct.pack_into('<I', image, 60, 64)
                    image[64:68] = b'PE\0\0'
                    struct.pack_into('<H', image, 68, machine)
                    path.write_bytes(image)
            self.assertEqual(len(package.validate_pe(root)), 9)
            path = root / 'lib/wine/i386-windows/quartz.dll'
            image = bytearray(path.read_bytes())
            struct.pack_into('<H', image, 68, 0x8664)
            path.write_bytes(image)
            with self.assertRaisesRegex(ValueError, 'PE architecture'):
                package.validate_pe(root)
