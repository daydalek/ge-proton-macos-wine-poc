# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless regression test for ASF startup timestamp base normalization.

Extracts normalize_stream_timestamps() from crossover-26.3-media.patch, applies
patches/crossover/winedmo-asf-startup-timestamp-base.patch, and compiles the
function into a standalone C harness with ASan/UBSan.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE_PATCH = ROOT / 'patches/crossover/crossover-26.3-media.patch'
FIX_PATCH = ROOT / 'patches/crossover/winedmo-asf-startup-timestamp-base.patch'


def extract_normalize_function():
    base_text = BASE_PATCH.read_text()
    start = base_text.index('+static void normalize_stream_timestamps( struct stream *stream, struct sample *sample )\n')
    end = base_text.index('\n+}\n', start) + len('\n+}\n')
    func_lines = [line[1:] for line in base_text[start:end].splitlines()]

    patch_lines = FIX_PATCH.read_text().splitlines()
    hunk_idx = next(i for i, line in enumerate(patch_lines) if line.startswith('@@ '))
    old_block = [line[1:] for line in patch_lines[hunk_idx + 1:] if line.startswith((' ', '-'))]
    new_block = [line[1:] for line in patch_lines[hunk_idx + 1:] if line.startswith((' ', '+'))]

    func_text = '\n'.join(func_lines) + '\n'
    old_text = '\n'.join(old_block)
    new_text = '\n'.join(new_block)
    if old_text not in func_text:
        raise AssertionError('Fix patch context not found in normalize_stream_timestamps')
    return func_text.replace(old_text, new_text, 1)


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef int BOOL;
typedef int64_t INT64;
#define TRUE 1
#define FALSE 0
#define AV_NOPTS_VALUE ((INT64)INT64_MIN)
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))

struct stream {
    INT64 timestamp_base;
    BOOL timestamp_base_set;
};

struct sample {
    INT64 pts;
    INT64 dts;
};
'''

CASES = r'''
int main(void)
{
    /* Normal 30fps ASF/WMV stream starting at pts=0: crossing 200ms at frame 7
     * (2330000 > 2000000) must NOT latch timestamp_base mid-stream. */
    struct stream s = {0};
    const INT64 frames[] = {0, 330000, 660000, 1000000, 1330000, 1660000, 2000000, 2330000, 2670000, 3000000};
    for (size_t i = 0; i < sizeof(frames) / sizeof(frames[0]); ++i)
    {
        struct sample smp = {frames[i], AV_NOPTS_VALUE};
        normalize_stream_timestamps(&s, &smp);
        assert(smp.pts == frames[i]);
        assert(s.timestamp_base_set == TRUE);
        assert(s.timestamp_base == 0);
    }

    /* Stream whose first timestamped sample has a large startup offset (>200ms)
     * must still rebase all samples to zero. */
    struct stream late = {0};
    struct sample l0 = {5000000, AV_NOPTS_VALUE};
    struct sample l1 = {5330000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&late, &l0);
    normalize_stream_timestamps(&late, &l1);
    assert(l0.pts == 0);
    assert(l1.pts == 330000);

    /* Leading AV_NOPTS_VALUE packet defers latching until the first real timestamp. */
    struct stream nopts = {0};
    struct sample p0 = {AV_NOPTS_VALUE, AV_NOPTS_VALUE};
    struct sample p1 = {100000, AV_NOPTS_VALUE};
    struct sample p2 = {2500000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&nopts, &p0);
    assert(nopts.timestamp_base_set == FALSE);
    normalize_stream_timestamps(&nopts, &p1);
    assert(nopts.timestamp_base_set == TRUE);
    assert(nopts.timestamp_base == 0);
    assert(p1.pts == 100000);
    normalize_stream_timestamps(&nopts, &p2);
    assert(p2.pts == 2500000);

    printf("ALL PASS\n");
    return 0;
}
'''


class WinedmoAsfTimestampBaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BASE_PATCH.is_file() or not FIX_PATCH.is_file():
            raise unittest.SkipTest('ASF timestamp base patches not found')
        cls.compiler = shutil.which('clang') or shutil.which('cc')
        if not cls.compiler:
            raise unittest.SkipTest('A C compiler is required')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)

    def test_startup_timestamp_base_latches_once(self):
        root = Path(self.temp.name)
        src = root / 'asf_ts.c'
        binary = root / 'asf_ts'
        src.write_text(PREAMBLE + '\n' + extract_normalize_function() + '\n' + CASES)
        subprocess.run([self.compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(src), '-o', str(binary)], check=True, capture_output=True)
        res = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10,
                             env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn('ALL PASS', res.stdout)


if __name__ == '__main__':
    unittest.main()
