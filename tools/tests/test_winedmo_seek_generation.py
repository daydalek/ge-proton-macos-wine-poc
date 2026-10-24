# SPDX-License-Identifier: LGPL-2.1-or-later
"""Deterministic seek interleavings using the parser functions from the patch stack.

No media, Wine process or audio device is used. setUpClass only applies patches
and compiles; test methods execute the standalone state-transition harness.
"""
import os
import re
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PARSER = 'dlls/winedmo/winedmo_quartz_parser.c'


def function(source, name):
    match = re.search(r'^static [^\n]+\b' + re.escape(name) + r'\([^;]*?\)\n\{',
                      source, re.M)
    if match is None:
        raise ValueError('Parser function missing: ' + name)
    start, opening = match.start(), match.end() - 1
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class SeekGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('A C compiler is required')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        path = root / PARSER
        path.parent.mkdir(parents=True)
        base = (ROOT / 'patches/crossover/crossover-26.3-media.patch').read_text()
        section = base.split(f'diff --git a/{PARSER} b/{PARSER}\n', 1)[1].split('\ndiff --git ', 1)[0]
        path.write_text('\n'.join(line[1:] for line in section.splitlines()
                                  if line.startswith('+') and not line.startswith('+++')) + '\n')
        for name in ('winedmo-repeated-seek.patch', 'winedmo-seek-generation.patch'):
            subprocess.run(['git', 'apply', str(ROOT / 'patches/crossover' / name)],
                           cwd=root, check=True, capture_output=True)
        source = path.read_text()
        functions = '\n'.join(function(source, name) for name in (
            'dmo_parser_source_wait_for_video_time', 'dmo_parser_wait_for_seek_or_stop',
            'dmo_parser_source_send_eos'))
        harness = root / 'seek.c'
        harness.write_text(PREAMBLE + functions + CASES)
        cls.binary = root / 'seek'
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(harness), '-o', str(cls.binary)], check=True, capture_output=True)

    def check(self, scenario):
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        subprocess.run([str(self.binary), scenario], check=True, capture_output=True,
                       timeout=5, env=env)

    def test_seek_completed_before_eof_wait(self):
        self.check('completed-seek')

    def test_spurious_wake_then_seek_completed(self):
        self.check('spurious-wake')

    def test_stop_ends_eof_wait(self):
        self.check('stop')

    def test_old_video_packet_skips_clock_wait(self):
        self.check('stale-video')

    def test_seek_finishes_during_video_clock_wait(self):
        self.check('clock-seek')

    def test_current_video_packet_keeps_pacing(self):
        self.check('current-video')

    def test_stale_eos_cannot_end_new_segment(self):
        self.check('stale-eos')


PREAMBLE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
typedef int64_t REFERENCE_TIME;
typedef uint32_t DWORD;
typedef struct { int refs, calls; } IReferenceClock;
struct strmbase_filter { int filter_cs; IReferenceClock *clock; };
struct dmo_parser {
    struct strmbase_filter filter;
    int streaming_cs, flushing_cv;
    bool streaming, flushing;
    unsigned int read_flush_generation;
    REFERENCE_TIME stream_start;
};
struct dmo_parser_source {
    struct { struct { struct strmbase_filter *filter; void *peer; } pin; } pin;
    struct { int majortype; bool bTemporalCompression; } stream_mt;
    struct { REFERENCE_TIME llCurrent; } seek;
    int flushing_cs;
    bool eos_sent;
};
struct dmo_packet { bool has_pts; REFERENCE_TIME pts; unsigned int generation; };
static const int MEDIATYPE_Video = 1;
static struct dmo_parser *active;
static int lock_depth, waits, sleeps, eos_calls, mode;
#define INFINITE 0xffffffffu
#define FAILED(hr) ((hr) < 0)
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define WARN(...) ((void)0)
static void EnterCriticalSection(int *cs) { (void)cs; ++lock_depth; }
static void LeaveCriticalSection(int *cs) { (void)cs; assert(lock_depth > 0); --lock_depth; }
static int IsEqualGUID(const int *a, const int *b) { return *a == *b; }
static struct dmo_parser *dmo_impl_from_strmbase_filter(struct strmbase_filter *f) { return (void *)f; }
static void IReferenceClock_AddRef(IReferenceClock *c) { ++c->refs; }
static void IReferenceClock_Release(IReferenceClock *c) { --c->refs; }
static int IReferenceClock_GetTime(IReferenceClock *c, REFERENCE_TIME *now) {
    ++c->calls; assert(c->calls < 20); *now = mode == 4 ? c->calls * 50000 : 0;
    if (mode == 3) ++active->read_flush_generation;
    return 0;
}
static void Sleep(DWORD milliseconds) { assert(milliseconds <= 10); ++sleeps; assert(sleeps < 20); }
static void SleepConditionVariableCS(int *cv, int *cs, DWORD timeout) {
    (void)cv; (void)cs; (void)timeout; assert(lock_depth == 1); ++waits; assert(waits < 4);
    if (mode == 1 && waits == 2) ++active->read_flush_generation;
    if (mode == 2) active->streaming = false;
}
static void IPin_EndOfStream(void *peer) { assert(peer); ++eos_calls; }
'''

CASES = r'''
int main(int argc, char **argv) {
    struct dmo_parser f = {0}; IReferenceClock c = {0};
    struct dmo_parser_source p = {0}; struct dmo_packet pkt = {0};
    assert(argc == 2); active = &f; f.streaming = true; f.read_flush_generation = 7;
    f.filter.clock = &c; p.pin.pin.filter = &f.filter; p.pin.pin.peer = &p;
    p.stream_mt.majortype = MEDIATYPE_Video;
    pkt.has_pts = true; pkt.pts = 100000; pkt.generation = 7;
    if (!strcmp(argv[1], "completed-seek")) {
        dmo_parser_wait_for_seek_or_stop(&f, 6); assert(waits == 0);
    } else if (!strcmp(argv[1], "spurious-wake")) {
        mode = 1; dmo_parser_wait_for_seek_or_stop(&f, 7); assert(waits == 2);
    } else if (!strcmp(argv[1], "stop")) {
        mode = 2; dmo_parser_wait_for_seek_or_stop(&f, 7); assert(waits == 1);
    } else if (!strcmp(argv[1], "stale-video")) {
        pkt.generation = 6; dmo_parser_source_wait_for_video_time(&p, &pkt);
        assert(c.calls == 0 && sleeps == 0);
    } else if (!strcmp(argv[1], "clock-seek")) {
        mode = 3; dmo_parser_source_wait_for_video_time(&p, &pkt);
        assert(c.calls == 1 && sleeps == 1);
    } else if (!strcmp(argv[1], "current-video")) {
        mode = 4; dmo_parser_source_wait_for_video_time(&p, &pkt);
        assert(c.calls == 2 && sleeps == 1);
    } else if (!strcmp(argv[1], "stale-eos")) {
        dmo_parser_source_send_eos(&p, 6); assert(eos_calls == 0 && !p.eos_sent);
        dmo_parser_source_send_eos(&p, 7); assert(eos_calls == 1 && p.eos_sent);
        dmo_parser_source_send_eos(&p, 7); assert(eos_calls == 1);
    } else { assert(0); }
    assert(c.refs == 0 && lock_depth == 0); return 0;
}
'''

if __name__ == '__main__':
    if sys.argv[1:] == ['--compile-only']:
        try:
            SeekGenerationTests.setUpClass()
            print('Parser regression harness compiled; execution deferred')
        finally:
            SeekGenerationTests.doClassCleanups()
    else:
        unittest.main()
