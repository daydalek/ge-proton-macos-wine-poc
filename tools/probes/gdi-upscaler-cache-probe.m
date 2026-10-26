/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Window-free state-machine regression. MetalFX is a controlled test double
 * here; Real-CUGAN uses the actual native library and official CPU model. */
#import "cocoa_upscaler.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@implementation WineSpatialScaler
+ (BOOL) enabled { return YES; }
- (CGImageRef) copyScaledImage:(CGImageRef)image width:(NSUInteger)width height:(NSUInteger)height
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef testBitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    assert(testBitmap);
    CGContextDrawImage(testBitmap, CGRectMake(0, 0, width, height), image);
    CGImageRef result = CGBitmapContextCreateImage(testBitmap);
    CGContextRelease(testBitmap);
    return result;
}
@end

static double testClock = 10;
@interface ClockUpscaler : WineGDIUpscaler
@end
@implementation ClockUpscaler
- (NSTimeInterval) frameTime { return testClock; }
@end

static CGImageRef make_image(unsigned width, unsigned height, BOOL changed)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    assert(bitmap);
    unsigned char *pixels = CGBitmapContextGetData(bitmap);
    for (unsigned y = 0; y < height; ++y)
        for (unsigned x = 0; x < width; ++x)
        {
            unsigned char *p = pixels + (y * width + x) * 4;
            p[0] = 50; p[1] = 110; p[2] = 180; p[3] = 255;
        }
    if (changed) pixels[((size_t)width * height - 1) * 4] ^= 1;
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return image;
}

static void wait_callbacks(NSUInteger *count, NSUInteger target)
{
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 10;
    while (*count < target && CFAbsoluteTimeGetCurrent() < deadline)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(*count >= target);
}

static void test_fast_cache(void)
{
    WineGDIUpscaler *upscaler = [[WineGDIUpscaler alloc] init];
    CGImageRef first = make_image(24, 24, NO);
    CGImageRef changed = make_image(24, 24, YES);
    CGImageRef scaled = [upscaler copyScaledImage:first width:64 height:64 needsDisplay:nil];
    assert(scaled);
    CGImageRelease(scaled);
    for (unsigned i = 0; i < 100; ++i)
    {
        scaled = [upscaler copyScaledImage:first width:64 height:64 needsDisplay:nil];
        assert(scaled); CGImageRelease(scaled);
    }
    assert(upscaler.fastInferenceCount == 1 && upscaler.cacheHitCount == 100);
    scaled = [upscaler copyScaledImage:changed width:64 height:64 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.fastInferenceCount == 2);
    CGImageRef shape = make_image(18, 32, NO);
    scaled = [upscaler copyScaledImage:shape width:64 height:64 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    /* Identical byte count and output shape, different input geometry. */
    scaled = [upscaler copyScaledImage:first width:64 height:64 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.fastInferenceCount == 4);
    assert(![upscaler copyScaledImage:first width:24 height:24 needsDisplay:nil]);
    CGImageRelease(first); CGImageRelease(changed); CGImageRelease(shape);
    [upscaler release];
}

static void test_neural_cache(void)
{
    WineGDIUpscaler *upscaler = [[WineGDIUpscaler alloc] init];
    __block NSUInteger callbacks = 0;
    void (^redraw)(void) = ^{ ++callbacks; };
    CGImageRef first = make_image(24, 24, NO), changed = make_image(24, 24, YES);
    assert(![upscaler copyScaledImage:first width:48 height:48 needsDisplay:redraw]);
    for (unsigned i = 0; i < 100; ++i)
        assert(![upscaler copyScaledImage:first width:48 height:48 needsDisplay:redraw]);
    assert(![upscaler copyScaledImage:changed width:48 height:48 needsDisplay:redraw]);
    assert(upscaler.neuralInferenceCount == 1);
    wait_callbacks(&callbacks, 1);
    /* Completed first-frame inference stays hidden for the changed frame. */
    assert(![upscaler copyScaledImage:changed width:48 height:48 needsDisplay:redraw]);
    assert(upscaler.neuralInferenceCount == 2);
    wait_callbacks(&callbacks, 2);
    for (unsigned i = 0; i < 100; ++i)
    {
        CGImageRef scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:redraw];
        assert(scaled); CGImageRelease(scaled);
    }
    assert(upscaler.neuralInferenceCount == 2 && upscaler.cacheHitCount == 100);
    assert(![upscaler copyScaledImage:changed width:47 height:47 needsDisplay:redraw]);
    wait_callbacks(&callbacks, 3);
    CGImageRef resizedOutput = [upscaler copyScaledImage:changed width:47 height:47 needsDisplay:redraw];
    assert(resizedOutput && CGImageGetWidth(resizedOutput) == 47);
    CGImageRelease(resizedOutput);
    CGImageRef resized = make_image(23, 25, NO);
    assert(![upscaler copyScaledImage:resized width:46 height:50 needsDisplay:redraw]);
    wait_callbacks(&callbacks, 4);
    CGImageRef scaled = [upscaler copyScaledImage:resized width:46 height:50 needsDisplay:redraw];
    assert(scaled && CGImageGetWidth(scaled) == 46 && CGImageGetHeight(scaled) == 50);
    CGImageRelease(scaled);
    CGImageRelease(first); CGImageRelease(changed); CGImageRelease(resized);
    [upscaler release];
}

static void test_adaptive(void)
{
    ClockUpscaler *upscaler = [[ClockUpscaler alloc] init];
    __block NSUInteger callbacks = 0;
    CGImageRef first = make_image(24, 24, NO), changed = make_image(24, 24, YES);
    CGImageRef scaled = [upscaler copyScaledImage:first width:48 height:48 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.neuralInferenceCount == 0 && upscaler.fastInferenceCount == 1);
    testClock = 10.3;
    scaled = [upscaler copyScaledImage:first width:48 height:48 needsDisplay:^{ ++callbacks; }];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.neuralInferenceCount == 1);
    testClock = 10.31;
    scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.fastInferenceCount == 2 && upscaler.neuralInferenceCount == 1);
    wait_callbacks(&callbacks, 1);
    testClock = 10.4;
    scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.neuralInferenceCount == 1);
    testClock = 10.6;
    scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:^{ ++callbacks; }];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.neuralInferenceCount == 2);
    wait_callbacks(&callbacks, 2);
    for (unsigned i = 0; i < 100; ++i)
    {
        scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:nil];
        assert(scaled); CGImageRelease(scaled);
    }
    assert(upscaler.neuralInferenceCount == 2 && upscaler.fastInferenceCount == 2);
    CGImageRelease(first); CGImageRelease(changed);
    [upscaler release];

    /* A static GDI window still receives a timer-driven redraw when it stops
     * painting. This check uses the actual monotonic clock and main queue. */
    WineGDIUpscaler *timer = [[WineGDIUpscaler alloc] init];
    first = make_image(24, 24, NO);
    callbacks = 0;
    scaled = [timer copyScaledImage:first width:48 height:48 needsDisplay:^{ ++callbacks; }];
    assert(scaled); CGImageRelease(scaled);
    wait_callbacks(&callbacks, 1);
    scaled = [timer copyScaledImage:first width:48 height:48 needsDisplay:^{ ++callbacks; }];
    assert(scaled); CGImageRelease(scaled);
    assert(timer.neuralInferenceCount == 1);
    wait_callbacks(&callbacks, 2);
    scaled = [timer copyScaledImage:first width:48 height:48 needsDisplay:nil];
    assert(scaled); CGImageRelease(scaled);
    assert(timer.neuralInferenceCount == 1);
    CGImageRelease(first);
    [timer release];

    ClockUpscaler *animated = [[ClockUpscaler alloc] init];
    for (unsigned i = 0; i < 100; ++i)
    {
        testClock = 20 + i * 0.01;
        first = make_image(24, 24, i % 2);
        scaled = [animated copyScaledImage:first width:48 height:48 needsDisplay:nil];
        assert(scaled); CGImageRelease(scaled); CGImageRelease(first);
    }
    assert(animated.neuralInferenceCount == 0 && animated.fastInferenceCount == 100);
    [animated release];
}

static void test_missing_backend(BOOL adaptive)
{
    ClockUpscaler *upscaler = [[ClockUpscaler alloc] init];
    CGImageRef first = make_image(24, 24, NO);
    __block NSUInteger callbacks = 0;
    void (^firstRedraw)(void) = nil;
    if (!adaptive) firstRedraw = ^{ ++callbacks; };
    CGImageRef scaled = [upscaler copyScaledImage:first width:48 height:48 needsDisplay:firstRedraw];
    if (adaptive) { assert(scaled); CGImageRelease(scaled); testClock = 11; }
    else assert(!scaled);
    if (adaptive)
    {
        scaled = [upscaler copyScaledImage:first width:48 height:48 needsDisplay:^{ ++callbacks; }];
        assert(scaled); CGImageRelease(scaled);
        wait_callbacks(&callbacks, 1);
    }
    else
    {
        wait_callbacks(&callbacks, 1);
    }
    for (unsigned i = 0; i < 100; ++i)
    {
        scaled = [upscaler copyScaledImage:first width:48 height:48 needsDisplay:nil];
        if (adaptive) { assert(scaled); CGImageRelease(scaled); }
        else assert(!scaled);
    }
    assert(upscaler.neuralInferenceCount == 1);
    CGImageRelease(first);
    [upscaler release];
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        assert(argc == 2);
        if (!strcmp(argv[1], "disabled")) assert(![WineGDIUpscaler enabled]);
        else if (!strcmp(argv[1], "fast")) test_fast_cache();
        else if (!strcmp(argv[1], "neural")) test_neural_cache();
        else if (!strcmp(argv[1], "adaptive")) test_adaptive();
        else if (!strcmp(argv[1], "failure")) test_missing_backend(NO);
        else if (!strcmp(argv[1], "adaptive-failure")) test_missing_backend(YES);
        else assert(0);
        puts("PASS: GDI frame cache and presentation policy");
    }
}
