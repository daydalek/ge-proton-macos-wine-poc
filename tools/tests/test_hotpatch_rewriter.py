# SPDX-License-Identifier: LGPL-2.1-or-later
"""Exercise the C rewriter shipped in the patch with synthetic PE inputs."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'patches/crossover/i386-hotpatch-prologue.patch'


class HotpatchRewriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if compiler is None:
            raise unittest.SkipTest('A C compiler is required for the PE rewriter tests')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        # Compile the actual implementation added by the patch, including its
        # RVA helpers, rather than a separate model of the parsing logic.
        added = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith('+') and not line.startswith('+++'))
        start = added.index('struct pe_section_range\n')
        end = added.index('\n            fixup_i386_hotpatch_prologues( fd, header.e_lfanew );')
        source = cls.root / 'rewriter.c'
        source.write_text('''#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define IMAGE_SIZEOF_NT_OPTIONAL32_HEADER 224
#define IMAGE_FILE_MACHINE_I386 0x14c
#define IMAGE_NT_OPTIONAL_HDR32_MAGIC 0x10b
#define xmalloc malloc
''' + added[start:end] + '''
int main(int argc, char **argv)
{
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) return 2;
    fixup_i386_hotpatch_prologues(fd, strtoul(argv[2], NULL, 0));
    return close(fd) ? 3 : 0;
}
''')
        cls.binary = cls.root / 'rewriter'
        subprocess.run([compiler, '-g', '-fsanitize=address,undefined',
                        '-fno-sanitize-recover=all', str(source), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def rewrite(self, data, lfanew=0x80):
        path = self.root / 'input.dll'
        path.write_bytes(data)
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:abort_on_error=0')
        result = subprocess.run([str(self.binary), str(path), hex(lfanew)],
                                env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return path.read_bytes()

    def pe(self, symbols=False):
        data = bytearray(0x600)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 0x80)
        struct.pack_into('<IHH', data, 0x80, 0x4550, 0x14c, 1)
        struct.pack_into('<H', data, 0x80 + 20, 224)
        struct.pack_into('<H', data, 0x80 + 24, 0x10b)
        section = 0x80 + 24 + 224
        struct.pack_into('<III', data, section + 12, 0x1000, 0x400, 0x200)
        struct.pack_into('<I', data, section + 36, 0x60000020)
        data[0x280:0x288] = b'\x90' * 6 + b'\x66\x90'
        if symbols:
            struct.pack_into('<II', data, 0x80 + 12, 0x500, 1)
            struct.pack_into('<IhH', data, 0x500 + 8, 0x86, 1, 0x20)
        else:
            struct.pack_into('<III', data, 0x80 + 116, 1, 0x1000, 0x60)
            struct.pack_into('<I', data, 0x200 + 20, 1)
            struct.pack_into('<I', data, 0x200 + 28, 0x1040)
            struct.pack_into('<I', data, 0x240, 0x1086)
        return data

    def test_large_pe_offsets_are_ignored_safely(self):
        data = bytes(512)
        for offset in (513, 0xffffff08, 0xfffffff0, 0xffffffff):
            with self.subTest(offset=hex(offset)):
                self.assertEqual(self.rewrite(data, offset), data)

    def test_truncated_headers_are_ignored_safely(self):
        for size in (0, 1, 127, 128, 375):
            with self.subTest(size=size):
                data = bytes(size)
                self.assertEqual(self.rewrite(data), data)

    def test_export_rewrite_changes_only_entry_and_is_idempotent(self):
        data = self.pe()
        expected = bytearray(data)
        expected[0x286:0x288] = b'\x8b\xff'
        rewritten = self.rewrite(data)
        self.assertEqual(rewritten, expected)
        self.assertEqual(self.rewrite(rewritten), expected)

    def test_coff_function_symbol_is_rewritten(self):
        data = self.pe(symbols=True)
        expected = bytearray(data)
        expected[0x286:0x288] = b'\x8b\xff'
        self.assertEqual(self.rewrite(data), expected)

    def test_other_entry_layout_is_preserved(self):
        data = self.pe()
        data[0x285] = 0xcc
        self.assertEqual(self.rewrite(data), data)

    def test_x64_image_is_preserved(self):
        data = self.pe()
        struct.pack_into('<H', data, 0x80 + 4, 0x8664)
        self.assertEqual(self.rewrite(data), data)
