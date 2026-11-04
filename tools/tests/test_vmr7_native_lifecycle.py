# SPDX-License-Identifier: LGPL-2.1-or-later
"""Headless lifecycle checks for the VMR7 native video surface code.

Two harnesses run the actual production code under test doubles:

1. The WineWindow(WineVMR7VideoSurfaces) category implementation is extracted
   verbatim from dlls/winemac.drv/cocoa_vmr7.h and linked against recording
   doubles for WineWindow and WineVMR7VideoSurface.  Running it under
   NSZombieEnabled proves clear removes the dictionary entry before detach,
   detaches exactly once, and destroys the surface exactly once.

2. The native-present helper functions are extracted verbatim from the
   maintained patches/crossover/quartz-vmr7-native-presentation.patch and
   linked against recording Win32 stubs; a test-only vmr7_presenter struct
   supplies just the fields those helpers use.  The checks prove RELEASE goes through the cached
   root HWND even after the video child is gone, is sent exactly once, that
   reparenting releases the old root first, and that any native failure
   (unsupported, lock, format, escape error) releases a stale frame.

No Wine process, GUI or game is launched.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vmr7_native_sources import NATIVE_PATCH, new_file, added_text  # noqa: E402

OBJC_PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

static int failures;
#define CHECK(cond, name) \
    do { \
        if (cond) printf("PASS %s\n", name); \
        else { printf("FAIL %s\n", name); ++failures; } \
    } while (0)

@class WineVMR7VideoSurface;

@interface WineWindow : NSObject
{
@public
    NSMutableDictionary* videoSurfaces;
}
@property (nonatomic) BOOL closing;
@end

@implementation WineWindow
    - (void) dealloc
    {
        [self wine_clearVideoSurfaces];
        [videoSurfaces release];
        [super dealloc];
    }
@end

@interface WineWindow (WineVMR7VideoSurfaces)
    - (BOOL) wine_presentVideoWithToken:(uint64_t)token image:(CGImageRef)image target:(CGRect)rect;
    - (void) wine_clearVideoWithToken:(uint64_t)token;
    - (void) wine_updateVideoSurfaces;
    - (void) wine_clearVideoSurfaces;
@end

static int detach_calls, dealloc_calls, detach_still_in_dict, setimage_calls;

@interface WineVMR7VideoSurface : NSObject
{
    WineWindow* parent;
    uint64_t token;
    BOOL detached;
}
    - (id) initWithParent:(WineWindow*)parentWindow token:(uint64_t)presenterToken;
    - (void) setImage:(CGImageRef)frame target:(CGRect)rect;
    - (void) updateLayout;
    - (void) detach;
@end

@implementation WineVMR7VideoSurface
    - (id) initWithParent:(WineWindow*)parentWindow token:(uint64_t)presenterToken
    {
        self = [super init];
        if (self) { parent = parentWindow; token = presenterToken; }
        return self;
    }
    - (void) setImage:(CGImageRef)frame target:(CGRect)rect { ++setimage_calls; }
    - (void) updateLayout { }
    - (void) detach
    {
        if (detached) return;
        detached = YES;
        ++detach_calls;
        if (parent && parent->videoSurfaces &&
                [parent->videoSurfaces objectForKey:
                    [NSNumber numberWithUnsignedLongLong:token]] == self)
            ++detach_still_in_dict;
    }
    - (void) dealloc { ++dealloc_calls; [super dealloc]; }
@end
'''

OBJC_MAIN = r'''
static unsigned char pixels[16];

static CGImageRef make_image(void)
{
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, 16, NULL);
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(2, 2, 8, 32, 8, colorspace,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
            provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorspace);
    CGDataProviderRelease(provider);
    return image;
}

int main(void)
{
    @autoreleasepool
    {
        WineWindow* window = [[WineWindow alloc] init];
        CGImageRef image = make_image();
        CGRect rect = CGRectMake(0, 0, 2, 2);
        NSNumber* key = [NSNumber numberWithUnsignedLongLong:42];

        CHECK(image != NULL, "test image created");
        CHECK([window wine_presentVideoWithToken:42 image:image target:rect],
                "present creates surface");
        CHECK(window->videoSurfaces.count == 1, "surface retained in dict");
        CHECK(setimage_calls == 1, "first frame applied");

        CHECK([window wine_presentVideoWithToken:42 image:image target:rect],
                "present reuses surface");
        CHECK(window->videoSurfaces.count == 1, "still one surface");
        CHECK(setimage_calls == 2, "second frame applied");

        window.closing = YES;
        CHECK(![window wine_presentVideoWithToken:43 image:image target:rect],
                "closing rejects new surface");
        CHECK(window->videoSurfaces.count == 1, "closing kept existing surface");
        window.closing = NO;

        [window wine_clearVideoWithToken:42];
        CHECK(window->videoSurfaces.count == 0, "clear removed dict entry");
        CHECK(detach_calls == 1, "clear detached once");
        CHECK(detach_still_in_dict == 0, "entry removed before detach");
        CHECK(dealloc_calls == 1, "surface destroyed exactly once");

        [window wine_clearVideoWithToken:42];
        CHECK(detach_calls == 1 && dealloc_calls == 1, "second clear is a no-op");
        [window wine_clearVideoWithToken:999];
        CHECK(detach_calls == 1 && dealloc_calls == 1, "unknown token is a no-op");

        CHECK([window wine_presentVideoWithToken:43 image:image target:rect], "token 43 presents");
        CHECK([window wine_presentVideoWithToken:44 image:image target:rect], "token 44 presents");
        CHECK(window->videoSurfaces.count == 2, "two surfaces live");
        [window release];
        CHECK(detach_calls == 3, "window teardown detached remaining surfaces");

        CGImageRelease(image);
    }
    /* Teardown surfaces were held by the allValues snapshot until the pool
     * drained; destruction has completed by now. */
    CHECK(dealloc_calls == 3, "all surfaces destroyed exactly once");
    printf("%s\n", failures ? "FAILED" : "ALL PASS");
    return failures ? 1 : 0;
}
'''

C_PREAMBLE = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include "wine/macdrv_video.h"

typedef int BOOL;
typedef int32_t HRESULT;
typedef uint32_t DWORD;
typedef uint8_t BYTE;
typedef int32_t INT;
typedef long LONG;
typedef size_t SIZE_T;
typedef uintptr_t ULONG_PTR;
typedef void *HDC;
typedef void *HWND;
typedef struct { LONG cx, cy; } SIZE;
typedef struct { int _dummy; } IVMRImagePresenter;
typedef struct { int _dummy; } IVMRSurfaceAllocator;
typedef struct { int _dummy; } IVMRWindowlessControl;
typedef struct IVMRSurfaceAllocatorNotify IVMRSurfaceAllocatorNotify;
typedef struct IDirectDraw7 IDirectDraw7;
typedef struct IDirectDrawSurface7 IDirectDrawSurface7;
typedef struct { DWORD dwFlags, dwRGBBitCount, dwRBitMask, dwGBitMask, dwBBitMask; } DDPIXELFORMAT;
typedef struct { DWORD dwSize, dwWidth, dwHeight; LONG lPitch; void *lpSurface;
                 DDPIXELFORMAT ddpfPixelFormat; } DDSURFACEDESC2;

#define TRUE 1
#define FALSE 0
#define S_OK ((HRESULT)0)
#define E_FAIL ((HRESULT)0x80004005)
#define FAILED(hr) ((HRESULT)(hr) < 0)
#define TRACE(...)
#define FIXME(...)
#define WARN(...)
#define ERR(...)
#define WINE_DEFAULT_DEBUG_CHANNEL(x)
#define DDLOCK_WAIT 1
#define DDLOCK_READONLY 0x10
#define DDPF_RGB 0x40
#define GA_ROOT 2
#define QUERYESCSUPPORT 8

static int failures;
#define CHECK(cond, name) \
    do { \
        if (cond) printf("PASS %s\n", name); \
        else { printf("FAIL %s\n", name); ++failures; } \
    } while (0)

/* Recording Win32 stubs. */
static HWND video_hwnd = (HWND)0x100;
static HWND root_hwnd = (HWND)0x200;
static HWND root_hwnd2 = (HWND)0x300;
static HWND current_root;
static int child_dead, ancestor_null;
static INT stub_query_ret = 1, stub_escape_ret = 1;
static int stub_lock_fails;
static DDSURFACEDESC2 stub_desc;
static int lock_calls, unlock_calls, getdc_calls;
#define MAX_ESCAPES 32
static int escape_calls;
static HWND escape_hwnd[MAX_ESCAPES];
static uint32_t escape_cmd[MAX_ESCAPES];

static HDC GetDC(HWND hwnd)
{
    ++getdc_calls;
    if (!hwnd) return NULL;
    if (hwnd == video_hwnd && child_dead) return NULL;
    return (HDC)hwnd;
}

static int ReleaseDC(HWND hwnd, HDC dc) { (void)hwnd; (void)dc; return 1; }

static HWND GetAncestor(HWND hwnd, int flags)
{
    (void)flags;
    if (hwnd == video_hwnd) return ancestor_null ? NULL : current_root;
    return hwnd;
}

static INT ExtEscape(HDC hdc, INT escape, INT in_count, const char *in_data,
                     INT out_count, char *out_data)
{
    int idx = escape_calls++;
    if (idx >= MAX_ESCAPES) { printf("FAIL escape log overflow\n"); ++failures; return 0; }
    escape_hwnd[idx] = (HWND)hdc;
    if (escape == QUERYESCSUPPORT)
    {
        escape_cmd[idx] = 0;
        return stub_query_ret;
    }
    escape_cmd[idx] = macdrv_video_message_parse(in_data, in_count, NULL, NULL);
    return stub_escape_ret;
    (void)out_count; (void)out_data;
}

static HRESULT stub_surface_lock(IDirectDrawSurface7 *surf, DDSURFACEDESC2 *desc)
{
    (void)surf;
    ++lock_calls;
    if (stub_lock_fails) return E_FAIL;
    *desc = stub_desc;
    return S_OK;
}

static HRESULT stub_surface_unlock(IDirectDrawSurface7 *surf)
{
    (void)surf;
    ++unlock_calls;
    return S_OK;
}

#define IDirectDrawSurface7_Lock(p, rect, desc, flags, h) stub_surface_lock(p, desc)
#define IDirectDrawSurface7_Unlock(p, rect) stub_surface_unlock(p)

/* Minimal test double for the production struct: only the fields the
 * extracted native helpers touch. */
struct vmr7_presenter
{
    HWND window;
    int native_support;
    HWND native_root;
    BYTE *native_frame;
    SIZE_T native_frame_size;
};
'''

C_MAIN = r'''
static unsigned char surf_mem[64];

static void setup_presenter(struct vmr7_presenter *p)
{
    memset(p, 0, sizeof(*p));
    p->window = video_hwnd;
    memset(&stub_desc, 0, sizeof(stub_desc));
    stub_desc.dwWidth = 2;
    stub_desc.dwHeight = 2;
    stub_desc.lPitch = 8;
    stub_desc.lpSurface = surf_mem;
    stub_desc.ddpfPixelFormat.dwFlags = DDPF_RGB;
    stub_desc.ddpfPixelFormat.dwRGBBitCount = 32;
    stub_desc.ddpfPixelFormat.dwRBitMask = 0x00ff0000;
    stub_desc.ddpfPixelFormat.dwGBitMask = 0x0000ff00;
    stub_desc.ddpfPixelFormat.dwBBitMask = 0x000000ff;
    stub_lock_fails = 0;
    stub_query_ret = 1;
    stub_escape_ret = 1;
    child_dead = 0;
    ancestor_null = 0;
    current_root = root_hwnd;
    lock_calls = unlock_calls = getdc_calls = escape_calls = 0;
}

static int find_escape(uint32_t cmd, HWND hwnd, int from)
{
    for (int i = from; i < escape_calls; ++i)
        if (escape_cmd[i] == cmd && escape_hwnd[i] == hwnd) return i;
    return -1;
}

int main(void)
{
    struct vmr7_presenter p;
    IDirectDrawSurface7 *surf = (IDirectDrawSurface7 *)0xabc;

    /* Native present success caches the root HWND. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "native present succeeds");
    CHECK(p.native_root == root_hwnd, "root hwnd cached");
    CHECK(find_escape(MACDRV_VIDEO_CMD_PRESENT, video_hwnd, 0) >= 0,
            "present escape sent via video dc");
    CHECK(p.native_frame != NULL, "frame buffer allocated");
    free(p.native_frame);

    /* RELEASE goes through the cached root once; second call is a no-op. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present before release");
    vmr7_presenter_release_native(&p);
    CHECK(p.native_root == NULL, "root cleared on release");
    CHECK(find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0) >= 0,
            "release sent via root dc");
    {
        int calls = escape_calls;
        vmr7_presenter_release_native(&p);
        CHECK(escape_calls == calls, "second release is a no-op");
    }
    free(p.native_frame);

    /* Video child dead but root alive: RELEASE still sent exactly once. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present before child death");
    child_dead = 1;
    vmr7_presenter_release_native(&p);
    CHECK(find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0) >= 0,
            "release survives dead video hwnd");
    CHECK(p.native_root == NULL, "root cleared after dead-child release");
    free(p.native_frame);

    /* Reparented video window releases the old root before presenting. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present on root1");
    current_root = root_hwnd2;
    CHECK(vmr7_presenter_try_native(&p, surf), "present on root2");
    {
        int rel = find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0);
        int pres = find_escape(MACDRV_VIDEO_CMD_PRESENT, video_hwnd, rel >= 0 ? rel + 1 : 0);
        CHECK(rel >= 0, "release sent to old root on reparent");
        CHECK(pres > rel, "old-root release precedes new present");
        CHECK(p.native_root == root_hwnd2, "root updated after reparent");
    }
    free(p.native_frame);

    /* Lock failure after a success releases the stale frame. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present before lock failure");
    stub_lock_fails = 1;
    CHECK(!vmr7_presenter_try_native(&p, surf), "lock failure reports failure");
    CHECK(find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0) >= 0,
            "stale frame released on lock failure");
    CHECK(p.native_root == NULL, "root cleared on lock failure");
    free(p.native_frame);

    /* Unsupported format releases the stale frame. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present before format failure");
    stub_desc.ddpfPixelFormat.dwRGBBitCount = 16;
    CHECK(!vmr7_presenter_try_native(&p, surf), "bad format reports failure");
    CHECK(find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0) >= 0,
            "stale frame released on format failure");
    free(p.native_frame);

    /* NULL root after prior success: no new PRESENT, old root released. */
    setup_presenter(&p);
    CHECK(vmr7_presenter_try_native(&p, surf), "present before null root");
    ancestor_null = 1;
    {
        int pres_before = find_escape(MACDRV_VIDEO_CMD_PRESENT, video_hwnd, 0);
        CHECK(!vmr7_presenter_try_native(&p, surf), "null root reports failure");
        CHECK(find_escape(MACDRV_VIDEO_CMD_RELEASE, root_hwnd, 0) >= 0,
                "old root released on null root");
        CHECK(find_escape(MACDRV_VIDEO_CMD_PRESENT, video_hwnd,
                pres_before >= 0 ? pres_before + 1 : 0) < 0,
                "no present sent with null root");
        CHECK(p.native_root == NULL, "root cleared on null root");
    }
    free(p.native_frame);

    /* Escape returning -1 (error) is failure, not success. */
    setup_presenter(&p);
    stub_escape_ret = -1;
    CHECK(!vmr7_presenter_try_native(&p, surf), "escape error reports failure");
    CHECK(p.native_root == NULL, "no root cached on escape error");
    free(p.native_frame);

    /* Unsupported driver: no lock, no escape, failure. */
    setup_presenter(&p);
    stub_query_ret = 0;
    CHECK(!vmr7_presenter_try_native(&p, surf), "unsupported reports failure");
    CHECK(lock_calls == 0, "unsupported never locked");
    CHECK(find_escape(MACDRV_VIDEO_CMD_PRESENT, video_hwnd, 0) < 0,
            "unsupported sent no present");
    CHECK(p.native_root == NULL, "unsupported cached no root");
    free(p.native_frame);

    printf("%s\n", failures ? "FAILED" : "ALL PASS");
    return failures ? 1 : 0;
}
'''


def function(source, name):
    match = re.search(r'^static [^\n]+\b' + re.escape(name) + r'\([^;]*?\)\n\{',
                      source, re.M)
    if match is None:
        raise ValueError('Function missing: ' + name)
    start, opening = match.start(), match.end() - 1
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def category_impl(source):
    match = re.search(r'^@implementation WineWindow \(WineVMR7VideoSurfaces\)\n.*?^@end',
                      source, re.M | re.S)
    if match is None:
        raise ValueError('WineVMR7VideoSurfaces implementation missing')
    return match.group(0)


@unittest.skipUnless(sys.platform == 'darwin',
                     'Objective-C Foundation harness is macOS-only')
class CocoaLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('A C compiler is required')
        if not NATIVE_PATCH.is_file():
            raise unittest.SkipTest('maintained native presentation patch not found')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        source = new_file('dlls/winemac.drv/cocoa_vmr7.h')
        harness = root / 'lifecycle.m'
        harness.write_text(OBJC_PREAMBLE + category_impl(source) + OBJC_MAIN)
        cls.binary = root / 'lifecycle'
        subprocess.run([compiler, '-g', '-O0', '-Wall', '-Wextra',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        '-framework', 'Foundation', '-framework', 'CoreGraphics',
                        str(harness), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def test_surface_lifecycle(self):
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', NSZombieEnabled='YES')
        result = subprocess.run([str(self.binary)], capture_output=True, text=True,
                                timeout=30, env=env)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ALL PASS', result.stdout)


class PresenterLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('A C compiler is required')
        if not NATIVE_PATCH.is_file():
            raise unittest.SkipTest('maintained native presentation patch not found')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        source = added_text('dlls/quartz/vmr7_presenter.c')
        extracted = '\n'.join(function(source, name) for name in (
            'vmr7_presenter_release_native', 'vmr7_presenter_native_supported',
            'vmr7_presenter_present_native', 'vmr7_presenter_try_native'))
        harness = root / 'presenter.c'
        harness.write_text(C_PREAMBLE + extracted + C_MAIN)
        include = root / 'include'
        (include / 'wine').mkdir(parents=True)
        (include / 'wine/macdrv_video.h').write_text(
            new_file('include/wine/macdrv_video.h'))
        cls.binary = root / 'presenter'
        subprocess.run([compiler, '-std=c11', '-g', '-O0', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        '-I', str(include),
                        str(harness), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def test_presenter_release_paths(self):
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        result = subprocess.run([str(self.binary)], capture_output=True, text=True,
                                timeout=30, env=env)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ALL PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
