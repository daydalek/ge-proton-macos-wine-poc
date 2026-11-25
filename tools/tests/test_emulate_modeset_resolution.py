# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless regression test for the EmulateModeset "WxH" resolution pin.

Verifies patches/crossover/macos-emulate-modeset-resolution.patch in the
CrossOver patch series and compiles the extracted parse/apply helpers into a
standalone C harness with ASan/UBSan.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERIES = ROOT / 'configs/crossover-patch-series.txt'
FIX_PATCH = ROOT / 'patches/crossover/macos-emulate-modeset-resolution.patch'
CLIP_PATCH = ROOT / 'patches/crossover/macos-mouse-capture-and-fullscreen-clip.patch'


def extract_helpers() -> str:
    text = FIX_PATCH.read_text()
    marker = '+/* An "WxH" value in EmulateModeset'
    start = text.index(marker)
    end = text.index('static BOOL write_source_mode', start)
    lines = []
    for line in text[start:end].splitlines():
        if line.startswith(('+', ' ')):
            lines.append(line[1:])
    return '\n'.join(lines) + '\n'


HARNESS_PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int BOOL;
typedef unsigned int UINT;
typedef unsigned long DWORD;

#define TRUE 1
#define FALSE 0

#define DM_BITSPERPEL        0x00040000
#define DM_PELSWIDTH         0x00080000
#define DM_PELSHEIGHT        0x00100000
#define DM_POSITION          0x00000020
#define DM_DISPLAYFREQUENCY  0x00400000

typedef struct _devicemodeW {
    unsigned short dmSize;
    DWORD dmFields;
    DWORD dmBitsPerPel;
    DWORD dmPelsWidth;
    DWORD dmPelsHeight;
    DWORD dmDisplayFrequency;
    struct { long x, y; } dmPosition;
} DEVMODEW;

static BOOL emulate_modeset;
static DWORD emulate_modeset_width, emulate_modeset_height;
'''

HARNESS_MAIN = r'''
int main(void)
{
    DEVMODEW mode, fallback;
    const char *bad_values[] = {
        "y", "Y", "0", "1", "on", "off", "auto",
        "1280", "x720", "1280x", "1280x0", "0x720",
        "1280x720abc", "1280 x720", "", NULL
    };
    int i;

    /* --- parsing --- */
    emulate_modeset_width = emulate_modeset_height = 0;
    assert(parse_emulate_modeset_dim("1280x720") == TRUE);
    assert(emulate_modeset_width == 1280 && emulate_modeset_height == 720);

    emulate_modeset_width = emulate_modeset_height = 0;
    assert(parse_emulate_modeset_dim("1024X768") == TRUE);
    assert(emulate_modeset_width == 1024 && emulate_modeset_height == 768);

    for (i = 0; bad_values[i]; i++)
    {
        emulate_modeset_width = 7; emulate_modeset_height = 9;
        assert(parse_emulate_modeset_dim(bad_values[i]) == FALSE);
        assert(emulate_modeset_width == 7 && emulate_modeset_height == 9);
    }

    /* --- apply_forced_emulate_mode --- */
    emulate_modeset = TRUE;
    emulate_modeset_width = 1280; emulate_modeset_height = 720;

    /* valid current mode gets dims overridden, fallback untouched */
    mode = (DEVMODEW){ .dmSize = sizeof(mode), .dmFields = DM_POSITION | DM_BITSPERPEL,
                       .dmBitsPerPel = 32, .dmPelsWidth = 1470, .dmPelsHeight = 956 };
    fallback = mode;
    apply_forced_emulate_mode(&mode, &fallback);
    assert(mode.dmPelsWidth == 1280 && mode.dmPelsHeight == 720);
    assert(mode.dmFields & DM_PELSWIDTH && mode.dmFields & DM_PELSHEIGHT);
    assert(mode.dmBitsPerPel == 32);
    assert(fallback.dmPelsWidth == 1470 && fallback.dmPelsHeight == 956);

    /* empty current + fallback: takes fallback fields then forces dims */
    memset(&mode, 0, sizeof(mode));
    apply_forced_emulate_mode(&mode, &fallback);
    assert(mode.dmPelsWidth == 1280 && mode.dmPelsHeight == 720);
    assert(mode.dmBitsPerPel == 32);

    /* empty current, no fallback: stays empty */
    memset(&mode, 0, sizeof(mode));
    apply_forced_emulate_mode(&mode, NULL);
    assert(mode.dmPelsWidth == 0 && mode.dmPelsHeight == 0);

    /* detached mode + fallback: replaced by fallback then forced */
    memset(&mode, 0, sizeof(mode));
    mode.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
    apply_forced_emulate_mode(&mode, &fallback);
    assert(mode.dmPelsWidth == 1280 && mode.dmPelsHeight == 720);

    /* emulation disabled: no-op even with dims set */
    emulate_modeset = FALSE;
    mode = (DEVMODEW){ .dmPelsWidth = 1470, .dmPelsHeight = 956 };
    apply_forced_emulate_mode(&mode, &fallback);
    assert(mode.dmPelsWidth == 1470 && mode.dmPelsHeight == 956);
    emulate_modeset = TRUE;

    /* no forced dims: no-op */
    emulate_modeset_width = emulate_modeset_height = 0;
    apply_forced_emulate_mode(&mode, &fallback);
    assert(mode.dmPelsWidth == 1470 && mode.dmPelsHeight == 956);

    puts("emulate-modeset-resolution harness: PASS");
    return 0;
}
'''


class EmulateModesetResolutionTest(unittest.TestCase):
    def test_series_entry(self):
        entries = [line.strip() for line in SERIES.read_text().splitlines()
                   if line.strip() and not line.startswith('#')]
        self.assertIn('patches/crossover/macos-emulate-modeset-resolution.patch', entries)
        # The patch edits the WINE_EMULATE_MODESET block introduced by the
        # mouse-clip patch, so it must come after it in the series.
        self.assertGreater(
            entries.index('patches/crossover/macos-emulate-modeset-resolution.patch'),
            entries.index('patches/crossover/macos-mouse-capture-and-fullscreen-clip.patch'))

    def test_helpers_behavior(self):
        cc = shutil.which('clang') or shutil.which('cc')
        if not cc:
            self.skipTest('clang not found')
        source = HARNESS_PREAMBLE + extract_helpers() + HARNESS_MAIN
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'harness.c'
            exe = Path(tmp) / 'harness'
            src.write_text(source)
            subprocess.run(
                [cc, '-std=c99', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                 '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)],
                check=True, capture_output=True, text=True)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn('PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
