# SPDX-License-Identifier: LGPL-2.1-or-later
"""Verify Linux keeps shared compatibility patches and rejects stale binaries."""
import importlib.util
import json
from pathlib import Path
import sys
import struct
import re
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/linux'))
from build import patch_plan, sha256_file, incremental_additions
import verify as linux_verify

spec = importlib.util.spec_from_file_location('linux_package', ROOT / 'scripts/linux/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class LinuxProfileTests(unittest.TestCase):
    def test_pulse_readiness_uses_real_stream_state_and_handles_missing_stream(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('A C compiler is required')
        added = '\n'.join(line[1:] for line in (ROOT / 'patches/linux/crossover-pulse-build.patch').read_text().splitlines()
                          if line.startswith('+') and not line.startswith('+++'))
        helper = re.search(r'static BOOL pulse_stream_ready\(.*?\n\}', added, re.S).group()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'pulse-ready.c'
            source.write_text('''typedef int BOOL;
enum { PA_STREAM_CREATING, PA_STREAM_READY, PA_STREAM_FAILED, PA_STREAM_TERMINATED };
struct fake_stream { int state; };
struct pulse_stream { struct fake_stream *stream; };
static int queries;
static int pa_stream_get_state(struct fake_stream *stream) { ++queries; return stream->state; }
''' + helper + '''
int main(void) {
    struct fake_stream native = {0};
    struct pulse_stream stream = {0};
    if (pulse_stream_ready(&stream) || queries) return 1;
    stream.stream = &native;
    for (int i = 0; i < 4; ++i) {
        native.state = i;
        if (pulse_stream_ready(&stream) != (i == PA_STREAM_READY)) return 2;
    }
    return queries == 4 ? 0 : 3;
}
''')
            binary = root / 'pulse-ready'
            subprocess.run([compiler, '-std=c99', '-Werror=implicit-function-declaration',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_incremental_source_rejects_rewritten_history_and_baseline_changes(self):
        previous = {'source_sha256': 'baseline', 'patches': [{'path': 'first', 'sha256': 'original'}]}
        added = {'path': 'second', 'sha256': 'new'}
        current = {'source_sha256': 'baseline', 'patches': previous['patches'] + [added]}
        self.assertEqual(incremental_additions(previous, current), [added])
        for changed in (
            {'source_sha256': 'other', 'patches': current['patches']},
            {'source_sha256': 'baseline', 'patches': [{'path': 'first', 'sha256': 'changed'}, added]},
            previous,
        ):
            with self.assertRaisesRegex(ValueError, 'Source inputs changed'):
                incremental_additions(previous, changed)

    def test_runtime_environment_clears_inherited_renderer_and_loader_overrides(self):
        with patch.dict('os.environ', {'LD_PRELOAD': '/inherited/inject.so',
                                     'LD_AUDIT': '/inherited/audit.so',
                                     'WINE_D3D_CONFIG': 'renderer=gdi',
                                     'VK_DRIVER_FILES': '/inherited/driver.json'}):
            env = linux_verify.runtime_environment(SimpleNamespace(deps=Path('/deps')),
                Path('/runtime'), Path('/validation'), packaged=True)
        for key in ('LD_PRELOAD', 'LD_AUDIT', 'WINE_D3D_CONFIG'):
            self.assertNotIn(key, env)
        self.assertNotEqual(env.get('VK_DRIVER_FILES'), '/inherited/driver.json')

    def test_ne_bitmap_fonts_are_preserved_by_runtime_preparation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            image = bytearray(128)
            image[:2] = b'MZ'
            struct.pack_into('<I', image, 60, 64)
            image[64:66] = b'NE'
            path = root / 'bitmap.fon'
            path.write_bytes(image)
            report = package.prepare_runtime(root, Path('/unavailable-objcopy'))
            self.assertEqual(report['debug_stripped'], 0)
            self.assertEqual(path.read_bytes(), image)

    def test_packaged_validation_uses_only_shipped_libraries(self):
        build = SimpleNamespace(deps=Path('/build/deps'))
        runtime = Path('/relocated/runtime')
        output = Path('/validation')
        packaged = linux_verify.runtime_environment(build, runtime, output, packaged=True)
        self.assertEqual(packaged['LD_LIBRARY_PATH'], '/relocated/runtime/lib')
        self.assertEqual(packaged['WINEPREFIX'], '/validation/prefix')
        staged = linux_verify.runtime_environment(build, runtime, output)
        self.assertEqual(staged['LD_LIBRARY_PATH'], '/relocated/runtime/lib:/build/deps/lib')

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
