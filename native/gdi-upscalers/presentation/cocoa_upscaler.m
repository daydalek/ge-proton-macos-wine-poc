/*
 * Optional GDI upscaler selection and asynchronous neural presentation.
 * Copyright 2026 GE-Proton macOS Wine PoC contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#import "cocoa_upscaler.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

enum { UPSCALE_OFF = 0, UPSCALE_METALFX = 3, UPSCALE_ADAPTIVE = 4 };

static unsigned selected_algorithm(void)
{
    static unsigned selected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *mode = getenv("WINE_GDI_UPSCALER");
        if (mode)
        {
            if (!strcmp(mode, "metalfx")) selected = UPSCALE_METALFX;
            else if (!strcmp(mode, "anime4k")) selected = WGDI_ANIME4K;
            else if (!strcmp(mode, "realcugan")) selected = WGDI_REALCUGAN;
            else if (!strcmp(mode, "adaptive")) selected = UPSCALE_ADAPTIVE;
            else if (strcmp(mode, "off")) NSLog(@"Wine GDI upscaler: unknown mode; using standard presentation");
        }
        else
        {
            const char *legacy = getenv("WINE_METALFX");
            if (legacy && !strcmp(legacy, "spatial")) selected = UPSCALE_METALFX;
        }
    });
    return selected;
}

/* One global worker bounds concurrent neural inference across views. Each view
 * keeps one active job and one latest input snapshot; no frame queue grows. */
static dispatch_queue_t inference_queue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("wine.gdi.upscalers", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static wgdi_temporal_create_fn temporal_create;

static const struct wgdi_upscaler_api *backend_api(NSString **resources)
{
    static const struct wgdi_upscaler_api *api;
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (!dladdr((const void *)backend_api, &info)) return;
        NSString *driver = [NSString stringWithUTF8String:info.dli_fname];
        NSString *library = [[driver stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"libwinegdiupscalers.dylib"];
        const char *override = getenv("WINE_GDI_UPSCALER_LIBRARY");
        if (override && override[0] == '/') library = [NSString stringWithUTF8String:override];
        void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) return;
        const struct wgdi_upscaler_api *(*get_api)(uint32_t) = dlsym(handle, "wgdi_upscaler_get_api");
        if (get_api) api = get_api(WGDI_UPSCALER_ABI);
        if (api && (api->size != sizeof(*api) || api->abi_version != WGDI_UPSCALER_ABI ||
                    !api->create || !api->process || !api->destroy)) api = NULL;
        if (api) temporal_create = (wgdi_temporal_create_fn)dlsym(handle, "wine_gdi_temporal_create");
        if (api) directory = [[[library stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:@"gdi-upscalers"] copy];
        /* Keep the library loaded: worker tasks and context destructors retain
         * function pointers into it for the lifetime of the Wine process. */
    });
    if (resources) *resources = directory;
    return api;
}

/* Scheduling heuristic only: changed 64-pixel spans account for at most a
 * quarter of the image. Presentation still verifies every retained patch. */
static BOOL sparse_change(NSData *old, NSData *current, NSUInteger width, NSUInteger height)
{
    if (old.length != current.length) return NO;
    const uint8_t *a = old.bytes, *b = current.bytes;
    NSUInteger changed = 0;
    for (NSUInteger y = 0; y < height; ++y)
        for (NSUInteger x = 0; x < width; x += 64)
        {
            NSUInteger count = MIN((NSUInteger)64, width - x);
            if (memcmp(a + (y * width + x) * 4, b + (y * width + x) * 4, count * 4))
                changed += count;
            if (changed > width * height / 4) return NO;
        }
    return YES;
}

@implementation WineGDIUpscaler

+ (BOOL) enabled { return selected_algorithm() != UPSCALE_OFF; }

- (id) init
{
    self = [super init];
    if (!self) return nil;
    algorithm = selected_algorithm();
    if (algorithm == UPSCALE_METALFX || algorithm == UPSCALE_ADAPTIVE)
    {
        metalFX = [[WineSpatialScaler alloc] init];
        if (!metalFX && algorithm == UPSCALE_METALFX) { [self release]; return nil; }
    }
    const char *mode = getenv("WINE_GDI_TEMPORAL");
    if ((algorithm == WGDI_REALCUGAN || algorithm == UPSCALE_ADAPTIVE) && (!mode || strcmp(mode, "0"))) {
        NSString *resources = nil;
        backend_api(&resources);
        if (temporal_create) temporal = temporal_create(WGDI_TEMPORAL_PRESENTER_ABI, resources.fileSystemRepresentation);
    }
    return self;
}

- (void) dealloc
{
    [temporal cancel]; [temporal release];
    [metalFX release];
    [latestInput release];
    [resultInput release];
    [fastInput release];
    CGContextRelease(captureBitmap);
    [capture release];
    CGImageRelease(result);
    CGImageRelease(fastResult);
    if (context)
    {
        void *retired = context;
        const struct wgdi_upscaler_api *api = backend_api(NULL);
        dispatch_async(inference_queue(), ^{ api->destroy(retired); });
    }
    [super dealloc];
}

- (NSUInteger) inferenceCount { return inferenceCount + fastInferenceCount; }
- (NSUInteger) cacheHitCount { return cacheHitCount; }
- (NSUInteger) neuralInferenceCount { return inferenceCount; }
- (NSUInteger) fastInferenceCount { return fastInferenceCount; }

- (NSTimeInterval) frameTime { return NSProcessInfo.processInfo.systemUptime; }

- (void)hideTemporalPresentation { [[temporal layer] setHidden:YES]; }

- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height needsDisplay:(void (^)(void))redraw
{
    if (!temporal) return NO;
    WGDITemporalRequest request = ^BOOL(NSData *snapshot, NSUInteger iw, NSUInteger ih, uint64_t token) {
        if (neuralFailed) {
            [temporal completeOutput:nil token:token needsDisplay:redraw];
            return YES;
        }
        if (inFlight) return NO;
        inFlight = YES; ++inferenceCount;
        dispatch_async(inference_queue(), ^{
            @autoreleasepool {
                NSString *resources = nil;
                const struct wgdi_upscaler_api *api = backend_api(&resources);
                char error[512] = "native temporal refinement unavailable";
                if (api && !context) {
                    struct wgdi_options options = {sizeof(options), WGDI_REALCUGAN, resources.fileSystemRepresentation, 2};
                    context = api->create(&options, error, sizeof(error));
                }
                NSData *completed = nil;
                if (context) {
                    NSMutableData *output = [NSMutableData dataWithLength:iw * ih * 16];
                    struct wgdi_image input = {(uint8_t *)snapshot.bytes, snapshot.length, iw * 4, iw, ih};
                    struct wgdi_image destination = {output.mutableBytes, output.length, iw * 8, iw * 2, ih * 2};
                    if (!api->process(context, &input, &destination, error, sizeof(error))) completed = output;
                }
                NSString *message = completed ? nil : [NSString stringWithUTF8String:error];
                dispatch_async(dispatch_get_main_queue(), ^{
                    inFlight = NO;
                    if (!completed) {
                        neuralFailed = YES;
                        NSLog(@"Wine temporal: neural refinement failed (%@)", message);
                    }
                    [temporal completeOutput:completed token:token needsDisplay:redraw];
                    if (redraw) redraw();
                });
            }
        });
        return YES;
    };
    return [temporal presentImage:image inLayer:parent frame:frame width:width height:height
        request:request needsDisplay:redraw];
}

- (CGImageRef) copyFastImage:(CGImageRef)image width:(NSUInteger)width height:(NSUInteger)height
{
    if (!metalFX || fastFailed) return NULL;
    if (fastResult && fastWidth == width && fastHeight == height &&
        fastInputWidth == latestWidth && fastInputHeight == latestHeight && [fastInput isEqualToData:latestInput])
    {
        ++cacheHitCount;
        return CGImageRetain(fastResult);
    }
    ++fastInferenceCount;
    CGImageRef scaled = [metalFX copyScaledImage:image width:width height:height];
    if (!scaled) { fastFailed = YES; return NULL; }
    CGImageRelease(fastResult);
    fastResult = scaled;
    [fastInput release];
    fastInput = [latestInput retain];
    fastWidth = width; fastHeight = height;
    fastInputWidth = latestWidth; fastInputHeight = latestHeight;
    return CGImageRetain(fastResult);
}

/* Persistent neural presentation: retain matching patches while changed
 * patches show the current surface until the worker finishes. All state stays
 * on the main thread; the worker owns immutable job snapshots. */
- (CGImageRef) copyCompositeImage:(CGImageRef)image width:(NSUInteger)width height:(NSUInteger)height
{
    if (algorithm != WGDI_REALCUGAN && algorithm != UPSCALE_ADAPTIVE) return NULL;
    BOOL compatible = result && resultWidth == latestWidth && resultHeight == latestHeight &&
        resultOutputWidth == width && resultOutputHeight == height;
    if (!compatible)
        return algorithm == UPSCALE_ADAPTIVE ? [self copyFastImage:image width:width height:height] : NULL;
    const NSUInteger block = 64, halo = 18;
    const NSUInteger iw = latestWidth, ih = latestHeight;
    const uint8_t *old = resultInput.bytes, *now = latestInput.bytes;
    CGMutablePathRef retained = CGPathCreateMutable();
    NSUInteger patches = 0;
    for (NSUInteger y = 0; y < ih; y += block)
        for (NSUInteger x = 0; x < iw; x += block)
        {
            NSUInteger left = x > halo ? x - halo : 0;
            NSUInteger bottom = y > halo ? y - halo : 0;
            NSUInteger right = MIN(iw, x + block + halo), top = MIN(ih, y + block + halo);
            BOOL equal = YES;
            for (NSUInteger row = bottom; equal && row < top; ++row)
                equal = !memcmp(old + (row * iw + left) * 4, now + (row * iw + left) * 4,
                                (right - left) * 4);
            if (equal)
            {
                // Integer output edges partition the surface at fractional scales.
                NSUInteger x0 = x * width / iw, x1 = MIN(iw, x + block) * width / iw;
                NSUInteger y0 = height - MIN(ih, y + block) * height / ih;
                NSUInteger y1 = height - y * height / ih;
                CGPathAddRect(retained, NULL, CGRectMake(x0, y0, x1 - x0, y1 - y0));
                ++patches;
            }
        }
    if (!patches)
    {
        CGPathRelease(retained);
        return algorithm == UPSCALE_ADAPTIVE ? [self copyFastImage:image width:width height:height] : NULL;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(space);
    if (!bitmap) { CGPathRelease(retained); return NULL; }
    CGImageRef fast = algorithm == UPSCALE_ADAPTIVE ? [self copyFastImage:image width:width height:height] : NULL;
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationLow);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), fast ? fast : image);
    if (fast) CGImageRelease(fast);
    CGContextAddPath(bitmap, retained);
    CGContextClip(bitmap);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), result);
    CGPathRelease(retained);
    CGImageRef composite = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return composite;
}

- (void) requestStableRedisplay:(void (^)(void))needsDisplay after:(double)remaining
{
    if (stabilityTimerPending || !needsDisplay) return;
    stabilityTimerPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        stabilityTimerPending = NO;
        needsDisplay();
    });
}

- (CGImageRef) copyScaledImage:(CGImageRef)image width:(NSUInteger)width height:(NSUInteger)height
                 needsDisplay:(void (^)(void))needsDisplay
{
    NSAssert([NSThread isMainThread], @"Wine GDI upscaler presentation requires the main thread");
    if (failed || !image || algorithm == UPSCALE_OFF) return NULL;
    NSUInteger iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    if (!iw || !ih || iw > 8192 || ih > 8192 || iw * ih > 32 * 1024 * 1024 ||
        width <= iw || height <= ih || width > 8192 || height > 8192 ||
        width * height > 32 * 1024 * 1024) return NULL;
    BOOL neuralSize = iw <= 4096 && ih <= 4096 && iw * ih <= 2 * 1024 * 1024 &&
                      width <= iw * 2 && height <= ih * 2;
    if (algorithm != UPSCALE_METALFX && algorithm != UPSCALE_ADAPTIVE && !neuralSize) return NULL;
    if (iw != captureWidth || ih != captureHeight)
    {
        CGContextRelease(captureBitmap);
        [capture release];
        capture = [[NSMutableData alloc] initWithLength:iw * ih * 4];
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        captureBitmap = CGBitmapContextCreate(capture.mutableBytes, iw, ih, 8, iw * 4, space,
                                              kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(space);
        if (!captureBitmap) { failed = YES; return NULL; }
        CGContextSetBlendMode(captureBitmap, kCGBlendModeCopy);
        captureWidth = iw; captureHeight = ih;
    }
    CGContextDrawImage(captureBitmap, CGRectMake(0, 0, iw, ih), image);
    struct wgdi_image previous = {(uint8_t *)latestInput.bytes, latestInput.length,
                                  latestWidth * 4, latestWidth, latestHeight};
    struct wgdi_image current = {capture.mutableBytes, capture.length, iw * 4, iw, ih};
    BOOL frameChanged = !wgdi_frames_equal(&previous, &current);
    BOOL geometryChanged = latestOutputWidth != width || latestOutputHeight != height;
    if (frameChanged)
    {
        [latestInput release];
        latestInput = [capture copy];
    }
    latestWidth = iw; latestHeight = ih;
    latestOutputWidth = width; latestOutputHeight = height;
    if (algorithm == UPSCALE_METALFX) return [self copyFastImage:image width:width height:height];
    if (algorithm == UPSCALE_ADAPTIVE)
    {
        double remaining = wgdi_stability_observe(&stability, frameChanged || geometryChanged, [self frameTime]);
        BOOL incremental = result && resultWidth == iw && resultHeight == ih &&
            resultOutputWidth == width && resultOutputHeight == height &&
            sparse_change(resultInput, latestInput, iw, ih);
        if ((remaining > 0 && !incremental) || !neuralSize || neuralFailed)
        {
            if (neuralSize && !neuralFailed) [self requestStableRedisplay:needsDisplay after:remaining];
            return [self copyCompositeImage:image width:width height:height];
        }
    }
    /* Exact byte equality ties a completed neural image to the current Wine
     * surface. An older dialogue/frame can never be overlaid on a newer one. */
    if (result && resultWidth == iw && resultHeight == ih &&
        resultOutputWidth == width && resultOutputHeight == height &&
        [resultInput isEqualToData:latestInput])
    {
        ++cacheHitCount;
        return CGImageRetain(result);
    }
    if (inFlight)
        return [self copyCompositeImage:image width:width height:height];
    ++inferenceCount;
    inFlight = YES;
    NSData *jobInput = latestInput;
    dispatch_async(inference_queue(), ^{
        @autoreleasepool
        {
            NSString *resources = nil;
            const struct wgdi_upscaler_api *api = backend_api(&resources);
            char error[512] = "native upscaler library unavailable or ABI mismatch";
            if (api && !context)
            {
                struct wgdi_options options = {sizeof(options), algorithm == UPSCALE_ADAPTIVE ? WGDI_REALCUGAN : algorithm,
                                               resources.fileSystemRepresentation, 2};
                context = api->create(&options, error, sizeof(error));
                if (context) NSLog(@"Wine GDI upscaler: %@ initialized", algorithm == WGDI_ANIME4K ? @"Anime4K" : @"Real-CUGAN");
            }
            CGImageRef completed = NULL;
            if (context)
            {
                NSMutableData *output = [NSMutableData dataWithLength:width * height * 4];
                struct wgdi_image input = {(uint8_t *)jobInput.bytes, jobInput.length, iw * 4, iw, ih};
                struct wgdi_image destination = {output.mutableBytes, output.length, width * 4, width, height};
                if (!api->process(context, &input, &destination, error, sizeof(error)))
                {
                    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)output);
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    if (provider && colorSpace)
                        completed = CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
                            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL,
                            FALSE, kCGRenderingIntentDefault);
                    if (colorSpace) CGColorSpaceRelease(colorSpace);
                    if (provider) CGDataProviderRelease(provider);
                    if (!completed) strlcpy(error, "output CGImage allocation failed", sizeof(error));
                }
            }
            NSString *message = completed ? nil : [NSString stringWithUTF8String:error];
            dispatch_async(dispatch_get_main_queue(), ^{
                inFlight = NO;
                if (completed)
                {
                    CGImageRelease(result);
                    result = completed;
                    [resultInput release];
                    resultInput = [jobInput retain];
                    resultWidth = iw; resultHeight = ih;
                    resultOutputWidth = width; resultOutputHeight = height;
                }
                else
                {
                    if (algorithm == UPSCALE_ADAPTIVE) neuralFailed = YES;
                    else failed = YES;
                    NSString *fallback = algorithm == UPSCALE_ADAPTIVE && metalFX && !fastFailed
                        ? @"MetalFX" : @"standard GDI";
                    NSLog(@"Wine GDI upscaler: %@ failed (%@); using %@ presentation",
                          algorithm == WGDI_ANIME4K ? @"Anime4K" : @"Real-CUGAN", message, fallback);
                }
                if (needsDisplay) needsDisplay();
            });
        }
    });
    return [self copyCompositeImage:image width:width height:height];
}
@end
