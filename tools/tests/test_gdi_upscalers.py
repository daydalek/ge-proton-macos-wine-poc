# SPDX-License-Identifier: LGPL-2.1-or-later
"""Unattended checks for the actual GDI patch, shader port and frame policy."""
import ctypes
import importlib.util
import os
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'native/gdi-upscalers'


def new_patch_files(name):
    files = {}
    for section in (ROOT / name).read_text().split('diff --git ')[1:]:
        if 'new file mode 100644\n' not in section:
            continue
        target = re.search(r'^\+\+\+ b/(.+)$', section, re.M).group(1)
        files[Path(target).name] = ''.join(line[1:] + '\n' for line in section.splitlines()
                                               if line.startswith('+') and not line.startswith('+++'))
    return files


class FrameAndShaderTests(unittest.TestCase):
    def test_exact_pixel_difference_and_stability_with_sanitizers(self):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler required')
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / 'frame-diff'
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-I' + str(NATIVE / 'include'),
                            str(NATIVE / 'tests/frame-diff-test.c'), '-o', str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=15)

    def test_canonical_headers_match_distributed_wine_patch(self):
        files = new_patch_files('patches/wine-ge/macos-gdi-upscalers.patch')
        for name in ('wine_gdi_upscaler.h', 'wine_gdi_frame_diff.h', 'wine_gdi_upscale_policy.h'):
            self.assertEqual(files[name], (NATIVE / 'include' / name).read_text(), name)

    def test_metal_port_preserves_every_official_weight_in_column_order(self):
        spec = importlib.util.spec_from_file_location('anime4k_generator', ROOT / 'scripts/generate-anime4k-metal.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = module.SOURCE.read_text()
        generated = module.generate(source)
        original = re.findall(r'mat4\(([^)]+)\)', source)
        converted = re.findall(r'float4x4\((.*?)\) \* go_', generated)
        self.assertEqual(len(original), 63)  # 9 first-layer taps, then 3 × 18 signed taps.
        self.assertEqual(len(converted), len(original))
        number = r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?'
        for old, new in zip(original, converted):
            # Strip constructor names before comparing the exact scalar sequence.
            self.assertEqual(re.findall(number, old), re.findall(number, new.replace('float4', '')))
        self.assertEqual(generated.count('kernel void convolution'), 4)
        self.assertIn('features.read(gid / 2)[(gid.y % 2) * 2 + gid.x % 2]', generated)
        with self.assertRaises(ValueError):
            module.generate(source.replace(' * go_0(-1.0, -1.0)', '', 1))


@unittest.skipUnless(sys.platform == 'darwin', 'macOS Objective-C adapter')
class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.path = Path(cls.temporary.name)
        files = new_patch_files('patches/wine-ge/macos-metalfx-spatial.patch')
        files.update(new_patch_files('patches/wine-ge/macos-gdi-upscalers.patch'))
        for name, content in files.items():
            (cls.path / name).write_text(content)
        cls.binary = cls.path / 'cache-probe'
        subprocess.run(['clang', '-arch', 'x86_64', '-mmacosx-version-min=11.0', '-fblocks',
                        '-Wall', '-Wextra', '-Werror', '-I' + str(cls.path),
                        str(ROOT / 'tools/probes/gdi-upscaler-cache-probe.m'),
                        str(cls.path / 'cocoa_upscaler.m'), '-framework', 'AppKit',
                        '-framework', 'Metal', '-o', str(cls.binary)],
                       check=True, capture_output=True)
        if os.getenv('WGDI_TEST_NATIVE_LIBRARY'):
            native = Path(os.environ['WGDI_TEST_NATIVE_LIBRARY']).resolve()
            (cls.path / 'libwinegdiupscalers.dylib').symlink_to(native)
            (cls.path / 'gdi-upscalers').symlink_to(native.parent / 'gdi-upscalers', target_is_directory=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_probe(self, mode, probe, library=None):
        env = dict(os.environ, WINE_GDI_UPSCALER=mode, WINE_METALFX='spatial')
        env.pop('WINE_GDI_UPSCALER_LIBRARY', None)
        if library:
            env['WINE_GDI_UPSCALER_LIBRARY'] = library
        result = subprocess.run([str(self.binary), probe], env=env, capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_disabled_and_unknown_modes_override_legacy_opt_in(self):
        self.run_probe('off', 'disabled')
        self.run_probe('unknown', 'disabled')

    def test_fast_backend_reuses_100_identical_frames_and_detects_one_byte_changes(self):
        self.run_probe('metalfx', 'fast')

    def test_missing_neural_backend_retains_standard_or_fast_presentation(self):
        self.run_probe('anime4k', 'failure', '/missing/wine-gdi-upscalers.dylib')
        self.run_probe('adaptive', 'adaptive-failure', '/missing/wine-gdi-upscalers.dylib')

    @unittest.skipUnless(os.getenv('WGDI_TEST_NATIVE_LIBRARY'), 'Build native library and set WGDI_TEST_NATIVE_LIBRARY')
    def test_real_model_async_cache_rejects_stale_results(self):
        self.run_probe('realcugan', 'neural', os.environ['WGDI_TEST_NATIVE_LIBRARY'])

    @unittest.skipUnless(os.getenv('WGDI_TEST_NATIVE_LIBRARY'), 'Build native library and set WGDI_TEST_NATIVE_LIBRARY')
    def test_default_sibling_library_and_resource_layout(self):
        self.run_probe('realcugan', 'neural')

    @unittest.skipUnless(os.getenv('WGDI_TEST_NATIVE_LIBRARY'), 'Build native library and set WGDI_TEST_NATIVE_LIBRARY')
    def test_adaptive_quiet_interval_fast_fallback_and_idle_timer(self):
        self.run_probe('adaptive', 'adaptive', os.environ['WGDI_TEST_NATIVE_LIBRARY'])


@unittest.skipUnless(os.getenv('WGDI_TEST_GPU') == '1' and os.getenv('WGDI_TEST_NATIVE_LIBRARY'),
                     'Optional window-free GPU/reference comparison')
class Anime4KGPUTests(unittest.TestCase):
    def test_official_network_matches_metal_on_small_gradient(self):
        class Image(ctypes.Structure):
            _fields_ = [('pixels', ctypes.POINTER(ctypes.c_uint8)), ('bytes', ctypes.c_size_t),
                        ('stride', ctypes.c_size_t), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32)]

        class Options(ctypes.Structure):
            _fields_ = [('size', ctypes.c_uint32), ('algorithm', ctypes.c_uint32),
                        ('resources', ctypes.c_char_p), ('threads', ctypes.c_uint32)]

        create = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.POINTER(Options), ctypes.c_void_p, ctypes.c_size_t)
        process = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(Image),
                                  ctypes.POINTER(Image), ctypes.c_void_p, ctypes.c_size_t)
        destroy = ctypes.CFUNCTYPE(None, ctypes.c_void_p)

        class API(ctypes.Structure):
            _fields_ = [('version', ctypes.c_uint32), ('size', ctypes.c_uint32),
                        ('create', create), ('process', process), ('destroy', destroy)]

        path = Path(os.environ['WGDI_TEST_NATIVE_LIBRARY']).resolve()
        library = ctypes.CDLL(str(path))
        library.wgdi_upscaler_get_api.argtypes = [ctypes.c_uint32]
        library.wgdi_upscaler_get_api.restype = ctypes.POINTER(API)
        api = library.wgdi_upscaler_get_api(1).contents
        error = ctypes.create_string_buffer(512)
        options = Options(ctypes.sizeof(Options), 1, os.fsencode(path.parent / 'gdi-upscalers'), 1)
        context = api.create(ctypes.byref(options), error, len(error))
        if not context and b'Metal device unavailable' in error.value:
            self.skipTest(error.value.decode())
        self.assertTrue(context, error.value.decode())
        width, height = 5, 7
        raw = bytearray()
        image = []
        for y in range(height):
            row = []
            for x in range(width):
                b, g, r = (x * 31 + y * 11 + 9) % 256, (x * 13 + y * 27 + 25) % 256, (x * 21 + y * 5 + 40) % 256
                raw.extend((b, g, r, 255))
                row.append([r / 255, g / 255, b / 255, 1.0])
            image.append(row)
        original = image
        source = (NATIVE / 'vendor/anime4k/Anime4K_Upscale_CNN_x2_S.glsl').read_text()
        for index, block in enumerate(source.split('//!DESC ')[1:5]):
            taps = re.findall(r'mat4\(([^)]+)\) \* go_([01])\(([-\d.]+), ([-\d.]+)\)', block)
            bias = [float(x) for x in re.search(r'result \+= vec4\(([^)]+)\)', block)[1].split(',')]
            result = []
            for y in range(height):
                row = []
                for x in range(width):
                    value = list(bias)
                    for matrix, signed, dx, dy in taps:
                        weights = [float(w) for w in matrix.split(',')]
                        sample = image[max(0, min(height - 1, y + int(float(dy))))][max(0, min(width - 1, x + int(float(dx))))]
                        if index:
                            sample = [max(-v if signed == '1' else v, 0) for v in sample]
                        for channel in range(4):
                            value[channel] += sum(weights[column * 4 + channel] * sample[column] for column in range(4))
                    row.append(value)
                result.append(row)
            image = result
        expected = []
        for y in range(height * 2):
            for x in range(width * 2):
                sx, sy = x / 2 - 0.25, y / 2 - 0.25
                x0, y0 = math.floor(sx), math.floor(sy)
                fx, fy = sx - x0, sy - y0
                residual = image[y // 2][x // 2][(y % 2) * 2 + x % 2]
                rgb = []
                for channel in range(3):
                    base = sum(original[max(0, min(height - 1, y0 + dy))][max(0, min(width - 1, x0 + dx))][channel]
                               * (fx if dx else 1 - fx) * (fy if dy else 1 - fy)
                               for dx in range(2) for dy in range(2))
                    rgb.append(round(max(0, min(1, base + residual)) * 255))
                expected.extend((rgb[2], rgb[1], rgb[0], 255))
        input_bytes = (ctypes.c_uint8 * len(raw)).from_buffer_copy(raw)
        output_bytes = (ctypes.c_uint8 * (width * height * 16))()
        before = Image(input_bytes, len(raw), width * 4, width, height)
        after = Image(output_bytes, len(output_bytes), width * 8, width * 2, height * 2)
        try:
            self.assertEqual(api.process(context, ctypes.byref(before), ctypes.byref(after), error, len(error)), 0,
                             error.value.decode())
            self.assertLessEqual(max(abs(actual - reference) for actual, reference in zip(output_bytes, expected)), 2)
        finally:
            api.destroy(context)


if __name__ == '__main__':
    unittest.main()
