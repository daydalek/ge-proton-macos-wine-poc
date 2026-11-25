# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless regression test for mouse capture policy and fullscreen clip sync.

Verifies patches/crossover/macos-mouse-capture-and-fullscreen-clip.patch in the
CrossOver patch series and compiles the extracted sync_window_cursor_clip()
logic into a standalone C harness with ASan/UBSan.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERIES = ROOT / 'configs/crossover-patch-series.txt'
FIX_PATCH = ROOT / 'patches/crossover/macos-mouse-capture-and-fullscreen-clip.patch'
STALE_PRESENT_PATCH = ROOT / 'patches/wine-ge/stale-present-rect.patch'


def extract_sync_window_cursor_clip() -> str:
    text = FIX_PATCH.read_text()
    marker = '+void sync_window_cursor_clip('
    start = text.index(marker)
    end_marker = '\n /**********************************************************************\n  *       NtUserGetClipCursor'
    end = text.index(end_marker, start)
    lines = []
    for line in text[start:end].splitlines():
        if line.startswith('+'):
            lines.append(line[1:])
        elif line.startswith(' '):
            lines.append(line[1:])
    return '\n'.join(lines) + '\n'


HARNESS_PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int BOOL;
typedef long LONG;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef uintptr_t HWND;

#define TRUE 1
#define FALSE 0
#define GA_PARENT 1
#define GA_ROOT 2
#define GWL_STYLE (-16)
#define WS_VISIBLE 0x10000000U
#define MDT_RAW_DPI 2

typedef struct tagRECT {
    LONG left, top, right, bottom;
} RECT;

struct window_rects {
    RECT window;
    RECT client;
    RECT visible;
};

static HWND g_desktop = 1;
static HWND g_foreground = 0;
static HWND g_parent = 1;
static HWND g_root = 0;
static DWORD g_style = WS_VISIBLE;
static RECT g_virtual = {0, 0, 1470, 956};
static RECT g_clip = {0, 0, 1470, 956};
static int g_unclipped_calls = 0;
static int g_fsclip_calls = 0;

static BOOL EqualRect(const RECT *a, const RECT *b)
{
    return a->left == b->left && a->top == b->top &&
           a->right == b->right && a->bottom == b->bottom;
}

static BOOL intersect_rect(RECT *dst, const RECT *a, const RECT *b)
{
    dst->left = a->left > b->left ? a->left : b->left;
    dst->top = a->top > b->top ? a->top : b->top;
    dst->right = a->right < b->right ? a->right : b->right;
    dst->bottom = a->bottom < b->bottom ? a->bottom : b->bottom;
    return dst->left < dst->right && dst->top < dst->bottom;
}

static HWND NtUserGetDesktopWindow(void) { return g_desktop; }
static HWND NtUserGetForegroundWindow(void) { return g_foreground; }
static HWND NtUserGetAncestor(HWND hwnd, UINT type)
{
    if (type == GA_PARENT) return g_parent;
    if (type == GA_ROOT) return g_root ? g_root : hwnd;
    return hwnd;
}
static DWORD NtUserGetWindowLongW(HWND hwnd, int idx) { (void)hwnd; (void)idx; return g_style; }
static UINT get_thread_dpi(void) { return 96; }
static RECT get_virtual_screen_rect(UINT dpi, int type) { (void)dpi; (void)type; return g_virtual; }
static BOOL get_clip_cursor(RECT *r, UINT dpi, int type) { (void)dpi; (void)type; *r = g_clip; return TRUE; }
static struct window_rects map_window_rects_virt_to_raw(struct window_rects r, UINT dpi) { (void)dpi; return r; }
#define TRACE(...) do {} while (0)

static BOOL NtUserClipCursor(const RECT *r)
{
    if (!r)
    {
        g_clip = g_virtual;
        ++g_unclipped_calls;
    }
    else g_clip = *r;
    return TRUE;
}

static BOOL clip_fullscreen_window(HWND hwnd, BOOL reset)
{
    (void)hwnd;
    (void)reset;
    ++g_fsclip_calls;
    return FALSE;
}
'''

HARNESS_MAIN = r'''
int main(void)
{
    HWND win = 100;
    g_foreground = win;
    g_root = win;
    g_parent = g_desktop;

    /* 1. Fullscreen (0,0)-(800,600) -> Windowed (378,135)-(1178,735) with stale (0,0)-(800,600) clip:
     *    must clear the stale cursor clip so the bottom-right half of the window is reachable. */
    struct window_rects fs = {{0, 0, 800, 600}, {0, 0, 800, 600}, {0, 0, 800, 600}};
    struct window_rects windowed = {{375, 106, 1181, 738}, {378, 135, 1178, 735}, {375, 106, 1181, 738}};
    g_clip = (RECT){0, 0, 800, 600};
    g_unclipped_calls = 0;
    sync_window_cursor_clip(win, &fs, &windowed);
    assert(g_unclipped_calls == 1);
    assert(EqualRect(&g_clip, &g_virtual));

    /* 2. Small 1x1 FPS mouselook trap still inside the new client rect is preserved,
     *    while a 1x1 trap left outside the moved window is cleared. */
    struct window_rects moved_far = {{900, 200, 1300, 500}, {900, 200, 1300, 500}, {900, 200, 1300, 500}};
    g_clip = (RECT){1000, 300, 1001, 301};
    g_unclipped_calls = 0;
    sync_window_cursor_clip(win, &windowed, &moved_far);
    assert(g_unclipped_calls == 0);

    g_clip = (RECT){400, 300, 401, 301};
    sync_window_cursor_clip(win, &windowed, &moved_far);
    assert(g_unclipped_calls == 1);

    /* 3. Child window geometry changes never clear top-level cursor clip. */
    g_parent = win;
    g_clip = (RECT){378, 135, 1178, 735};
    g_unclipped_calls = 0;
    sync_window_cursor_clip(200, &fs, &windowed);
    assert(g_unclipped_calls == 0);

    return 0;
}
'''


class MouseCaptureFullscreenClipTests(unittest.TestCase):
    def test_patch_series_orders_fix_after_stale_present_rect(self):
        entries = [
            line.strip() for line in SERIES.read_text().splitlines()
            if line.strip() and not line.strip().startswith('#')
        ]
        stale_rel = str(STALE_PRESENT_PATCH.relative_to(ROOT))
        fix_rel = str(FIX_PATCH.relative_to(ROOT))
        self.assertIn(stale_rel, entries)
        self.assertIn(fix_rel, entries)
        self.assertGreater(entries.index(fix_rel), entries.index(stale_rel))

    def test_patch_covers_env_overrides_present_rect_and_cocoa_confinement(self):
        patch_text = FIX_PATCH.read_text()
        self.assertIn('WINE_CLIP_CURSOR', patch_text)
        self.assertIn('WINE_EMULATE_MODESET', patch_text)
        self.assertIn('AllowClipCursor', patch_text)
        self.assertIn('WineExternalReleaseMouseCaptureNotification', patch_text)
        self.assertIn('refreshCursorClipping', patch_text)
        self.assertIn('leaving_fullscreen', patch_text)

    def test_sync_window_cursor_clip_c_harness(self):
        cc = shutil.which('clang') or shutil.which('cc')
        self.assertIsNotNone(cc, 'C compiler required')
        fn_source = extract_sync_window_cursor_clip()
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'harness.c'
            exe = Path(tmp) / 'harness'
            src.write_text(HARNESS_PREAMBLE + '\n' + fn_source + '\n' + HARNESS_MAIN)
            subprocess.run(
                [cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                 '-fsanitize=address,undefined', str(src), '-o', str(exe)],
                check=True, capture_output=True, text=True,
            )
            subprocess.run([str(exe)], check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
