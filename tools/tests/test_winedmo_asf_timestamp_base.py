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


def extract_patched_components():
    base_text = BASE_PATCH.read_text()
    marker = '+++ b/dlls/winedmo/unix_demuxer.c\n@@ '
    start = base_text.index(marker) + len(marker)
    hunk_start = base_text.index('\n', start) + 1
    end = base_text.index('\ndiff --git ', hunk_start)
    demuxer_text = '\n'.join(
        line[1:] for line in base_text[hunk_start:end].splitlines()
        if line.startswith((' ', '+'))
    ) + '\n'

    patch_lines = FIX_PATCH.read_text().splitlines()
    hunk_indices = [i for i, line in enumerate(patch_lines) if line.startswith('@@ ')]
    for pos, h_idx in enumerate(hunk_indices):
        next_idx = hunk_indices[pos + 1] if pos + 1 < len(hunk_indices) else len(patch_lines)
        body = patch_lines[h_idx + 1:next_idx]
        old_block = '\n'.join(line[1:] for line in body if line.startswith((' ', '-')))
        new_block = '\n'.join(line[1:] for line in body if line.startswith((' ', '+')))
        if old_block not in demuxer_text:
            raise AssertionError(f'Fix patch hunk {pos} context not found')
        demuxer_text = demuxer_text.replace(old_block, new_block, 1)

    struct_start = demuxer_text.index('{\n    AVBSFContext *filter;\n')
    struct_end = demuxer_text.index('\n};\n', struct_start) + len('\n};\n')
    fn_start = demuxer_text.index('enum asf_timestamp_base_mode\n{\n')
    fn_end = demuxer_text.index('\n}\n', demuxer_text.index('static void normalize_stream_timestamps')) + len('\n}\n')
    return 'struct stream\n' + demuxer_text[struct_start:struct_end] + '\n' + demuxer_text[fn_start:fn_end]


PREAMBLE = r'''
#define _POSIX_C_SOURCE 200112L
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int BOOL;
typedef unsigned int UINT;
typedef int64_t INT64;
typedef void AVBSFContext;
#define TRUE 1
#define FALSE 0
#define AV_NOPTS_VALUE ((INT64)INT64_MIN)
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))

struct sample {
    INT64 pts;
    INT64 dts;
};
'''

CASES = r'''
int main(void)
{
    unsetenv("WINE_DMO_ASF_TIMESTAMP_BASE");

    /* Auto mode, normal 30fps ASF/WMV stream starting at pts=0: crossing 200ms at
     * frame 7 (2330000 > 2000000) in a 33ms step locks timestamp_base = 0 instead
     * of jumping pts backward to 0 mid-stream before a P-frame. */
    struct stream s = {0};
    const INT64 frames[] = {0, 330000, 660000, 1000000, 1330000, 1660000, 2000000, 2330000, 2670000, 3000000};
    for (size_t i = 0; i < sizeof(frames) / sizeof(frames[0]); ++i)
    {
        struct sample smp = {frames[i], AV_NOPTS_VALUE};
        normalize_stream_timestamps(&s, &smp);
        assert(smp.pts == frames[i]);
        if (frames[i] <= 2000000)
        {
            assert(s.timestamp_base_set == FALSE);
            assert(s.timestamp_base_candidate_set == TRUE);
            assert(s.timestamp_base_candidate == frames[i]);
        }
        else
        {
            assert(s.timestamp_base_set == TRUE);
            assert(s.timestamp_base == 0);
        }
    }

    /* Auto mode, stream whose first timestamped sample starts late (>200ms)
     * must still rebase all samples to zero. */
    struct stream late = {0};
    struct sample l0 = {5000000, AV_NOPTS_VALUE};
    struct sample l1 = {5330000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&late, &l0);
    normalize_stream_timestamps(&late, &l1);
    assert(late.timestamp_base_set == TRUE);
    assert(late.timestamp_base == 5000000);
    assert(l0.pts == 0);
    assert(l1.pts == 330000);

    /* Auto mode, leading small packet (<=200ms) followed by a >200ms single-step
     * startup jump (e.g. preroll / superframe delay) must still rebase to 0 so
     * A/V timelines stay aligned. */
    struct stream jump = {0};
    struct sample j0 = {0, AV_NOPTS_VALUE};
    struct sample j1 = {15780000, AV_NOPTS_VALUE};
    struct sample j2 = {17180000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&jump, &j0);
    assert(jump.timestamp_base_set == FALSE);
    assert(j0.pts == 0);
    normalize_stream_timestamps(&jump, &j1);
    assert(jump.timestamp_base_set == TRUE);
    assert(jump.timestamp_base == 15780000);
    assert(j1.pts == 0);
    normalize_stream_timestamps(&jump, &j2);
    assert(j2.pts == 1400000);

    /* Leading AV_NOPTS_VALUE packet defers candidate tracking until first timestamp. */
    struct stream nopts = {0};
    struct sample p0 = {AV_NOPTS_VALUE, AV_NOPTS_VALUE};
    struct sample p1 = {100000, AV_NOPTS_VALUE};
    struct sample p2 = {1800000, AV_NOPTS_VALUE};
    struct sample p3 = {2100000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&nopts, &p0);
    assert(nopts.timestamp_base_set == FALSE);
    assert(nopts.timestamp_base_candidate_set == FALSE);
    normalize_stream_timestamps(&nopts, &p1);
    normalize_stream_timestamps(&nopts, &p2);
    normalize_stream_timestamps(&nopts, &p3);
    assert(nopts.timestamp_base_set == TRUE);
    assert(nopts.timestamp_base == 0);
    assert(p3.pts == 2100000);

    /* Overflow-safe large negative initial DTS followed by >200ms timestamp. */
    struct stream neg = {0};
    struct sample n0 = {AV_NOPTS_VALUE, INT64_MIN + 10};
    struct sample n1 = {2000001, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&neg, &n0);
    normalize_stream_timestamps(&neg, &n1);
    assert(neg.timestamp_base_set == TRUE);
    assert(neg.timestamp_base == 2000001);
    assert(n1.pts == 0);

    /* Explicit override: WINE_DMO_ASF_TIMESTAMP_BASE=first locks on pkt 0 even
     * across a >200ms jump. */
    setenv("WINE_DMO_ASF_TIMESTAMP_BASE", "first", 1);
    struct stream s_first = {0};
    struct sample f0 = {0, AV_NOPTS_VALUE};
    struct sample f1 = {15780000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&s_first, &f0);
    assert(s_first.timestamp_base_set == TRUE);
    assert(s_first.timestamp_base == 0);
    normalize_stream_timestamps(&s_first, &f1);
    assert(f1.pts == 15780000);

    /* Explicit override: WINE_DMO_ASF_TIMESTAMP_BASE=legacy restores original
     * rebasing on 30fps streams crossing 200ms. */
    setenv("WINE_DMO_ASF_TIMESTAMP_BASE", "legacy", 1);
    struct stream s_leg = {0};
    struct sample g0 = {2000000, AV_NOPTS_VALUE};
    struct sample g1 = {2330000, AV_NOPTS_VALUE};
    normalize_stream_timestamps(&s_leg, &g0);
    assert(s_leg.timestamp_base_set == FALSE);
    normalize_stream_timestamps(&s_leg, &g1);
    assert(s_leg.timestamp_base_set == TRUE);
    assert(s_leg.timestamp_base == 2330000);
    assert(g1.pts == 0);
    unsetenv("WINE_DMO_ASF_TIMESTAMP_BASE");

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
        src.write_text(PREAMBLE + '\n' + extract_patched_components() + '\n' + CASES)
        subprocess.run([self.compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(src), '-o', str(binary)], check=True, capture_output=True)
        res = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10,
                             env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn('ALL PASS', res.stdout)


if __name__ == '__main__':
    unittest.main()
