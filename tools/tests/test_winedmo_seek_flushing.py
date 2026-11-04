# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless regression test for the winedmo seek-read flush guard.

The flush-guard condition is extracted verbatim from the maintained
patches/crossover/winedmo-seek-read-flushing.patch (both the
media_source.c and wm_reader.c read callbacks) and compiled against a
recording stub.  Assertions cover: flush on the demux thread aborts the
read, flush on a seek/other thread still reads, no-flush normal reads
pass, and shutdown aborts regardless of thread.  The CreateThread id
out-param wiring is checked textually in the patch.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vmr7_native_sources import (WINEDMO_SEEK_PATCH, added_lines,  # noqa: E402
                                 flush_guard_condition)

PREAMBLE = r'''
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

typedef uint32_t DWORD;
static DWORD current_tid;
static DWORD GetCurrentThreadId(void) { return current_tid; }

struct fixture {
    int read_flushing;
    DWORD demux_thread_id;
    int demux_thread_shutdown;
    int demux_shutdown;
};

static int failures;
#define CHECK(cond, name) \
    do { \
        if (cond) printf("PASS %s\n", name); \
        else { printf("FAIL %s\n", name); ++failures; } \
    } while (0)
'''

MAIN = r'''
int main(void)
{
    /* The production 'if' is compiled verbatim inside should_flush(). */
    struct fixture *source = (struct fixture *)calloc(1, sizeof(*source));

    current_tid = 100; source->demux_thread_id = 100; source->read_flushing = 1;
    CHECK(should_flush(source), "flush on demux thread aborts read");
    current_tid = 200;
    CHECK(!should_flush(source), "flush on seek thread still reads");
    current_tid = 100; source->read_flushing = 0;
    CHECK(!should_flush(source), "no-flush demux read allowed");
    current_tid = 200;
    CHECK(!should_flush(source), "no-flush seek read allowed");
    source->read_flushing = 1;
    source->demux_thread_shutdown = 1; source->demux_shutdown = 1;
    current_tid = 100;
    CHECK(should_flush(source), "shutdown aborts demux read");
    current_tid = 200;
    CHECK(should_flush(source), "shutdown aborts seek read");
    source->read_flushing = 0;
    CHECK(should_flush(source), "shutdown aborts without flush");
    free(source);

    printf("%s\n", failures ? "FAILED" : "ALL PASS");
    return failures ? 1 : 0;
}
'''


def harness_for(obj_name, condition):
    """Wrap the verbatim production condition in a predicate.  The fixture
    is aliased to the production variable name ('source'/'reader'); the
    caller-side fixture pointer is always named 'source'."""
    return (PREAMBLE
            + 'static int should_flush(struct fixture *' + obj_name + ')\n{\n    '
            + condition + ' return 1;\n    return 0;\n}\n\n'
            + MAIN)


class WinedmoSeekFlushTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not WINEDMO_SEEK_PATCH.is_file():
            raise unittest.SkipTest('maintained seek-flush patch not found')
        cls.compiler = shutil.which('clang') or shutil.which('cc')
        if not cls.compiler:
            raise unittest.SkipTest('A C compiler is required')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)

    def run_guard(self, path_key):
        cond = flush_guard_condition(path_key)
        obj = 'reader' if 'reader->' in cond else 'source'
        root = Path(self.temp.name)
        src = root / ('flush_' + obj + '.c')
        src.write_text(harness_for(obj, cond))
        binary = root / ('flush_' + obj)
        subprocess.run([self.compiler, '-std=c11', '-O0', '-g', '-Wall', '-Wextra',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(src), '-o', str(binary)], check=True, capture_output=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True,
                                timeout=30,
                                env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ALL PASS', result.stdout)

    def test_media_source_flush_guard(self):
        self.run_guard('dlls/winedmo/media_source.c')

    def test_wm_reader_flush_guard(self):
        self.run_guard('dlls/winedmo/wm_reader.c')

    def test_create_thread_id_wiring(self):
        joined = '\n'.join(added_lines('dlls/winedmo/media_source.c', WINEDMO_SEEK_PATCH)
                           + added_lines('dlls/winedmo/wm_reader.c', WINEDMO_SEEK_PATCH))
        self.assertRegex(joined, r'&object->demux_thread_id')
        self.assertRegex(joined, r'&reader->demux_thread_id')


if __name__ == '__main__':
    unittest.main()
