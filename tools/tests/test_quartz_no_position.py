# SPDX-License-Identifier: LGPL-2.1-or-later
"""Compile the actual patched SetPositions body with deterministic graph stand-ins."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from test_winedmo_seek_generation import function

ROOT = Path(__file__).resolve().parents[2]


class NoPositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('A C compiler is required')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        patch = (ROOT / 'patches/linux/quartz-no-position-transition.patch').read_text()
        current = '\n'.join(line[1:] for line in patch.splitlines()
                            if line[:1] in (' ', '+') and not line.startswith('+++'))
        implementation = function(current, 'MediaSeeking_SetPositions')
        source = root / 'position.c'
        source.write_text(PREAMBLE + implementation + CASES)
        cls.binary = root / 'position'
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(source), '-o', str(cls.binary)], check=True, capture_output=True)

    def check(self, scenario):
        subprocess.run([str(self.binary), scenario], check=True, capture_output=True,
                       timeout=5, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

    def test_running_no_position_keeps_state(self):
        self.check('no-position')

    def test_return_time_still_forwards(self):
        self.check('return-time')

    def test_absolute_seek_keeps_pause_run(self):
        self.check('absolute')

    def test_stop_position_change_keeps_pause_run(self):
        self.check('stop-only')


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
typedef int64_t LONGLONG;
typedef uint32_t DWORD;
typedef int HRESULT;
typedef int BOOL;
typedef int FILTER_STATE;
#define WINAPI
#define S_OK 0
#define E_NOTIMPL (-1)
#define AM_SEEKING_NoPositioning 0
#define AM_SEEKING_AbsolutePositioning 1
#define AM_SEEKING_PositioningBitsMask 3
#define AM_SEEKING_ReturnTime 8
#define State_Running 2
#define State_Paused 1
#define SUCCEEDED(hr) ((hr) >= 0)
#define TRACE(...) ((void)0)
#define FIXME(...) ((void)0)
struct filter_graph;
typedef struct { struct filter_graph *graph; } IMediaSeeking;
struct filter { int seeking; };
struct filter_graph {
    int cs, needs_async_run, refClock;
    FILTER_STATE state;
    LONGLONG current_pos, stream_start, stream_elapsed;
    struct { struct filter items[1]; } filters;
    struct filter_graph *IMediaControl_iface;
};
static int pause_calls, run_calls, forward_calls, lock_depth;
static DWORD last_current_flags;
#define LIST_FOR_EACH_ENTRY(it,head,type,field) \
    for ((it) = (head)->items; (it) < (head)->items + 1; ++(it))
static struct filter_graph *impl_from_IMediaSeeking(IMediaSeeking *p) { return p->graph; }
static void EnterCriticalSection(int *cs) { (void)cs; ++lock_depth; }
static void LeaveCriticalSection(int *cs) { (void)cs; assert(lock_depth > 0); --lock_depth; }
static void IMediaControl_Pause(struct filter_graph **g) { ++pause_calls; (*g)->state = State_Paused; }
static void IMediaControl_Run(struct filter_graph **g) { ++run_calls; (*g)->state = State_Running; }
static void update_seeking(struct filter *f) { (void)f; }
static void IReferenceClock_GetTime(int clock, LONGLONG *time) { assert(clock); *time = 1000; }
static HRESULT IMediaSeeking_SetPositions(int seeking, LONGLONG *current,
        DWORD current_flags, LONGLONG *stop, DWORD stop_flags) {
    assert(seeking); (void)stop; (void)stop_flags;
    ++forward_calls; last_current_flags = current_flags; *current = 77;
    return S_OK;
}
'''

CASES = r'''
int main(int argc, char **argv) {
    struct filter_graph g = {0}; IMediaSeeking iface = {&g};
    LONGLONG current = 123, stop = 456;
    DWORD current_flags = AM_SEEKING_NoPositioning, stop_flags = AM_SEEKING_NoPositioning;
    assert(argc == 2); g.IMediaControl_iface = &g;
    g.state = State_Running; g.current_pos = 42; g.stream_start = 10;
    g.stream_elapsed = 9; g.refClock = 1; g.filters.items[0].seeking = 1;
    if (!strcmp(argv[1], "return-time")) current_flags = AM_SEEKING_ReturnTime;
    else if (!strcmp(argv[1], "absolute")) current_flags = AM_SEEKING_AbsolutePositioning;
    else if (!strcmp(argv[1], "stop-only")) stop_flags = AM_SEEKING_AbsolutePositioning;
    else assert(!strcmp(argv[1], "no-position"));
    assert(MediaSeeking_SetPositions(&iface, &current, current_flags, &stop, stop_flags) == S_OK);
    assert(forward_calls == 1 && last_current_flags == (current_flags | AM_SEEKING_ReturnTime));
    assert(g.state == State_Running && lock_depth == 0);
    if (current_flags == AM_SEEKING_AbsolutePositioning) {
        assert(g.current_pos == 77 && g.stream_start == 1000 && g.stream_elapsed == 0);
        assert(pause_calls == 1 && run_calls == 1);
    } else if (stop_flags == AM_SEEKING_AbsolutePositioning) {
        assert(g.current_pos == 42 && pause_calls == 1 && run_calls == 1);
    } else {
        assert(g.current_pos == 42 && g.stream_start == 10 && g.stream_elapsed == 9);
        assert(pause_calls == 0 && run_calls == 0);
    }
    if (current_flags & AM_SEEKING_ReturnTime) assert(current == 77);
    else assert(current == 123);
    return 0;
}
'''

if __name__ == '__main__':
    if sys.argv[1:] == ['--compile-only']:
        try:
            NoPositionTests.setUpClass()
            print('Quartz regression harness compiled; execution deferred')
        finally:
            NoPositionTests.doClassCleanups()
    else:
        unittest.main()
