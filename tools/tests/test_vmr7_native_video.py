# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless checks for the shared macdrv VMR7 native video escape protocol.

The wire format, message validation and signed-pitch row copy all live in
include/wine/macdrv_video.h as static inline helpers used by both the quartz
presenter (PE) and winemac.drv (Unix).  These tests compile that production
header directly: a sanitised host harness exercises parsing and row copying,
while i686/x86_64 Windows syntax-only compiles pin down the cross-ABI layout.
No Wine process, GUI or game is launched.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MINGW = ROOT / 'work/poc/tools/llvm-mingw-20260616-ucrt-macos-universal/bin'

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vmr7_native_sources import NATIVE_PATCH, new_file  # noqa: E402


def mingw_clang(name):
    found = shutil.which(name)
    return Path(found) if found else MINGW / name

HARNESS = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wine/macdrv_video.h"

static int failures;

#define CHECK(cond, name) \
    do { \
        if (cond) printf("PASS %s\n", name); \
        else { printf("FAIL %s\n", name); ++failures; } \
    } while (0)

static void make_header(struct macdrv_video_header *h, uint32_t command,
        uint32_t width, uint32_t height, uint32_t stride)
{
    memset(h, 0xaa, sizeof(*h));
    h->version = MACDRV_VIDEO_PROTOCOL_VERSION;
    h->command = command;
    h->token = 0x1122334455667788ULL;
    h->width = width;
    h->height = height;
    h->stride = stride;
    h->reserved = 0;
}

int main(void)
{
    const void *payload;
    uint64_t size;
    unsigned char *buf;
    uint32_t command;

    CHECK(sizeof(struct macdrv_video_header) == 32, "header size is 32");
    CHECK(offsetof(struct macdrv_video_header, token) == 8, "token at offset 8");
    CHECK(MACDRV_VIDEO_ESCAPE_ID > 0 && MACDRV_VIDEO_ESCAPE_ID <= INT32_MAX,
            "escape id fits signed int");

    /* Valid 1280x720 present. */
    {
        uint64_t pixels = 1280ull * 4 * 720;
        buf = malloc(32 + pixels);
        memset(buf + 32, 0x5a, pixels);
        make_header((struct macdrv_video_header *)buf,
                MACDRV_VIDEO_CMD_PRESENT, 1280, 720, 1280 * 4);
        payload = NULL; size = 0;
        command = macdrv_video_message_parse(buf, 32 + (uint32_t)pixels, &payload, &size);
        CHECK(command == MACDRV_VIDEO_CMD_PRESENT, "1280x720 present accepted");
        CHECK(payload == buf + 32, "payload follows header");
        CHECK(size == pixels, "payload size matches");
        CHECK(macdrv_video_message_parse(buf, 32 + (uint32_t)pixels - 1, &payload, &size) == 0,
                "truncated payload rejected");
        free(buf);
    }

    /* Valid minimal 2x2 BGRX present. */
    {
        buf = malloc(48);
        memset(buf + 32, 0, 16);
        make_header((struct macdrv_video_header *)buf,
                MACDRV_VIDEO_CMD_PRESENT, 2, 2, 8);
        CHECK(macdrv_video_message_parse(buf, 48, &payload, &size) == MACDRV_VIDEO_CMD_PRESENT
                && size == 16, "2x2 present accepted");
        free(buf);
    }

    /* Invalid geometry and framing. */
    buf = malloc(64);
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT, 0, 2, 8);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "zero width rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT, 2, 0, 8);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "zero height rejected");
    CHECK(macdrv_video_message_parse(buf, 16, &payload, &size) == 0, "short header rejected");
    CHECK(macdrv_video_message_parse(NULL, 64, &payload, &size) == 0, "null input rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT, 2, 2, 4);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0,
            "stride smaller than width*4 rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT,
            0x40000000u, 1, 0x40000000u);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0,
            "width*4 overflow rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT,
            1024, 0xffffffffu, 4096);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0,
            "payload over INT_MAX rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT,
            2, 2, 0xffffffffu);
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0,
            "huge stride rejected");
    CHECK(!macdrv_video_present_payload_size(2, 2, 0xffffffffu, &size),
            "huge stride payload rejected");
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_PRESENT, 2, 2, 8);
    ((struct macdrv_video_header *)buf)->version = 2;
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "bad version rejected");
    ((struct macdrv_video_header *)buf)->version = MACDRV_VIDEO_PROTOCOL_VERSION;
    ((struct macdrv_video_header *)buf)->command = 0;
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "command 0 rejected");
    ((struct macdrv_video_header *)buf)->command = 99;
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "command 99 rejected");
    ((struct macdrv_video_header *)buf)->command = MACDRV_VIDEO_CMD_PRESENT;
    ((struct macdrv_video_header *)buf)->reserved = 1;
    CHECK(macdrv_video_message_parse(buf, 64, &payload, &size) == 0, "reserved rejected");

    /* Header-only RELEASE is idempotent. */
    make_header((struct macdrv_video_header *)buf, MACDRV_VIDEO_CMD_RELEASE, 0, 0, 0);
    CHECK(macdrv_video_message_parse(buf, 32, &payload, &size) == MACDRV_VIDEO_CMD_RELEASE,
            "release accepted");
    CHECK(macdrv_video_message_parse(buf, 32, &payload, &size) == MACDRV_VIDEO_CMD_RELEASE,
            "release idempotent");
    CHECK(macdrv_video_message_parse(buf, 33, &payload, &size) == 0,
            "release with trailing byte rejected");
    CHECK(macdrv_video_message_parse(buf, 31, &payload, &size) == 0,
            "short release rejected");
    free(buf);

    /* Row copy, padded positive pitch: two 16-byte rows, 8 bytes live. */
    {
        unsigned char src[32], dst[32];
        memset(src, 0xaa, sizeof(src));
        for (int i = 0; i < 8; ++i) { src[i] = 0x10 + i; src[16 + i] = 0x20 + i; }
        memset(dst, 0xee, sizeof(dst));
        CHECK(macdrv_video_copy_rows(dst, src, 16, 2, 2), "padded pitch copy");
        CHECK(!memcmp(dst, src, 8), "top row copied");
        CHECK(!memcmp(dst + 8, src + 16, 8), "bottom row copied");
        CHECK(dst[16] == 0xee, "no write past payload");
    }

    /* Row copy, exact-fit tightly packed pitch (pitch == width*4). */
    {
        unsigned char src[16], dst[32];
        for (int i = 0; i < 16; ++i) src[i] = (unsigned char)(0x50 + i);
        memset(dst, 0xee, sizeof(dst));
        CHECK(macdrv_video_copy_rows(dst, src, 8, 2, 2), "exact-fit packed copy");
        CHECK(!memcmp(dst, src, 16), "packed rows copied");
        CHECK(dst[16] == 0xee, "exact-fit no write past payload");
    }

    /* Huge height/pitch rejected before any copy, dst untouched. */
    {
        unsigned char src[64], dst[16];
        memset(dst, 0xee, sizeof(dst));
        CHECK(!macdrv_video_copy_rows(dst, src, 16, 2, 0x20000000u),
                "huge height rejected");
        CHECK(dst[0] == 0xee, "huge height left dst alone");
        memset(dst, 0xee, sizeof(dst));
        CHECK(!macdrv_video_copy_rows(dst, src, 0x7ffffff0, 2, 0x20000000u),
                "huge pitch rejected");
        CHECK(dst[0] == 0xee, "huge pitch left dst alone");
    }

    /* Row copy, negative pitch: src points at the top scanline and each
     * following row sits lower in memory. */
    {
        unsigned char src[32], dst[32];
        memset(src, 0xaa, sizeof(src));
        for (int i = 0; i < 8; ++i) { src[16 + i] = 0x30 + i; src[i] = 0x40 + i; }
        memset(dst, 0xee, sizeof(dst));
        CHECK(macdrv_video_copy_rows(dst, src + 16, -16, 2, 2), "negative pitch copy");
        CHECK(!memcmp(dst, src + 16, 8), "negative pitch top row");
        CHECK(!memcmp(dst + 8, src, 8), "negative pitch bottom row");
    }

    /* Invalid pitches rejected without touching dst. */
    {
        unsigned char src[64], dst[16];
        int bad[] = { 0, -2147483647 - 1, 4, -4 };
        for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        {
            memset(dst, 0xee, sizeof(dst));
            CHECK(!macdrv_video_copy_rows(dst, src, bad[i], 2, 2), "invalid pitch rejected");
            CHECK(dst[0] == 0xee, "invalid pitch left dst alone");
        }
        memset(dst, 0xee, sizeof(dst));
        CHECK(!macdrv_video_copy_rows(dst, src, 16, 0, 2), "zero width copy rejected");
        CHECK(!macdrv_video_copy_rows(dst, src, 16, 2, 0), "zero height copy rejected");
        CHECK(!macdrv_video_copy_rows(NULL, src, 16, 2, 2), "null dst rejected");
        CHECK(!macdrv_video_copy_rows(dst, NULL, 16, 2, 2), "null src rejected");
    }

    printf("%s\n", failures ? "FAILED" : "ALL PASS");
    return failures ? 1 : 0;
}
'''

ABI_CHECK = '#include "wine/macdrv_video.h"\n'


class MacdrvVideoProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = shutil.which('clang') or shutil.which('cc')
        if not cls.compiler:
            raise unittest.SkipTest('A C compiler is required')
        if not NATIVE_PATCH.is_file():
            raise unittest.SkipTest('maintained native presentation patch not found')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        cls.include = root / 'include'
        (cls.include / 'wine').mkdir(parents=True)
        (cls.include / 'wine/macdrv_video.h').write_text(
            new_file('include/wine/macdrv_video.h'))
        cls.harness = root / 'macdrv_video_test.c'
        cls.harness.write_text(HARNESS)
        cls.binary = root / 'macdrv_video_test'
        subprocess.run([cls.compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        '-I', str(cls.include),
                        str(cls.harness), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def test_protocol_and_row_copy(self):
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        result = subprocess.run([str(self.binary)], capture_output=True, text=True,
                                timeout=30, env=env)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('ALL PASS', result.stdout)

    def test_pe_abi_i686(self):
        clang = mingw_clang('i686-w64-mingw32-clang')
        if not clang.is_file():
            self.skipTest('i686-w64-mingw32-clang not found')
        source = Path(self.temp.name) / 'abi_i686.c'
        source.write_text(ABI_CHECK)
        subprocess.run([str(clang), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                        '-I', str(self.include), str(source)],
                       check=True, capture_output=True)

    def test_pe_abi_x86_64(self):
        clang = mingw_clang('x86_64-w64-mingw32-clang')
        if not clang.is_file():
            self.skipTest('x86_64-w64-mingw32-clang not found')
        source = Path(self.temp.name) / 'abi_x86_64.c'
        source.write_text(ABI_CHECK)
        subprocess.run([str(clang), '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                        '-I', str(self.include), str(source)],
                       check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
