/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Window-free state-machine regression. MetalFX is a controlled test double
 * here; Real-CUGAN uses the actual native library and official CPU model. */
#import "cocoa_upscaler.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSUInteger spatialInstances;
@implementation WineSpatialScaler
+ (BOOL) enabled { return YES; }
- (id) init { if ((self = [super init])) ++spatialInstances; return self; }
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

/* Seed a visibly distinct completed neural image and keep the worker busy.
 * This tests presentation independently of model quality and inference time. */
@interface CompositeUpscaler : WineGDIUpscaler
- (void) seed:(CGImageRef)source width:(NSUInteger)width height:(NSUInteger)height;
@end
@implementation CompositeUpscaler
- (void) seed:(CGImageRef)source width:(NSUInteger)width height:(NSUInteger)height
{
    NSUInteger iw = CGImageGetWidth(source), ih = CGImageGetHeight(source);
    NSMutableData *pixels = [NSMutableData dataWithLength:iw * ih * 4];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(pixels.mutableBytes, iw, ih, 8, iw * 4, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, iw, ih), source);
    resultInput = [pixels copy];
    CGContextRelease(bitmap);
    bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    unsigned char *bytes = CGBitmapContextGetData(bitmap);
    for (NSUInteger i = 0; i < width * height; ++i)
    { bytes[i*4] = 200; bytes[i*4+1] = 100; bytes[i*4+2] = 20; bytes[i*4+3] = 255; }
    result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap); CGColorSpaceRelease(space);
    resultWidth = iw; resultHeight = ih;
    resultOutputWidth = width; resultOutputHeight = height;
    inFlight = YES;
}
@end

static void test_composite(void)
{
    for (unsigned fractional = 0; fractional < 2; ++fractional)
    {
        unsigned width = 512 - fractional, height = 384 - fractional;
        CompositeUpscaler *upscaler = [[CompositeUpscaler alloc] init];
        CGImageRef first = make_image(256, 192, NO), changed = make_image(256, 192, YES);
        [upscaler seed:first width:width height:height];
        CGImageRef composite = [upscaler copyScaledImage:changed width:width height:height needsDisplay:nil];
        assert(composite);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), composite);
        const unsigned char *bytes = CGBitmapContextGetData(bitmap);
        // A stable distant patch retains neural pixels during active inference.
        assert(bytes[(16 * width + 16) * 4] == 200);
        // Changed patch displays the current frame immediately.
        assert(bytes[((height - 1) * width + width - 1) * 4] < 60);
        assert(upscaler.neuralInferenceCount == 0);
        CGContextRelease(bitmap); CGColorSpaceRelease(space); CGImageRelease(composite);
        // Reverting to the completed source restores the complete neural result.
        composite = [upscaler copyScaledImage:first width:width height:height needsDisplay:nil];
        assert(composite); CGImageRelease(composite);
        CGImageRelease(first); CGImageRelease(changed); [upscaler release];
    }
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
    scaled = [upscaler copyScaledImage:changed width:48 height:48 needsDisplay:^{ ++callbacks; }];
    assert(scaled); CGImageRelease(scaled);
    assert(upscaler.neuralInferenceCount == 2);
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

static unsigned mock_count(const char *name)
{
    void *handle = dlopen(getenv("WINE_GDI_UPSCALER_LIBRARY"), RTLD_NOW | RTLD_LOCAL);
    assert(handle);
    unsigned (*count)(void) = (unsigned (*)(void))dlsym(handle, name);
    assert(count);
    return count();
}

static void test_temporal_excluded(void)
{
    setenv("WINE_GDI_UPSCALER_EXCLUDE", "0,0,4,4", 1);
    WineGDIUpscaler *upscaler = [[WineGDIUpscaler alloc] init];
    CALayer *parent = [CALayer layer];
    CGImageRef image = make_image(4, 4, NO);
    BOOL presented = [upscaler presentImage:image inLayer:parent
        frame:CGRectMake(0, 0, 8, 8) width:8 height:8 needsDisplay:nil];
    assert(presented);
    assert(mock_count("wgdi_mock_temporal_present_count") == 1);
    assert(mock_count("wgdi_mock_temporal_cancel_count") == 0);
    CGImageRelease(image);
    [upscaler release];
    unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
}

static void test_regions(BOOL expectRegions)
{
    setenv("WGDI_MOCK_SELECTION", "1", 1);
    WineGDIUpscaler *upscaler = [[WineGDIUpscaler alloc] init];
    CALayer *parent = [CALayer layer];
    CGImageRef image = make_image(640, 480, NO);
    BOOL presented = [upscaler presentImage:image inLayer:parent
        frame:CGRectMake(0, 0, 640, 480) width:640 height:480 needsDisplay:nil];
    assert(presented);
    for (unsigned i = 0; i < 500 && !mock_count("wgdi_mock_temporal_complete_count"); ++i)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(mock_count("wgdi_mock_temporal_complete_count") == 1);
    if (expectRegions)
    {
        assert(mock_count("wgdi_mock_regions_count") == 1);
        assert(mock_count("wgdi_mock_regions_tile_count") == 6);
        assert(mock_count("wgdi_mock_regions_selected_total") == 1);
        assert(mock_count("wgdi_mock_regions_selected_first") == 1);
        assert(mock_count("wgdi_mock_process_count") == 0);
    }
    else
        assert(mock_count("wgdi_mock_process_count") == 1);
    CGImageRelease(image);
    [upscaler release];
    unsetenv("WGDI_MOCK_SELECTION");
}

static void test_adaptive_temporal(void)
{
    ClockUpscaler *upscaler = [[ClockUpscaler alloc] init];
    CALayer *parent = [CALayer layer];
    CGImageRef image = make_image(24, 24, NO);
    assert(spatialInstances == 0);
    assert([upscaler presentImage:image inLayer:parent frame:CGRectMake(0, 0, 48, 48)
        width:48 height:48 needsDisplay:nil]);
    assert(mock_count("wgdi_mock_temporal_present_count") == 1);
    assert(spatialInstances == 0);
    CGImageRef scaled = [upscaler copyScaledImage:image width:48 height:48 needsDisplay:nil];
    assert(scaled);
    CGImageRelease(scaled);
    assert(spatialInstances == 1);
    scaled = [upscaler copyScaledImage:image width:48 height:48 needsDisplay:nil];
    assert(scaled);
    CGImageRelease(scaled);
    assert(spatialInstances == 1);
    CGImageRelease(image);
    [upscaler release];
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

static CGImageRef region_image(unsigned width, unsigned height, BOOL text, BOOL outside)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    assert(bitmap);
    unsigned char *data = CGBitmapContextGetData(bitmap);
    for (unsigned y = 0; y < height; ++y)
        for (unsigned x = 0; x < width; ++x)
        {
            unsigned char *p = data + (y * width + x) * 4;
            p[0] = text && y >= height / 2 ? 90 : outside && !x && !y ? 70 : 50;
            p[1] = 110; p[2] = 180; p[3] = 255;
        }
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(space);
    return image;
}

static unsigned blue_at(CGImageRef image, unsigned x, unsigned y)
{
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    assert(data && x < CGImageGetWidth(image) && y < CGImageGetHeight(image));
    unsigned blue = CFDataGetBytePtr(data)[y * CGImageGetBytesPerRow(image) + x * 4];
    CFRelease(data);
    return blue;
}

static void test_excluded_regions(void)
{
    unsetenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
    unsetenv("WINE_GDI_UPSCALER_PICK");
    setenv("WINE_GDI_UPSCALER_EXCLUDE", "0,2,4,2", 1);
    WineGDIUpscaler *upscaler = [[WineGDIUpscaler alloc] init];
    __block NSUInteger callbacks = 0;
    void (^redraw)(void) = ^{ ++callbacks; };
    CGImageRef first = region_image(4, 4, NO, NO);
    CGImageRef text = region_image(4, 4, YES, NO);
    CGImageRef changed = region_image(4, 4, YES, YES);
    CGImageRef output = [upscaler copyScaledImage:first width:8 height:8 needsDisplay:redraw];
    assert(output && upscaler.neuralInferenceCount == 1);
    CGImageRelease(output);
    wait_callbacks(&callbacks, 1);
    output = [upscaler copyScaledImage:text width:8 height:8 needsDisplay:redraw];
    assert(output && upscaler.neuralInferenceCount == 1);
    assert(blue_at(output, 2, 1) == 82 && blue_at(output, 2, 6) == 90);
    CGImageRelease(output);
    output = [upscaler copyScaledImage:changed width:8 height:8 needsDisplay:redraw];
    assert(output && upscaler.neuralInferenceCount == 2);
    CGImageRelease(output);
    wait_callbacks(&callbacks, 2);
    setenv("WINE_GDI_UPSCALER_PICK", "off", 1);
    output = [upscaler copyScaledImage:changed width:8 height:8 needsDisplay:redraw];
    assert(output && blue_at(output, 2, 6) == 122);
    CGImageRelease(output);
    unsetenv("WINE_GDI_UPSCALER_PICK");
    output = [upscaler copyScaledImage:text width:8 height:8 needsDisplay:redraw];
    assert(output && upscaler.neuralInferenceCount == 3);
    CGImageRelease(output);
    wait_callbacks(&callbacks, 3);
    CGImageRef later = region_image(4, 4, NO, NO);
    output = [upscaler copyScaledImage:later width:8 height:8 needsDisplay:redraw];
    assert(output && upscaler.neuralInferenceCount == 3 && blue_at(output, 2, 6) == 50);
    CGImageRelease(output);
    setenv("WINE_GDI_UPSCALER_PICK", "off", 1);
    output = [upscaler copyScaledImage:later width:8 height:8 needsDisplay:redraw];
    if (output) CGImageRelease(output);
    assert(upscaler.neuralInferenceCount == 4);
    wait_callbacks(&callbacks, 4);
    unsetenv("WINE_GDI_UPSCALER_PICK");
    setenv("WINE_GDI_UPSCALER_EXCLUDE", "0,0,4,4", 1);
    output = [upscaler copyScaledImage:text width:20 height:20 needsDisplay:redraw];
    assert(output && CGImageGetWidth(output) == 20 && upscaler.neuralInferenceCount == 4);
    assert(blue_at(output, 5, 17) == 90);
    CGImageRelease(output);
    setenv("WINE_GDI_UPSCALER_EXCLUDE", "0,2,4,2", 1);
    output = [upscaler copyScaledImage:later width:20 height:20 needsDisplay:redraw];
    assert(output && CGImageGetWidth(output) == 20 && upscaler.neuralInferenceCount == 4);
    CGImageRelease(output);
    assert(![upscaler copyScaledImage:later width:SIZE_MAX height:20 needsDisplay:nil]);
    CGRect frame = wgdi_presentation_frame(640, 480, 2, NO, CGRectZero, CGRectMake(0, 0, 320, 240));
    assert(CGRectEqualToRect(frame, CGRectMake(0, 0, 320, 240)));
    frame = wgdi_presentation_frame(640, 480, 2, YES, CGRectMake(120, 0, 1200, 900),
        CGRectMake(0, 0, 1440, 900));
    assert(CGRectEqualToRect(frame, CGRectMake(120, 0, 1200, 900)));
    frame = wgdi_presentation_frame(640, 480, 2, YES, CGRectMake(75, 50, 1600, 900),
        CGRectMake(0, 0, 1800, 1000));
    assert(CGRectEqualToRect(frame, CGRectMake(275, 50, 1200, 900)));
    CGImageRelease(first); CGImageRelease(text); CGImageRelease(changed); CGImageRelease(later);
    [upscaler release];
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        assert(argc == 2);
        if (!strcmp(argv[1], "disabled")) assert(![WineGDIUpscaler enabled]);
        else if (!strcmp(argv[1], "composite")) test_composite();
        else if (!strcmp(argv[1], "excluded")) test_excluded_regions();
        else if (!strcmp(argv[1], "fast")) test_fast_cache();
        else if (!strcmp(argv[1], "neural")) test_neural_cache();
        else if (!strcmp(argv[1], "adaptive")) test_adaptive();
        else if (!strcmp(argv[1], "temporal-excluded")) test_temporal_excluded();
        else if (!strcmp(argv[1], "regions")) test_regions(YES);
        else if (!strcmp(argv[1], "regions-fallback")) test_regions(NO);
        else if (!strcmp(argv[1], "adaptive-temporal")) test_adaptive_temporal();
        else if (!strcmp(argv[1], "failure")) test_missing_backend(NO);
        else if (!strcmp(argv[1], "adaptive-failure")) test_missing_backend(YES);
        else assert(0);
        puts("PASS: GDI frame cache and presentation policy");
    }
}
