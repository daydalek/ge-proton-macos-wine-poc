/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Silent, window-free GPU checks against Wine's actual Spatial implementation.
 * Build/run instructions are in METALFX.md. Exit 77 means GPU unavailable. */
#import "cocoa_spatial.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void free_pixels(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static CGImageRef make_image(size_t width, size_t height, BOOL black)
{
    unsigned char *pixels = calloc(width * height, 4);
    assert(pixels);
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x)
        {
            unsigned char *p = pixels + (y * width + x) * 4;
            if (!black)
            {
                /* BGRA quadrants: red, green / blue, white. */
                p[0] = y >= height / 2 ? 255 : 0;
                p[1] = x >= width / 2 ? 255 : 0;
                p[2] = ((x < width / 2) == (y < height / 2)) ? 255 : 0;
            }
            p[3] = 255;
        }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, width * height * 4, free_pixels);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, FALSE, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    assert(image);
    return image;
}

static void check_image(CGImageRef image, size_t width, size_t height, BOOL black)
{
    assert(image && CGImageGetWidth(image) == width && CGImageGetHeight(image) == height);
    CFDataRef bytes = CGDataProviderCopyData(CGImageGetDataProvider(image));
    const unsigned char *pixels = CFDataGetBytePtr(bytes);
    for (unsigned quadrant = 0; quadrant < 4; ++quadrant)
    {
        size_t x = width * ((quadrant % 2) * 2 + 1) / 4;
        size_t y = height * ((quadrant / 2) * 2 + 1) / 4;
        const unsigned char *p = pixels + y * CGImageGetBytesPerRow(image) + x * 4;
        unsigned expected[3] = {quadrant >= 2 ? 255 : 0, quadrant % 2 ? 255 : 0,
                                quadrant == 0 || quadrant == 3 ? 255 : 0};
        for (unsigned channel = 0; channel < 3; ++channel)
        {
            int difference = (int)p[channel] - (black ? 0 : (int)expected[channel]);
            if (abs(difference) > 20)
                fprintf(stderr, "quadrant %u channel %u: got %u expected %u\n",
                        quadrant, channel, p[channel], black ? 0 : expected[channel]);
            assert(abs(difference) <= 20);
        }
    }
    CFRelease(bytes);
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        if (argc == 2 && !strcmp(argv[1], "disabled"))
        {
            assert(![WineSpatialScaler enabled]);
            puts("PASS: disabled option");
            return 0;
        }
        if (![WineSpatialScaler enabled]) return 77;
        WineSpatialScaler *scaler = [[WineSpatialScaler alloc] init];
        if (!scaler) return 77;
        CGImageRef original = make_image(64, 48, NO);
        assert(![scaler copyScaledImage:original width:64 height:48]);
        assert(![scaler copyScaledImage:original width:32 height:24]);
        assert(![scaler copyScaledImage:original width:128 height:48]);
        assert(![scaler copyScaledImage:original width:SIZE_MAX height:SIZE_MAX]);
        assert(![scaler copyScaledImage:NULL width:128 height:96]);
        CGImageRef first = [scaler copyScaledImage:original width:128 height:96];
        check_image(first, 128, 96, NO);

        CGImageRef black = make_image(64, 48, YES);
        for (unsigned i = 0; i < 4; ++i)
        {
            CGImageRef next = [scaler copyScaledImage:black width:128 height:96];
            check_image(next, 128, 96, YES);
            CGImageRelease(next);
        }
        check_image(first, 128, 96, NO); /* Previous Core Animation frame stays immutable. */
        CGImageRelease(first);
        CGImageRelease(black);
        CGImageRelease(original);

        original = make_image(97, 73, NO);
        first = [scaler copyScaledImage:original width:195 height:147];
        check_image(first, 195, 147, NO); /* Odd dimensions exercise padded row pitches. */
        CGImageRelease(first);
        CGImageRelease(original);

        original = make_image(800, 600, NO);
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (unsigned i = 0; i < 6; ++i)
        {
            @autoreleasepool
            {
                first = [scaler copyScaledImage:original width:1600 height:1200];
                check_image(first, 1600, 1200, NO);
                CGImageRelease(first);
            }
        }
        printf("PASS: GPU color/orientation, immutable frames, resize, odd pitch, bounds; "
               "800x600 -> 1600x1200 %.2f ms/frame (includes setup and readback)\n",
               (CFAbsoluteTimeGetCurrent() - start) * 1000 / 6);
        CGImageRelease(original);
        [scaler release];
    }
    return 0;
}
