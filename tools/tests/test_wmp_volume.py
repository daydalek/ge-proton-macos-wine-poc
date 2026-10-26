# SPDX-License-Identifier: LGPL-2.1-or-later
"""Exercise the WMP volume setter from the published patch, silently."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VolumeTests(unittest.TestCase):
    def test_percentage_to_decibels_and_cached_settings(self):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler required')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch = (ROOT / 'patches/crossover/wmp-volume-decibels.patch').read_text()
            # Keep the added and context lines of the complete setter hunk.
            source = '\n'.join(line[1:] for line in patch.splitlines()
                               if line.startswith((' ', '+')) and not line.startswith('+++'))
            function = re.search(r'static HRESULT WINAPI WMPSettings_put_volume\([^)]*\)\n\{.*?\n\}',
                                 source, re.S).group()
            harness = root / 'volume.c'
            harness.write_text(PREAMBLE + function + CASES)
            binary = root / 'volume'
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(harness), '-lm', '-o', str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True)


PREAMBLE = r'''
#include <assert.h>
#include <math.h>
#include <stdlib.h>
typedef long LONG;
typedef int HRESULT;
#define WINAPI
#define S_OK 0
#define S_FALSE 1
#define E_INVALIDARG (-1)
#define TRACE(...) ((void)0)
typedef struct { void *filter_graph, *basic_audio; LONG volume; } WindowsMediaPlayer;
typedef WindowsMediaPlayer IWMPSettings;
#define impl_from_IWMPSettings(iface) (iface)
static LONG captured;
static unsigned calls;
static HRESULT IBasicAudio_put_Volume(void *audio, LONG volume)
{
    assert(audio);
    captured = volume;
    ++calls;
    return S_OK;
}
'''

CASES = r'''
int main(void)
{
    WindowsMediaPlayer player = {0};
    assert(WMPSettings_put_volume(&player, 19) == S_OK);
    assert(player.volume == 19 && calls == 0);
    player.filter_graph = &player;
    assert(WMPSettings_put_volume(&player, 19) == S_FALSE);
    player.basic_audio = &player;
    assert(WMPSettings_put_volume(&player, 0) == S_OK && captured == -10000);
    assert(WMPSettings_put_volume(&player, 100) == S_OK && captured == 0);
    assert(WMPSettings_put_volume(&player, 19) == S_OK && labs(captured + 1442) <= 1);
    assert(WMPSettings_put_volume(&player, 50) == S_OK && labs(captured + 602) <= 1);
    LONG previous = -10000;
    for (LONG volume = 1; volume <= 100; ++volume)
    {
        assert(WMPSettings_put_volume(&player, volume) == S_OK);
        assert(captured > previous && captured <= 0);
        assert(player.volume == volume);
        previous = captured;
    }
    unsigned before = calls;
    assert(WMPSettings_put_volume(&player, -1) == E_INVALIDARG);
    assert(WMPSettings_put_volume(&player, 101) == E_INVALIDARG);
    assert(player.volume == 100 && calls == before);
    return 0;
}
'''
