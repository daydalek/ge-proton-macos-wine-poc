# SPDX-License-Identifier: LGPL-2.1-or-later
import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[2] / 'scripts/lib/wined3d_builtins.py'
SPEC = importlib.util.spec_from_file_location('wined3d_builtins', MODULE)
graphics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(graphics)


class WineD3DBuiltinsTests(unittest.TestCase):
    def make_source(self, root):
        for arch in graphics.ARCHITECTURES:
            for name in graphics.GRAPHICS_DLLS:
                path = root / 'lib/wine' / arch / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'MZ' + bytes(62) + b'Wine builtin DLL' + (arch + name).encode())

    def test_preserves_both_architectures_without_changing_defaults(self):
        with tempfile.TemporaryDirectory() as temp:
            wine = Path(temp)
            self.make_source(wine)
            graphics.preserve_wined3d_builtins(wine)
            for arch in graphics.ARCHITECTURES:
                for name in graphics.GRAPHICS_DLLS:
                    original = wine / 'lib/wine' / arch / name
                    alternate = wine / 'lib/wine/wined3d' / arch / name
                    self.assertEqual(original.read_bytes(), alternate.read_bytes())
                    original.write_bytes(b'replaced by GPTK')
                    self.assertNotEqual(original.read_bytes(), alternate.read_bytes())

    def test_uses_clean_stage_not_deployed_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            source, wine = Path(temp) / 'source', Path(temp) / 'Wine'
            self.make_source(source)
            graphics.preserve_wined3d_builtins(wine, source)
            source_dll = source / 'lib/wine/x86_64-windows/dxgi.dll'
            self.assertEqual(source_dll.read_bytes(),
                             (wine / 'lib/wine/wined3d/x86_64-windows/dxgi.dll').read_bytes())

    def test_invalid_or_missing_inputs_do_not_partially_publish(self):
        for kind in ('missing', 'native', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                source, wine = Path(temp) / 'source', Path(temp) / 'Wine'
                self.make_source(source)
                path = source / 'lib/wine/i386-windows/d3d12.dll'
                path.unlink()
                if kind == 'native':
                    path.write_bytes(b'MZ' + bytes(100))
                elif kind == 'symlink':
                    path.symlink_to('dxgi.dll')
                with self.assertRaises(ValueError):
                    graphics.preserve_wined3d_builtins(wine, source)
                self.assertFalse(wine.exists())
