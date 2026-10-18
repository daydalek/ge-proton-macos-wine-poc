# SPDX-License-Identifier: LGPL-2.1-or-later
"""Compile the loader branch from the distributed patch with controlled PE results."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'patches/crossover/wined3d-backend-selection.patch'


class WineD3DLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if compiler is None:
            raise unittest.SkipTest('A C compiler is required for the loader tests')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        added = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith('+') and not line.startswith('+++'))
        branch = added[added.index('    if (!build_dir'):]
        source = root / 'loader.c'
        source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int32_t NTSTATUS;
#define STATUS_DLL_NOT_FOUND ((NTSTATUS)0xc0000135)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)0xc00000bb)
#define STATUS_DLL_INIT_FAILED ((NTSTATUS)0xc0000142)
#define TRACE(...) ((void)0)
#define ERR(...) ((void)0)
static NTSTATUS result;
static char opened[512];
static char *prepend(char *p, const char *s, size_t n) { return memcpy(p - n, s, n); }
static NTSTATUS open_builtin_pe_file(const char *p, ...)
{
    strcpy(opened, p);
    return result;
}
static NTSTATUS find_builtin_dll(const char *name, const char *build_dir, const char *pe_dir)
{
    char file[1024], *ptr = NULL;
    unsigned int pos = 512;
    const char *dll_dir = "/runtime/lib/wine", *so_dir = "/x86_64-unix";
    void *attr = NULL, *module = NULL, *size_ptr = NULL, *image_info = NULL;
    int limit_low = 0, limit_high = 0, load_machine = 0, prefer_native = 0, offset = 0;
    NTSTATUS status = STATUS_DLL_NOT_FOUND;
    file[pos] = '/';
    strcpy(file + pos + 1, name);
''' + branch + r'''
done:
    (void)ptr;
    return status;
}
int main(int argc, char **argv)
{
    if (argc != 5) return 2;
    result = (NTSTATUS)strtoul(argv[1], NULL, 0);
    NTSTATUS status = find_builtin_dll(argv[2], atoi(argv[3]) ? "/build" : NULL, argv[4]);
    /* load_builtin's default/builtin-native paths accept the prefix image for
     * DLL_NOT_FOUND and NOT_SUPPORTED. Selected-backend failures must propagate. */
    int prefix_fallback = status == STATUS_DLL_NOT_FOUND || status == STATUS_NOT_SUPPORTED;
    printf("%08x %d %s\n", (unsigned int)status, prefix_fallback, opened);
    return 0;
}
''')
        cls.binary = root / 'loader'
        subprocess.run([compiler, '-std=c99', str(source), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def load(self, status, name='d3d11.dll', build=False, arch='x86_64', value='0'):
        import os
        env = dict(os.environ)
        env.pop('WINED3DMETAL', None)
        if value is not None:
            env['WINED3DMETAL'] = value
        output = subprocess.check_output(
            [str(self.binary), hex(status), name, str(int(build)), '/' + arch + '-windows'],
            env=env, text=True)
        code, fallback, path = output.rstrip('\n').split(' ', 2)
        return int(code, 16), bool(int(fallback)), path

    def test_selected_backend_missing_or_unsupported_blocks_prefix_fallback(self):
        for arch in ('i386', 'x86_64'):
            for name in ('dxgi.dll', 'd3d10.dll', 'd3d10core.dll', 'd3d11.dll', 'd3d12.dll'):
                for status in (0xc0000135, 0xc00000bb):
                    with self.subTest(arch=arch, name=name, status=hex(status)):
                        code, fallback, path = self.load(status, name=name, arch=arch)
                        self.assertEqual(code, 0xc0000142)
                        self.assertFalse(fallback)
                        self.assertEqual(path, f'/runtime/lib/wine/wined3d/{arch}-windows/{name}')

    def test_success_and_other_errors_propagate(self):
        for status in (0, 0xc0000022, 0xc000007b):
            with self.subTest(status=hex(status)):
                code, fallback, _ = self.load(status)
                self.assertEqual(code, status)
                self.assertFalse(fallback)

    def test_normal_search_remains_available(self):
        for options in ({'value': None}, {'value': '1'}, {'value': ''},
                        {'name': 'ddraw.dll'}, {'build': True}):
            with self.subTest(options=options):
                _, fallback, path = self.load(0, **options)
                self.assertTrue(fallback)
                self.assertEqual(path, '')
