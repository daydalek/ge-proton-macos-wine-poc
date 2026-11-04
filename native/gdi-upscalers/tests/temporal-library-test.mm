/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Temporal block residual library test. Drives the real presenter through
 * presentImage + synthetic neural jobs on the main run loop and verifies
 * multi-slot translated residual reuse. Build (arm64):
 *   xcrun clang++ -std=c++17 -O2 -fno-objc-arc -Wall -Wextra \
 *       -I native/gdi-upscalers/include \
 *       native/gdi-upscalers/tests/temporal-library-test.mm \
 *       -framework Foundation -framework AppKit -framework Metal \
 *       -framework QuartzCore -framework IOSurface -framework CoreGraphics \
 *       -o /tmp/wgdi-temporal-library-test
 * Run: MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 /tmp/wgdi-temporal-library-test \
 *       /path/to/gdi-upscalers            # dir containing temporal.metallib
 */
#include "../src/temporal.mm"
#include <set>
#include <atomic>
#include <memory>
#include <vector>

static int failures;
#define CHECK(cond, msg) do { \
    if (cond) printf("PASS %s\n", msg); \
    else { ++failures; printf("FAIL %s\n", msg); } } while (0)

static uint32_t rngState = 0x12345678u;
static uint32_t rngNext(void)
{
    rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5;
    return rngState;
}
static void fillRandom(uint8_t *p, NSUInteger count)
{
    for (NSUInteger i = 0; i < count; ++i) {
        uint8_t *px = p + i * 4;
        uint32_t v = rngNext();
        px[0] = v; px[1] = v >> 8; px[2] = v >> 16; px[3] = 255;
    }
}
static void blitSprite(uint8_t *frame, NSUInteger stride, const uint8_t *sprite,
    NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h)
{
    for (NSUInteger row = 0; row < h; ++row)
        memcpy(frame + (y + row) * stride + x * 4, sprite + row * w * 4, w * 4);
}
static CGImageRef makeImage(const uint8_t *bgra, NSUInteger w, NSUInteger h)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bgra, w * h * 4, NULL);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, NO,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}
/* Pending neural job state; the request block captures the immutable input and
 * the test answers it on the next run-loop pass with a pointwise 2x output. */
static NSUInteger requestCount;
static uint64_t requestToken;
static NSData *requestInput;
static NSUInteger requestWidth, requestHeight;
static WGDITemporalRequest makeRequest(void)
{
    WGDITemporalRequest block = ^BOOL(NSData *input, NSUInteger w, NSUInteger h, uint64_t token) {
        ++requestCount;
        requestToken = token;
        [requestInput release]; requestInput = [input retain];
        requestWidth = w; requestHeight = h;
        return YES;
    };
    return [[block copy] autorelease];
}
/* Pointwise 2x: out(2x+i,2y+j).rgb = clamp(in(x,y).rgb*0.9 + ((i^j) ? 0.06 : 0)).
 * Residual then translates by 2d when the input translates by d. */
static NSData *syntheticOutput(void)
{
    NSUInteger w = requestWidth, h = requestHeight;
    NSMutableData *out = [NSMutableData dataWithLength:w * h * 16];
    const uint8_t *in = (const uint8_t *)requestInput.bytes;
    uint8_t *o = (uint8_t *)out.mutableBytes;
    for (NSUInteger y = 0; y < h; ++y)
        for (NSUInteger x = 0; x < w; ++x) {
            const uint8_t *src = in + (y * w + x) * 4;
            for (NSUInteger j = 0; j < 2; ++j)
                for (NSUInteger i = 0; i < 2; ++i) {
                    float d = (i ^ j) ? 0.06f * 255.0f : 0.0f;
                    uint8_t *dst = o + ((2 * y + j) * 2 * w + 2 * x + i) * 4;
                    for (NSUInteger c = 0; c < 3; ++c) {
                        float v = src[c] * 0.9f + d;
                        dst[c] = v > 255.0f ? 255 : (uint8_t)(v + 0.5f);
                    }
                    dst[3] = 255;
                }
        }
    return out;
}
static void answerPending(id<WGDITemporalPresenter> presenter)
{
    if (!requestToken) return;
    uint64_t token = requestToken;
    NSData *output = syntheticOutput();
    requestToken = 0;
    [requestInput release]; requestInput = nil;
    [presenter completeOutput:output token:token needsDisplay:^{}];
}
static void runLoopOnce(id<WGDITemporalPresenter> presenter)
{
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    answerPending(presenter);
}
static void pump(id<WGDITemporalPresenter> presenter, double seconds)
{
    double end = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < end) runLoopOnce(presenter);
}
static BOOL waitFor(id<WGDITemporalPresenter> presenter, BOOL (^cond)(void), double timeout)
{
    double end = NSProcessInfo.processInfo.systemUptime + timeout;
    while (NSProcessInfo.processInfo.systemUptime < end) {
        runLoopOnce(presenter);
        if (cond()) return YES;
    }
    return cond();
}
static NSData *readTexture(id<MTLTexture> texture, id<MTLDevice> device, id<MTLCommandQueue> queue)
{
    NSUInteger bpp = texture.pixelFormat == MTLPixelFormatRGBA16Float ? 8 :
        texture.pixelFormat == MTLPixelFormatR8Unorm ? 1 : 4;
    NSUInteger stride = (texture.width * bpp + 255) & ~(NSUInteger)255;
    id<MTLBuffer> buffer = [device newBufferWithLength:stride * texture.height
        options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(texture.width, texture.height, 1)
        toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride
        destinationBytesPerImage:stride * texture.height];
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    NSMutableData *data = [NSMutableData dataWithLength:texture.width * texture.height * bpp];
    for (NSUInteger y = 0; y < texture.height; ++y)
        memcpy((uint8_t *)data.mutableBytes + y * texture.width * bpp,
               (const uint8_t *)buffer.contents + y * stride, texture.width * bpp);
    [buffer release];
    return data;
}
static float halfAt(const uint8_t *data, NSUInteger offset)
{
    _Float16 v;
    memcpy(&v, data + offset, sizeof(v));
    return (float)v;
}
/* Compare residual pixel regions channel-wise within tolerance. */
static NSUInteger halfDiff(const uint8_t *a, NSUInteger aOff, const uint8_t *b,
    NSUInteger bOff, NSUInteger components, float tolerance)
{
    NSUInteger diff = 0;
    for (NSUInteger i = 0; i < components; ++i)
        if (fabsf(halfAt(a, (aOff + i) * 2) - halfAt(b, (bOff + i) * 2)) > tolerance) ++diff;
    return diff;
}

@implementation WGDITemporalRenderer (LibraryTest)
- (NSUInteger)testFramesInFlight { return framesInFlight; }
- (NSUInteger)testLibrarySlots { return librarySlots; }
- (NSUInteger)testActiveSlots {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < 16; ++i) if (slotActive[i]) ++n;
    return n;
}
- (BOOL)testSlotActive:(NSUInteger)i { return i < 16 && slotActive[i]; }
- (BOOL)testFailed { return failed; }
- (uint64_t)testPendingToken { return pendingToken; }
- (id<MTLTexture>)testResidual { return residualTexture; }
- (id<MTLTexture>)testCurrent { return currentTexture; }
- (CALayer *)testLayer { return displayLayer; }
- (id<MTLTexture>)testExclusionWeights { return exclusionWeightTexture; }
- (id<MTLBuffer>)testMatches { return matchRecords; }
- (id<MTLBuffer>)testStats { return lastMetaSubmitted < metaSlotCount ?
    metaSlots[lastMetaSubmitted].stats : nil; }
- (id<MTLBuffer>)testProvisional { return provisionalFlags; }
- (id<MTLBuffer>)testTimes { return referenceTimes; }
- (id<MTLBuffer>)testLibraryTable { return libraryTable; }
- (NSUInteger)testLibraryEntries { return libraryEntries; }
- (void)testSetExactTranslation:(BOOL)flag { exactTranslation = flag; }
- (BOOL)testExactTranslation { return exactTranslation; }
- (id<MTLDevice>)testDevice { return device; }
- (id)testSpatialScaler { return spatialScaler; }
- (id<MTLTexture>)testSpatialIn { return spatialIn; }
- (id<MTLTexture>)testSpatialOut { return spatialOut; }
- (BOOL)testSpatialFailed { return spatialFailed; }
- (void)testForceSpatialFailure { [self clearSpatial]; spatialFailed = YES; }
- (NSUInteger)testSourceSlotCount { return sourceSlotCount; }
- (NSUInteger)testMetadataSlotCount { return metaSlotCount; }
- (NSUInteger)testFrameSequence { return frameSequence; }
- (id<MTLBuffer>)testMirror { return referenceMirror; }
- (void)testOverwriteMirror:(uint8_t)value {
    memset(referenceMirror.contents, value, inputWidth * inputHeight * 4);
}
- (BOOL)testSnapshotPending { return snapshotPending; }
- (uint64_t)testEpoch { return schedule.epoch; }

- (int)testStagingNull { return snapshotStaging ? (snapshotStaging.contents ? 0 : 1) : -1; }
- (NSUInteger)testSurfaceSlotCount { return surfaceSlotCount; }
- (NSUInteger)testSurfaceCacheCount { return surfaceCacheCount; }
- (id<MTLBuffer>)testAnalysedUpload { return analysedUpload; }
- (void)testSetAnalysedUpload:(id<MTLBuffer>)b {
    [analysedUpload release]; analysedUpload = [b retain];
}
- (NSUInteger)testInputStride { return inputStride; }
- (NSUInteger)testBusyTotals {
    unsigned n = 0;
    for (unsigned i = 0; i < sourceSlotCount; ++i) n += sourceSlots[i].busy;
    for (unsigned i = 0; i < surfaceSlotCount; ++i) n += surfaceSlots[i].busy;
    for (unsigned i = 0; i < metaSlotCount; ++i) n += metaSlots[i].busy;
    return n;
}
- (unsigned)testDirtyTiles {
    unsigned n = 0;
    for (NSUInteger i = 0; i < (NSUInteger)schedule.columns * schedule.rows; ++i)
        n += schedule.tiles[i].dirty != 0;
    return n;
}

- (void)testSetFadeUntil:(double)v { fadeUntil = v; }
- (void)testSetLastRendered:(double)v { lastRenderedParamTime = v; }
- (void)testSetPendingToken:(uint64_t)t { pendingToken = t; }
- (double)testNow { return [self now]; }
- (void)testSnapshotTile:(NSUInteger)tile request:(WGDITemporalRequest)request
{
    NSUInteger count = (NSUInteger)schedule.columns * schedule.rows;
    NSMutableData *selection = [NSMutableData dataWithLength:count * sizeof(uint32_t)];
    NSMutableData *versions = [NSMutableData dataWithLength:count * sizeof(uint64_t)];
    ((uint32_t *)selection.mutableBytes)[tile] = 1;
    for (NSUInteger i = 0; i < count; ++i)
        ((uint64_t *)versions.mutableBytes)[i] = schedule.tiles[i].version;
    [self snapshot:selection versions:versions request:request redraw:nil];
}

- (NSUInteger)testUploadBusyTotal {
    unsigned n = 0;
    for (unsigned i = 0; i < sourceSlotCount; ++i) n += sourceSlots[i].busy;
    return n;
}
- (id<MTLRenderPipelineState>)testRenderPS { return renderPS; }
- (id<MTLTexture>)testWeights { return weightsTexture; }
- (id<MTLCommandQueue>)testQueue { return queue; }
@end

static uint32_t fmixHost(uint32_t h)
{
    h ^= h >> 16; h *= 0x85ebca6bu; h ^= h >> 13; h *= 0xc2b2ae35u; h ^= h >> 16;
    return h;
}
static uint32_t contextHash(const uint8_t *frame, NSUInteger w, NSUInteger h,
                            NSUInteger ox, NSUInteger oy)
{
    uint32_t hash = 2166136261u;
    for (NSUInteger dy = 0; dy < 32; ++dy)
        for (NSUInteger dx = 0; dx < 32; ++dx) {
            long x = (long)ox - 8 + (long)dx, y = (long)oy - 8 + (long)dy;
            x = x < 0 ? 0 : x >= (long)w ? (long)w - 1 : x;
            y = y < 0 ? 0 : y >= (long)h ? (long)h - 1 : y;
            const uint8_t *p = frame + ((NSUInteger)y * w + (NSUInteger)x) * 4;
            uint32_t px = p[2] | ((uint32_t)p[1] << 8) | ((uint32_t)p[0] << 16);
            hash = (hash ^ px) * 16777619u;
        }
    return fmixHost(hash);
}
static void writeSource(uint8_t *frame, NSUInteger w, NSUInteger gx, NSUInteger gy,
    uint32_t ringSeed, BOOL sharedContext)
{
    uint32_t state = ringSeed;
    for (int y = -19; y < 35; ++y)
        for (int x = -19; x < 35; ++x) {
            uint8_t *p = frame + ((NSUInteger)(gy + y) * w + (NSUInteger)(gx + x)) * 4;
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            p[0] = state; p[1] = state >> 8; p[2] = state >> 16; p[3] = 255;
        }
    state = 0xABCDEF01u;
    for (int y = -8; y < 24; ++y)
        for (int x = -8; x < 24; ++x) {
            uint8_t *p = frame + ((NSUInteger)(gy + y) * w + (NSUInteger)(gx + x)) * 4;
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            uint32_t v = sharedContext ? state : ringSeed + state;
            p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = 255;
        }
    for (NSUInteger y = 0; y < 16; ++y)
        for (NSUInteger x = 0; x < 16; ++x) {
            uint8_t *p = frame + ((gy + y) * w + (gx + x)) * 4;
            p[0] = 90; p[1] = 60; p[2] = 30; p[3] = 255;
        }
}
static void copyPatch54(uint8_t *dst, const uint8_t *src, NSUInteger w, NSUInteger h,
    int sx, int sy, int dx, int dy)
{
    for (int y = -19; y < 35; ++y)
        for (int x = -19; x < 35; ++x) {
            int tx = dx + x, ty = dy + y;
            if (tx < 0 || ty < 0 || tx >= (int)w || ty >= (int)h) continue;
            memcpy(dst + ((NSUInteger)ty * w + (NSUInteger)tx) * 4,
                   src + ((NSUInteger)(sy + y) * w + (NSUInteger)(sx + x)) * 4, 4);
        }
}

struct matchRecord { uint32_t x, y, z, w; };
static const NSUInteger FW = 640, FH = 480;
static const NSUInteger BC = (FW + 15) / 16, BR = (FH + 15) / 16;

@interface TestDriver : NSObject {
    WGDITemporalRenderer *renderer;
    CALayer *parent;
    NSUInteger width, height, outWidth, outHeight;
}
- (id)initWithRenderer:(WGDITemporalRenderer *)r parent:(CALayer *)p
    width:(NSUInteger)w height:(NSUInteger)h;
- (void)setOutputWidth:(NSUInteger)w height:(NSUInteger)h;
- (void (^)(void))redraw;
- (BOOL)present:(const uint8_t *)pixels;
@end
@implementation TestDriver
- (id)initWithRenderer:(WGDITemporalRenderer *)r parent:(CALayer *)p
    width:(NSUInteger)w height:(NSUInteger)h
{
    self = [super init];
    if (!self) return nil;
    renderer = [r retain]; parent = [p retain];
    width = w; height = h;
    outWidth = w; outHeight = h;
    return self;
}
- (void)dealloc
{
    [renderer release]; [parent release];
    [super dealloc];
}
- (void)setOutputWidth:(NSUInteger)w height:(NSUInteger)h
{
    outWidth = w; outHeight = h;
}
- (void (^)(void))redraw
{
    TestDriver *driver = self;
    return [[^{
        [driver->renderer presentLatestInLayer:driver->parent
            frame:CGRectMake(0, 0, driver->outWidth, driver->outHeight)
            width:driver->outWidth height:driver->outHeight
            request:makeRequest() needsDisplay:[driver redraw]];
    } copy] autorelease];
}
- (BOOL)present:(const uint8_t *)pixels
{
    CGImageRef image = makeImage(pixels, width, height);
    BOOL ok = [renderer presentImage:image inLayer:parent
        frame:CGRectMake(0, 0, outWidth, outHeight) width:outWidth height:outHeight
        request:makeRequest() needsDisplay:[self redraw]];
    CGImageRelease(image);
    return ok;
}
@end

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: %s <resources-directory>\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString *resources = [NSString stringWithUTF8String:argv[1]];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(-32000, -32000, FW, FH)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.contentView.wantsLayer = YES;
        [window orderFrontRegardless];
        CALayer *parent = window.contentView.layer;

        /* One random background and one 96x96 sprite re-blit at each position
         * so translated content is byte-identical across frames. */
        NSMutableData *background = [NSMutableData dataWithLength:FW * FH * 4];
        fillRandom((uint8_t *)background.mutableBytes, FW * FH);
        NSMutableData *sprite = [NSMutableData dataWithLength:96 * 96 * 4];
        fillRandom((uint8_t *)sprite.mutableBytes, 96 * 96);
        NSMutableData *sprite1 = [background mutableCopy];
        blitSprite((uint8_t *)sprite1.mutableBytes, FW * 4,
            (const uint8_t *)sprite.bytes, 160, 96, 96, 96);
        NSMutableData *sprite2 = [background mutableCopy];
        blitSprite((uint8_t *)sprite2.mutableBytes, FW * 4,
            (const uint8_t *)sprite.bytes, 192, 112, 96, 96);
        NSMutableData *sprite3 = [background mutableCopy];
        blitSprite((uint8_t *)sprite3.mutableBytes, FW * 4,
            (const uint8_t *)sprite.bytes, 197, 115, 96, 96);

        id<WGDITemporalPresenter> base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
            resources.fileSystemRepresentation);
        CHECK(base != nil, "presenter created");
        WGDITemporalRenderer *r = (WGDITemporalRenderer *)base;
        if (!r) return 1;
        [r testSetExactTranslation:YES];
        TestDriver *d = [[[TestDriver alloc] initWithRenderer:r parent:parent
            width:FW height:FH] autorelease];
        BOOL ok;

        /* Scenario 1: background accepted and stored as the first slot. */
        requestCount = requestToken = 0;
        CHECK([d present:(const uint8_t *)background.bytes], "s1 present");
        ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s1 first library slot stored");
        CHECK(requestCount >= 1, "s1 inference requested");
        NSData *r1 = readTexture(r.testResidual, r.testDevice, r.testQueue);

        /* Scenario 2: sprite slot is stored alongside the background slot. */
        CHECK([d present:(const uint8_t *)sprite1.bytes], "s2 present");
        ok = waitFor(r, ^{ return r.testActiveSlots >= 2 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s2 second slot stored (not redundant)");
        NSData *r2 = readTexture(r.testResidual, r.testDevice, r.testQueue);

        /* Scenario 3: background returns; every probed block matches exactly and
         * no inference is issued afterwards. */
        NSUInteger before = requestCount;
        CHECK([d present:(const uint8_t *)background.bytes], "s3 present");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s3 frame completed");
        const uint32_t *stats = r.testStats ? (const uint32_t *)r.testStats.contents : NULL;
        const struct matchRecord *matches = r.testMatches ? (const struct matchRecord *)r.testMatches.contents : NULL;
        NSUInteger probed = stats ? stats[0] : 0, exact = stats ? stats[1] : 0;
        NSUInteger provisional = stats ? stats[2] : 0;
        NSUInteger matched = 0; BOOL allExact = YES;
        for (NSUInteger i = 0; matches && i < BC * BR; ++i) {
            if (!matches[i].x) continue;
            ++matched;
            if (matches[i].w != 1 || matches[i].y != 0 || matches[i].z != 0) allExact = NO;
        }
        CHECK(probed > 0 && probed == exact && provisional == 0, "s3 all probed blocks exact");
        CHECK(matched == probed && allExact, "s3 match records d=0 exact");
        pump(r, 0.45);
        CHECK(requestCount == before, "s3 no inference request within 400 ms");
        NSData *r3 = readTexture(r.testResidual, r.testDevice, r.testQueue);
        {
            NSUInteger bad = 0, firstBad = 0;
            for (NSUInteger i = 0; i < FW * 2 * FH * 2 * 4; ++i)
                if (halfDiff((const uint8_t *)r1.bytes, i, (const uint8_t *)r3.bytes, i,
                        1, 1e-3f)) { if (!bad) firstBad = i; ++bad; }
            if (bad) {
                NSUInteger px = firstBad / 4, ch = firstBad % 4;
                printf("s3 diff components %lu first at 2x-px (%lu,%lu) ch %lu r1=%f r3=%f\n",
                    (unsigned long)bad, (unsigned long)(px % (FW * 2)),
                    (unsigned long)(px / (FW * 2)), (unsigned long)ch,
                    halfAt((const uint8_t *)r1.bytes, firstBad * 2),
                    halfAt((const uint8_t *)r3.bytes, firstBad * 2));
            }
            CHECK(bad == 0, "s3 residual equals step 1");
        }

        /* Scenario 4: sprite moved by an even d=(32,16); interior blocks match
         * exactly and reuse the translated step-2 residual. */
        NSUInteger ix[64], iy[64], interiorCount = 0;
        for (NSUInteger gy = 0; gy + 16 <= FH; gy += 16)
            for (NSUInteger gx = 0; gx + 16 <= FW; gx += 16)
                if (gx >= 210 && gx + 34 <= 288 && gy >= 130 && gy + 34 <= 208) {
                    ix[interiorCount] = gx; iy[interiorCount] = gy;
                    ++interiorCount;
                }
        CHECK([d present:(const uint8_t *)sprite2.bytes], "s4 present");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s4 frame completed");
        matches = (const struct matchRecord *)r.testMatches.contents;
        BOOL recordsOK = interiorCount > 0;
        for (NSUInteger i = 0; recordsOK && i < interiorCount; ++i) {
            struct matchRecord m = matches[(iy[i] / 16) * BC + ix[i] / 16];
            if (!m.x || m.w != 1 || m.y != 32u || m.z != 16u) recordsOK = NO;
        }
        CHECK(recordsOK, "s4 interior blocks exact d=(32,16)");
        NSData *r4 = readTexture(r.testResidual, r.testDevice, r.testQueue);
        NSUInteger diff = 0;
        const uint8_t *r4b = (const uint8_t *)r4.bytes, *r2b = (const uint8_t *)r2.bytes;
        for (NSUInteger i = 0; i < interiorCount; ++i)
            for (NSUInteger py = 0; py < 32; ++py)
                for (NSUInteger px = 0; px < 32; ++px) {
                    NSUInteger pos = (2 * iy[i] + py) * (FW * 2) + 2 * ix[i] + px;
                    NSUInteger src = pos - (64 + 32 * (FW * 2));
                    diff += halfDiff(r4b, pos * 4, r2b, src * 4, 4, 1e-3f);
                }
        CHECK(diff == 0, "s4 residual equals step-2 residual shifted by (64,32)");

        /* Scenario 5: odd translation d=(37,19) also matches exactly when the
         * model declares integer translation; the residual shifts by 2d. */
        NSUInteger interiorCount5 = 0;
        for (NSUInteger gy = 0; gy + 16 <= FH; gy += 16)
            for (NSUInteger gx = 0; gx + 16 <= FW; gx += 16)
                if (gx >= 215 && gx + 34 <= 293 && gy >= 133 && gy + 34 <= 211) {
                    ix[interiorCount5] = gx; iy[interiorCount5] = gy;
                    ++interiorCount5;
                }
        CHECK([d present:(const uint8_t *)sprite3.bytes], "s5 present");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s5 frame completed");
        matches = (const struct matchRecord *)r.testMatches.contents;
        const uint32_t *prov = (const uint32_t *)r.testProvisional.contents;
        recordsOK = interiorCount5 > 0;
        for (NSUInteger i = 0; recordsOK && i < interiorCount5; ++i) {
            NSUInteger index = (iy[i] / 16) * BC + ix[i] / 16;
            struct matchRecord m = matches[index];
            if (!m.x || m.w != 1 || m.y != 37u || m.z != 19u || prov[index] != 0)
                recordsOK = NO;
        }
        CHECK(recordsOK, "s5 interior blocks exact d=(37,19)");
        {
            NSData *r5 = readTexture(r.testResidual, r.testDevice, r.testQueue);
            const uint8_t *r5b = (const uint8_t *)r5.bytes;
            NSUInteger shifted = 0;
            for (NSUInteger i = 0; i < interiorCount5; ++i)
                for (NSUInteger py = 0; py < 32; ++py)
                    for (NSUInteger px = 0; px < 32; ++px) {
                        NSUInteger pos = (2 * iy[i] + py) * (FW * 2) + 2 * ix[i] + px;
                        NSUInteger src = pos - (74 + 38 * (FW * 2));
                        shifted += halfDiff(r5b, pos * 4, r2b, src * 4, 4, 1e-3f);
                    }
            CHECK(shifted == 0, "s5 residual equals step-2 residual shifted by (74,38)");
        }
        pump(r, 0.45);
        {
            NSUInteger stillExact = 0;
            for (NSUInteger i = 0; i < interiorCount5; ++i) {
                NSUInteger index = (iy[i] / 16) * BC + ix[i] / 16;
                struct matchRecord m = matches[index];
                if (m.x && m.w == 1 && prov[index] == 0) ++stillExact;
            }
            CHECK(stillExact == interiorCount5,
                "s5 interior stays exact, no refinement needed");
        }

        [r cancel]; [r release]; r = nil;

        /* Scenario 5b: with exact translation disabled the same move stays
         * provisional until refinement clears it. */
        base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
            resources.fileSystemRepresentation);
        r = (WGDITemporalRenderer *)base;
        CHECK(r != nil, "s5b presenter created");
        CHECK(![r testExactTranslation], "s5b exact translation off by default");
        TestDriver *d5 = [[[TestDriver alloc] initWithRenderer:r parent:parent
            width:FW height:FH] autorelease];
        requestCount = requestToken = 0;
        [d5 present:(const uint8_t *)background.bytes];
        ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s5b background slot stored");
        [d5 present:(const uint8_t *)sprite1.bytes];
        ok = waitFor(r, ^{ return r.testActiveSlots >= 2 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s5b sprite slot stored");
        NSData *rPre5 = readTexture(r.testResidual, r.testDevice, r.testQueue);
        CHECK([d5 present:(const uint8_t *)sprite3.bytes], "s5b present");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s5b frame completed");
        matches = (const struct matchRecord *)r.testMatches.contents;
        prov = (const uint32_t *)r.testProvisional.contents;
        recordsOK = interiorCount5 > 0;
        for (NSUInteger i = 0; recordsOK && i < interiorCount5; ++i) {
            NSUInteger index = (iy[i] / 16) * BC + ix[i] / 16;
            struct matchRecord m = matches[index];
            if (!m.x || m.w != 0 || m.y != 37u || m.z != 19u || prov[index] != 1)
                recordsOK = NO;
        }
        CHECK(recordsOK, "s5b interior blocks provisional d=(37,19)");
        {
            NSData *rNow5 = readTexture(r.testResidual, r.testDevice, r.testQueue);
            const uint8_t *nowB = (const uint8_t *)rNow5.bytes;
            const uint8_t *preB = (const uint8_t *)rPre5.bytes;
            NSUInteger ring = 0, ringDiff = 0;
            for (NSUInteger by = 0; by < BR; ++by)
                for (NSUInteger bx = 0; bx < BC; ++bx) {
                    if (matches[by * BC + bx].x) continue;  /* only clean blocks */
                    for (NSUInteger py = 0; py < 16; ++py)
                        for (NSUInteger px = 0; px < 16; ++px) {
                            NSUInteger x = bx * 16 + px, y = by * 16 + py;
                            BOOL provCover = NO, exactCover = NO;
                            for (int dy = -1; dy <= 1; ++dy)
                                for (int dx = -1; dx <= 1; ++dx) {
                                    int nx = (int)bx + dx, ny = (int)by + dy;
                                    if (nx < 0 || ny < 0 || nx >= (int)BC || ny >= (int)BR)
                                        continue;
                                    struct matchRecord m = matches[(NSUInteger)ny * BC + (NSUInteger)nx];
                                    if (!m.x) continue;
                                    int gx = nx * 16, gy2 = ny * 16;
                                    BOOL inBand = (int)x >= gx - 8 && (int)x < gx + 24 &&
                                        (int)y >= gy2 - 8 && (int)y < gy2 + 24;
                                    if (!inBand) continue;
                                    if (m.w) exactCover = YES; else provCover = YES;
                                }
                            if (!provCover || exactCover) continue;
                            ++ring;
                            for (NSUInteger j = 0; j < 2; ++j)
                                for (NSUInteger i = 0; i < 2; ++i) {
                                    NSUInteger pos = (2 * y + j) * (FW * 2) + 2 * x + i;
                                    ringDiff += halfDiff(nowB, pos * 4, preB, pos * 4, 4, 0.0f);
                                }
                        }
                }
            CHECK(ring > 0 && ringDiff == 0, "s5b provisional ring keeps previous residual");
        }
        NSMutableData *indices = [NSMutableData dataWithLength:interiorCount5 * sizeof(uint32_t)];
        for (NSUInteger i = 0; i < interiorCount5; ++i)
            ((uint32_t *)indices.mutableBytes)[i] = (uint32_t)((iy[i] / 16) * BC + ix[i] / 16);
        ok = waitFor(r, ^{
            const uint32_t *flags = (const uint32_t *)r.testProvisional.contents;
            const float *times = (const float *)r.testTimes.contents;
            const uint32_t *blocks = (const uint32_t *)indices.bytes;
            for (NSUInteger i = 0; i < interiorCount5; ++i)
                if (flags[blocks[i]] || times[blocks[i]] < 0) return NO;
            return YES;
        }, 10.0);
        CHECK(ok, "s5b provisional cleared after refinement");

        [r cancel]; [r release]; r = nil;

        /* Scenario 8: per-block volatility frees dialogue-text slots. A fresh
         * presenter repeats steps 1-2 (churn is cumulative history; the earlier
         * scenarios' sprite moves would legitimately mark that union volatile),
         * then six frames differing only in a text band are each refined and
         * stored. Volatile positions must not keep redundant text slots alive
         * nor cost the background slot. */
        base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
            resources.fileSystemRepresentation);
        r = (WGDITemporalRenderer *)base;
        CHECK(r != nil, "s8 presenter created");
        [r testSetExactTranslation:YES];
        TestDriver *d8 = [[[TestDriver alloc] initWithRenderer:r parent:parent
            width:FW height:FH] autorelease];
        requestCount = requestToken = 0;
        [d8 present:(const uint8_t *)background.bytes];
        ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s8 background slot stored");
        [d8 present:(const uint8_t *)sprite1.bytes];
        ok = waitFor(r, ^{ return r.testActiveSlots >= 2 && r.testFramesInFlight == 0; }, 15.0);
        CHECK(ok, "s8 sprite slot stored");
        NSUInteger before8 = r.testActiveSlots;
        NSMutableData *textBand = [NSMutableData dataWithLength:512 * 64 * 4];
        for (NSUInteger frame = 0; frame < 6; ++frame) {
            fillRandom((uint8_t *)textBand.mutableBytes, 512 * 64);
            NSMutableData *texted = [sprite1 mutableCopy];
            blitSprite((uint8_t *)texted.mutableBytes, FW * 4,
                (const uint8_t *)textBand.bytes, 64, 400, 512, 64);
            CHECK([d8 present:(const uint8_t *)texted.bytes], "s8 text frame present");
            NSUInteger expected = requestCount + 1;
            ok = waitFor(r, ^{ return requestCount >= expected &&
                r.testPendingToken == 0; }, 10.0);
            CHECK(ok, "s8 text frame refined");
            pump(r, 0.3);  /* slot snapshot completion */
        }
        NSUInteger after8 = r.testActiveSlots;
        CHECK(after8 <= before8 + 3, "s8 volatile text slots bounded");
        CHECK([r testSlotActive:0], "s8 background slot retained");
        before = requestCount;
        CHECK([d8 present:(const uint8_t *)background.bytes], "s8 background return");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s8 return frame completed");
        stats = (const uint32_t *)r.testStats.contents;
        matches = (const struct matchRecord *)r.testMatches.contents;
        probed = stats[0]; exact = stats[1]; provisional = stats[2];
        matched = 0; allExact = YES;
        for (NSUInteger i = 0; i < BC * BR; ++i) {
            if (!matches[i].x) continue;
            ++matched;
            if (matches[i].w != 1 || matches[i].y != 0 || matches[i].z != 0) allExact = NO;
        }
        CHECK(probed > 0 && probed == exact && provisional == 0 &&
            matched == probed && allExact, "s8 return matched exact from library");
        CHECK(r.testDirtyTiles == 0, "s8 return ring recovered from library");
        pump(r, 0.45);
        CHECK(requestCount == before, "s8 return needs no re-request");
        before = requestCount;
        CHECK([d8 present:(const uint8_t *)sprite2.bytes], "s8b novel halo present");
        ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
        CHECK(ok, "s8b novel halo frame completed");
        pump(r, 0.45);
        CHECK(requestCount > before, "s8b novel halo invalidated neighbors re-request");
        [r cancel]; [r release]; r = nil;

        /* Scenario 6: library disabled behaves like the old pipeline. */
        setenv("WINE_GDI_TEMPORAL_LIBRARY_MB", "0", 1);
        base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
            resources.fileSystemRepresentation);
        unsetenv("WINE_GDI_TEMPORAL_LIBRARY_MB");
        r = (WGDITemporalRenderer *)base;
        TestDriver *d6 = [[[TestDriver alloc] initWithRenderer:r parent:parent
            width:FW height:FH] autorelease];
        [r testSetExactTranslation:YES];
        CHECK(r && r.testLibrarySlots == 0, "s6 library disabled");
        CHECK(!r.testMatches, "s6 no match record buffer");
        requestCount = requestToken = 0;
        [d6 present:(const uint8_t *)background.bytes];
        ok = waitFor(r, ^{ return requestCount >= 1 && r.testPendingToken == 0; }, 15.0);
        CHECK(ok, "s6 background refined");
        [d6 present:(const uint8_t *)sprite1.bytes];
        ok = waitFor(r, ^{ return requestCount >= 2 && r.testPendingToken == 0; }, 15.0);
        CHECK(ok, "s6 sprite refined");
        before = requestCount;
        [d6 present:(const uint8_t *)background.bytes];
        ok = waitFor(r, ^{ return requestCount > before; }, 10.0);
        CHECK(ok, "s6 inference requested again on return");
        [r cancel]; [r release]; r = nil;

        /* Scenario 7: odd 703x252 frames must not trip Metal validation. */
        base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
            resources.fileSystemRepresentation);
        r = (WGDITemporalRenderer *)base;
        TestDriver *d7 = [[[TestDriver alloc] initWithRenderer:r parent:parent
            width:703 height:252] autorelease];
        CHECK(r != nil, "s7 presenter created");
        NSMutableData *odd = [NSMutableData dataWithLength:703 * 252 * 4];
        fillRandom((uint8_t *)odd.mutableBytes, 703 * 252);
        setenv("WINE_GDI_UPSCALER_EXCLUDE", "100,50,200,100", 1);
        CHECK([d7 present:(const uint8_t *)odd.bytes], "s7 present 703x252");
        unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
        pump(r, 0.5);
        CHECK(![r testFailed], "s7 no Metal validation failure");
        [r cancel]; [r release];

        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s9 presenter created");
            [r testSetExactTranslation:YES];
            TestDriver *d9 = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *fa = [background mutableCopy];
            writeSource((uint8_t *)fa.mutableBytes, FW, 64, 64, 0x11111111u, NO);
            writeSource((uint8_t *)fa.mutableBytes, FW, 160, 64, 0x22222222u, NO);
            [d9 present:(const uint8_t *)fa.bytes];
            ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
            CHECK(ok, "s9a dual-context slot stored");
            NSMutableData *ft = [background mutableCopy];
            copyPatch54((uint8_t *)ft.mutableBytes, (const uint8_t *)fa.bytes,
                FW, FH, 160, 64, 320, 192);
            [d9 present:(const uint8_t *)ft.bytes];
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s9a frame completed");
            matches = (const struct matchRecord *)r.testMatches.contents;
            {
                struct matchRecord m = matches[(192 / 16) * BC + 320 / 16];
                CHECK(m.x && m.w == 1 && m.y == 160 && m.z == 128,
                      "s9a correct source recalled d=(160,128)");
            }
            [r cancel]; [r release]; r = nil;

            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s9b presenter created");
            [r testSetExactTranslation:YES];
            TestDriver *d9b = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *fb = [background mutableCopy];
            writeSource((uint8_t *)fb.mutableBytes, FW, 64, 64, 0x33333333u, YES);
            writeSource((uint8_t *)fb.mutableBytes, FW, 160, 64, 0x44444444u, YES);
            [d9b present:(const uint8_t *)fb.bytes];
            ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
            CHECK(ok, "s9b same-key slot stored");
            const uint32_t key = contextHash((const uint8_t *)fb.bytes, FW, FH, 64, 64);
            NSUInteger entries = r.testLibraryEntries;
            struct tableEntry { uint32_t key, value; };
            const struct tableEntry *table = (const struct tableEntry *)r.testLibraryTable.contents;
            NSUInteger sameKey = 0;
            const uint32_t mask = (uint32_t)(entries - 1);
            uint32_t coordX[4] = {0, 0, 0, 0}, coordY[4] = {0, 0, 0, 0};
            for (NSUInteger s = 0; s < 16 && sameKey < 4; ++s) {
                const struct tableEntry *slot = table + s * entries;
                for (uint32_t i = 0; i < 32 && sameKey < 4; ++i) {
                    const struct tableEntry *e = &slot[(key + i) & mask];
                    if (!e->key) break;
                    if (e->key == key) {
                        coordX[sameKey] = e->value & 0xffffu;
                        coordY[sameKey] = e->value >> 16;
                        ++sameKey;
                    }
                }
            }
            CHECK(sameKey >= 2, "s9b same key keeps at least two coordinates");
            uint32_t chosenX = sameKey >= 2 ? coordX[sameKey - 1] : 160;
            uint32_t chosenY = sameKey >= 2 ? coordY[sameKey - 1] : 64;
            NSMutableData *ft2 = [background mutableCopy];
            copyPatch54((uint8_t *)ft2.mutableBytes, (const uint8_t *)fb.bytes,
                FW, FH, (int)chosenX, (int)chosenY, 320, 192);
            [d9b present:(const uint8_t *)ft2.bytes];
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s9b frame completed");
            matches = (const struct matchRecord *)r.testMatches.contents;
            {
                struct matchRecord m = matches[(192 / 16) * BC + 320 / 16];
                CHECK(m.x && m.w == 1 && m.y == 320 - chosenX && m.z == 192 - chosenY,
                      "s9b later exact not shadowed by provisional");
            }
            [r cancel]; [r release]; r = nil;

            /* Scenario 9c: same visible context near the edge whose padding
             * dependency differs may never become exact. */
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s9c presenter created");
            [r testSetExactTranslation:YES];
            TestDriver *d9c = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *fc = [background mutableCopy];
            writeSource((uint8_t *)fc.mutableBytes, FW, 64, 64, 0x55555555u, YES);
            [d9c present:(const uint8_t *)fc.bytes];
            ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
            CHECK(ok, "s9c slot stored");
            NSMutableData *ft3 = [background mutableCopy];
            copyPatch54((uint8_t *)ft3.mutableBytes, (const uint8_t *)fc.bytes,
                FW, FH, 64, 64, 16, 64);
            [d9c present:(const uint8_t *)ft3.bytes];
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s9c frame completed");
            matches = (const struct matchRecord *)r.testMatches.contents;
            {
                struct matchRecord m = matches[(64 / 16) * BC + 1];
                CHECK(m.x && m.w == 0 && m.y == (uint32_t)-48 && m.z == 0,
                      "s9c edge move stays provisional");
            }
            [r cancel]; [r release]; r = nil;
        }

        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s9p presenter created");
            TestDriver *d9p = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *uniform = [NSMutableData dataWithLength:FW * FH * 4];
            memset(uniform.mutableBytes, 0x7f, uniform.length);
            [d9p present:(const uint8_t *)uniform.bytes];
            ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 15.0);
            CHECK(ok, "s9p slot stored");
            struct tableEntry { uint32_t key, value; };
            const struct tableEntry *table = r.testLibraryTable ?
                (const struct tableEntry *)r.testLibraryTable.contents : NULL;
            CHECK(table != NULL, "s9p table readable");
            uint32_t key = contextHash((const uint8_t *)uniform.bytes, FW, FH, 0, 0);
            if (!key) key = 1;
            unsigned found = 0;
            std::set<uint32_t> seen;
            for (unsigned e = 0; e < r.testLibraryEntries; ++e)
                if (table[e].key == key) {
                    ++found;
                    const uint32_t x = table[e].value & 0xffff, y = table[e].value >> 16;
                    CHECK(!(x & 1) && !(y & 1) && x + 16 <= FW && y + 16 <= FH &&
                          seen.insert(table[e].value).second, "s9p coordinate unique");
                }
            CHECK(found >= 1 && found <= 4, "s9p key bounded to four coordinates");
            [r cancel]; [r release]; r = nil;
        }

        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s10 presenter created");
            [r testSetExactTranslation:YES];
            TestDriver *d10 = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            setenv("WINE_GDI_UPSCALER_EXCLUDE", "64,64,96,48", 1);
            NSMutableData *texted = [background mutableCopy];
            blitSprite((uint8_t *)texted.mutableBytes, FW * 4,
                (const uint8_t *)sprite.bytes, 64, 64, 96, 48);
            CHECK([d10 present:(const uint8_t *)texted.bytes], "s10 present");
            for (int spins = 0; spins < 1000 && !requestCount; ++spins)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            ok = requestCount >= 1;
            CHECK(ok, "s10 inference requested");
            {
                const uint8_t *in = (const uint8_t *)requestInput.bytes;
                const uint8_t *src = (const uint8_t *)texted.bytes;
                BOOL normalized = YES, untouched = YES;
                for (NSUInteger y = 64; y < 112 && normalized; ++y)
                    for (NSUInteger x = 64; x < 160 && normalized; ++x) {
                        const uint8_t *p = in + (y * FW + x) * 4;
                        normalized = !p[0] && !p[1] && !p[2] && p[3] == 255;
                    }
                for (NSUInteger y = 0; y < FH && untouched; ++y)
                    for (NSUInteger x = 0; x < FW && untouched; ++x) {
                        if (x >= 64 && x < 160 && y >= 64 && y < 112) continue;
                        untouched = !memcmp(in + (y * FW + x) * 4,
                            src + (y * FW + x) * 4, 4);
                    }
                CHECK(normalized, "s10 requestInput masked pixels are black");
                CHECK(untouched, "s10 requestInput outside mask unchanged");
            }
            answerPending(r);
            pump(r, 0.4);
            NSData *shown = readTexture(r.testCurrent, r.testDevice, r.testQueue);
            {
                const uint8_t *p = (const uint8_t *)shown.bytes + (80 * FW + 80) * 4;
                CHECK(p[0] != 0 || p[1] != 0 || p[2] != 0,
                      "s10 displayed input keeps masked text");
            }
            NSData *wt = readTexture(r.testExclusionWeights, r.testDevice, r.testQueue);
            {
                const uint8_t *w = (const uint8_t *)wt.bytes;
                CHECK(w[80 * FW + 80] == 0, "s10 weight zero inside rect");
                CHECK(w[64 * FW + 45] == 0, "s10 weight zero at halo edge");
                CHECK(w[64 * FW + 40] > 0 && w[64 * FW + 40] < 255,
                      "s10 weight feathers");
                CHECK(w[64 * FW + 30] == 255, "s10 weight full past band");
            }
            before = requestCount;
            NSMutableData *texted2 = [texted mutableCopy];
            blitSprite((uint8_t *)texted2.mutableBytes, FW * 4,
                (const uint8_t *)sprite2.bytes + (400 * FW + 64) * 4, 64, 64, 96, 48);
            CHECK([d10 present:(const uint8_t *)texted2.bytes], "s10 masked-only change");
            pump(r, 0.4);
            CHECK(requestCount == before, "s10 masked-only change adds no request");
            ok = waitFor(r, ^{ return r.testActiveSlots >= 1 && r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s10 first masked slot stored");
            NSMutableData *nearMask = [texted2 mutableCopy];
            blitSprite((uint8_t *)nearMask.mutableBytes, FW * 4,
                (const uint8_t *)sprite.bytes, 160, 64, 96, 48);
            CHECK([d10 present:(const uint8_t *)nearMask.bytes], "s10 sprite adjacent to mask");
            ok = waitFor(r, ^{ return r.testActiveSlots >= 2 && r.testFramesInFlight == 0; }, 15.0);
            CHECK(ok, "s10 adjacent sprite slot stored");
            pump(r, 0.3);
            NSMutableData *returnTexted = [background mutableCopy];
            NSMutableData *freshText = [NSMutableData dataWithLength:96 * 48 * 4];
            fillRandom((uint8_t *)freshText.mutableBytes, 96 * 48);
            blitSprite((uint8_t *)returnTexted.mutableBytes, FW * 4,
                (const uint8_t *)freshText.bytes, 64, 64, 96, 48);
            before = requestCount;
            CHECK([d10 present:(const uint8_t *)returnTexted.bytes], "s10 return with new masked text");
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s10 return frame completed");
            stats = (const uint32_t *)r.testStats.contents;
            CHECK(stats[0] > 0 && stats[0] == stats[1] && stats[2] == 0 &&
                r.testDirtyTiles == 0, "s10 halo overlapping excluded rect recalls exact");
            pump(r, 0.45);
            CHECK(requestCount == before, "s10 recall near excluded rect needs no re-request");
            NSMutableData *unmasked = [returnTexted mutableCopy];
            blitSprite((uint8_t *)unmasked.mutableBytes, FW * 4,
                (const uint8_t *)sprite.bytes, 400, 300, 96, 48);
            CHECK([d10 present:(const uint8_t *)unmasked.bytes], "s10 unmasked change present");
            for (int spins = 0; spins < 1000 && !requestToken; ++spins)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(requestToken != 0, "s10 pending request captured");
            uint64_t staleToken = requestToken;
            NSData *staleOut = syntheticOutput();
            setenv("WINE_GDI_UPSCALER_EXCLUDE", "200,200,32,32", 1);
            [r completeOutput:staleOut token:staleToken needsDisplay:^{}];
            CHECK(r.testPendingToken != staleToken, "s10 stale token dropped on mask change");
            requestToken = 0;
            [requestInput release]; requestInput = nil;
            CHECK([d10 present:(const uint8_t *)texted2.bytes], "s10 mask change present");
            before = requestCount;
            ok = waitFor(r, ^{ return requestCount > before; }, 10.0);
            CHECK(ok, "s10 re-refined after mask change");
            answerPending(r);
            pump(r, 0.3);
            unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
            [r cancel]; [r release]; r = nil;
        }

        {
            char root[] = "/tmp/wgdi-manifest-XXXXXX";
            CHECK(mkdtemp(root) != NULL, "s11 scratch dir");
            NSString *scratch = [NSString stringWithUTF8String:root];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *models = [scratch stringByAppendingPathComponent:@"coreml"];
            [fm createDirectoryAtPath:models withIntermediateDirectories:YES
                attributes:nil error:nil];
            CHECK([fm copyItemAtPath:[resources stringByAppendingPathComponent:@"temporal.metallib"]
                toPath:[scratch stringByAppendingPathComponent:@"temporal.metallib"]
                error:nil], "s11 metallib copied");
            NSString *manifestPath = [models stringByAppendingPathComponent:@"manifest.json"];
            NSDictionary *good = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19, @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *wideHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @22, @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *smallHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @18, @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *dep20 = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19, @"dependency_halo": @20, @"integer_translation": @YES}}};
            NSDictionary *strHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @"19", @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *num123 = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19, @"dependency_halo": @19, @"integer_translation": @123}}};
            NSDictionary *notInteger = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19, @"dependency_halo": @19, @"integer_translation": @NO}}};
            NSDictionary *boolHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @YES, @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *hugeHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @4294967315LL, @"dependency_halo": @19, @"integer_translation": @YES}}};
            NSDictionary *hugeDep = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19, @"dependency_halo": @4294967315LL, @"integer_translation": @YES}}};
            NSDictionary *fracHalo = @{@"temporal_models": @{@"animevideov3":
                @{@"input_halo": @19.5, @"dependency_halo": @19, @"integer_translation": @YES}}};
            struct { NSString *name; id manifest; const char *model; BOOL exact; }
                cases[] = {
                {@"good manifest enables exact", good, "animevideov3", YES},
                {@"wider input halo enables exact", wideHalo, "animevideov3", YES},
                {@"missing manifest fails closed", nil, "animevideov3", NO},
                {@"legacy manifest fails closed", @{}, "animevideov3", NO},
                {@"root array fails closed", @[good], "animevideov3", NO},
                {@"models array fails closed", @{@"temporal_models": @[good]},
                    "animevideov3", NO},
                {@"models string fails closed", @{@"temporal_models": @"x"},
                    "animevideov3", NO},
                {@"models null fails closed", @{@"temporal_models": [NSNull null]},
                    "animevideov3", NO},
                {@"entry string fails closed", @{@"temporal_models":
                    @{@"animevideov3": @"x"}}, "animevideov3", NO},
                {@"entry null fails closed", @{@"temporal_models":
                    @{@"animevideov3": [NSNull null]}}, "animevideov3", NO},
                {@"small halo fails closed", smallHalo, "animevideov3", NO},
                {@"dependency 20 fails closed", dep20, "animevideov3", NO},
                {@"string halo fails closed", strHalo, "animevideov3", NO},
                {@"bool halo fails closed", boolHalo, "animevideov3", NO},
                {@"huge halo fails closed", hugeHalo, "animevideov3", NO},
                {@"huge dependency fails closed", hugeDep, "animevideov3", NO},
                {@"fractional halo fails closed", fracHalo, "animevideov3", NO},
                {@"number flag fails closed", num123, "animevideov3", NO},
                {@"non-integer translation fails closed", notInteger, "animevideov3", NO},
                {@"realcugan never exact", good, "realcugan", NO},
                {@"unset model never exact", good, nil, NO},
            };
            for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); ++c) {
                [fm removeItemAtPath:manifestPath error:nil];
                if (cases[c].manifest)
                    [[NSJSONSerialization dataWithJSONObject:cases[c].manifest options:0
                        error:nil] writeToFile:manifestPath atomically:YES];
                if (cases[c].model) setenv("WINE_GDI_NEURAL_MODEL", cases[c].model, 1);
                else unsetenv("WINE_GDI_NEURAL_MODEL");
                base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                    scratch.fileSystemRepresentation);
                r = (WGDITemporalRenderer *)base;
                CHECK(r && [r testExactTranslation] == cases[c].exact,
                    cases[c].name.UTF8String);
                [r cancel]; [r release]; r = nil;
            }
            unsetenv("WINE_GDI_NEURAL_MODEL");
            [fm removeItemAtPath:scratch error:nil];
        }
        {
            setenv("WINE_GDI_UPSCALER", "adaptive", 1);
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "sfx adaptive presenter created");
            CHECK(r.testSpatialScaler == nil, "sfx scaler lazy");
            TestDriver *dfx = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            [dfx setOutputWidth:FW * 2 height:FH * 2];
            CHECK([dfx present:(const uint8_t *)background.bytes], "sfx present");
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "sfx frame completed");
            const BOOL supported = r.testSpatialScaler != nil;
            if (supported) {
                CHECK(r.testSpatialIn.width == FW && r.testSpatialIn.height == FH,
                      "sfx input size");
                id scaler0 = r.testSpatialScaler, in0 = r.testSpatialIn, out0 = r.testSpatialOut;
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx present2");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialScaler == scaler0 && r.testSpatialIn == in0 &&
                      r.testSpatialOut == out0, "sfx same geometry reuses");
                CHECK(r.testSpatialOut.width == FW * 2 && r.testSpatialOut.height == FH * 2,
                      "sfx output size");
                [dfx setOutputWidth:800 height:600];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx resized present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialOut.width == 800 && r.testSpatialOut.height == 600 &&
                      r.testSpatialScaler != scaler0, "sfx resize reconfigures");
                [dfx setOutputWidth:FW * 2 height:FH * 2];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx restore present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialScaler != nil, "sfx restored scaler");
                ((uint8_t *)background.mutableBytes)[0] ^= 1;
                [dfx setOutputWidth:FW height:FH];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx 1x present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && !r.testSpatialFailed, "sfx 1x skips spatial without latching failure");
                ((uint8_t *)background.mutableBytes)[0] ^= 1;
                [dfx setOutputWidth:320 height:240];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx downscale present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && !r.testSpatialFailed, "sfx downscale skips spatial without latching failure");
                ((uint8_t *)background.mutableBytes)[0] ^= 1;
                [dfx setOutputWidth:FW * 2 height:FH * 2];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx upscale after shrink");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialScaler != nil && !r.testSpatialFailed,
                      "sfx upscale active after 1x and downscale");
                [r testForceSpatialFailure];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx failed present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && !r.testFailed && r.testSpatialScaler == nil,
                      "sfx injected failure keeps temporal");
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx failed again");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialScaler == nil, "sfx failed geometry no retry");
                ((uint8_t *)background.mutableBytes)[0] ^= 1;
                [dfx setOutputWidth:900 height:600];
                CHECK([dfx present:(const uint8_t *)background.bytes], "sfx retry present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok && r.testSpatialScaler != nil && r.testSpatialOut.width == 900,
                      "sfx new output geometry retries");
                [dfx setOutputWidth:FW * 2 height:FH * 2];
            } else {
                CHECK(r.testSpatialFailed, "sfx unsupported marked failed");
            }
            if (supported) {
                NSMutableData *fixture = [NSMutableData dataWithLength:FW * FH * 4];
                uint32_t *fb = (uint32_t *)fixture.mutableBytes;
                for (NSUInteger y = 0; y < FH; ++y)
                    for (NSUInteger x = 0; x < FW; ++x) {
                        uint32_t c = x < FW / 2 ? 0xff4020e0 : 0xffe06020;
                        if (y > 200 && y < 232 && x > 100 && x < 540 &&
                            ((x - 100) / 40) % 2 == 0) c = 0xffffffff;
                        fb[y * FW + x] = c;
                    }
                CHECK([dfx present:(const uint8_t *)fixture.bytes], "sfx fixture present");
                ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
                CHECK(ok, "sfx fixture completed");
                const NSUInteger pw = r.testSpatialOut.width, ph = r.testSpatialOut.height;
                MTLTextureDescriptor *cd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                    width:pw height:ph mipmapped:NO];
                cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                id<MTLTexture> composite = [r.testDevice newTextureWithDescriptor:cd];
                MTLRenderPassDescriptor *cpd = [MTLRenderPassDescriptor renderPassDescriptor];
                cpd.colorAttachments[0].texture = composite;
                cpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                cpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                NSData *reads[2] = {nil, nil};
                for (unsigned s = 0; s < 2; ++s) {
                    struct wgdi_temporal_parameters q = {}; q.use_spatial = s;
                    id<MTLCommandBuffer> cmd = [r.testQueue commandBuffer];
                    id<MTLRenderCommandEncoder> enc =
                        [cmd renderCommandEncoderWithDescriptor:cpd];
                    [enc setRenderPipelineState:r.testRenderPS];
                    [enc setFragmentTexture:r.testCurrent atIndex:0];
                    [enc setFragmentTexture:r.testResidual atIndex:1];
                    [enc setFragmentTexture:r.testWeights atIndex:2];
                    [enc setFragmentTexture:r.testExclusionWeights atIndex:3];
                    [enc setFragmentTexture:r.testSpatialOut atIndex:4];
                    [enc setFragmentBytes:&q length:sizeof(q) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
                    reads[s] = readTexture(composite, r.testDevice, r.testQueue);
                }
                CHECK(reads[0].length == pw * ph * 4 && reads[1].length == pw * ph * 4 &&
                    memcmp(reads[0].bytes, reads[1].bytes, reads[0].length) != 0,
                    "sfx adaptive composite differs from bilinear baseline in memory");
                [composite release];
            }
            [r cancel]; [r release]; r = nil;
            unsetenv("WINE_GDI_UPSCALER");
        }
        {
            setenv("WINE_GDI_UPSCALER", "realcugan", 1);
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "snc presenter created");
            TestDriver *dnc = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            CHECK([dnc present:(const uint8_t *)background.bytes], "snc present");
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok && r.testSpatialScaler == nil, "snc realcugan makes no scaler");
            [r cancel]; [r release]; r = nil;
            unsetenv("WINE_GDI_UPSCALER");
        }
        {
            @autoreleasepool {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> tq = [dev newCommandQueue];
            NSError *ferr = nil;
            id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:[resources
                stringByAppendingPathComponent:@"temporal.metallib"]] error:&ferr];
            MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
            rd.vertexFunction = [lib newFunctionWithName:@"temporal_vertex"];
            rd.fragmentFunction = [lib newFunctionWithName:@"temporal_fragment"];
            rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            id<MTLRenderPipelineState> fps = [dev newRenderPipelineStateWithDescriptor:rd error:&ferr];
            CHECK(fps != nil, "sfrag pipeline");
            const unsigned N = 8;
            auto texBGRA = ^id<MTLTexture>(uint32_t pixel) {
                MTLTextureDescriptor *d = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                    width:N height:N mipmapped:NO];
                id<MTLTexture> t = [dev newTextureWithDescriptor:d];
                uint32_t row[N]; for (unsigned x = 0; x < N; ++x) row[x] = pixel;
                for (unsigned y = 0; y < N; ++y)
                    [t replaceRegion:MTLRegionMake2D(0, y, N, 1) mipmapLevel:0
                        withBytes:row bytesPerRow:N * 4];
                return [t autorelease];
            };
            auto texR8 = ^id<MTLTexture>(uint8_t v) {
                MTLTextureDescriptor *d = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                    width:N height:N mipmapped:NO];
                id<MTLTexture> t = [dev newTextureWithDescriptor:d];
                uint8_t row[N]; memset(row, v, N);
                for (unsigned y = 0; y < N; ++y)
                    [t replaceRegion:MTLRegionMake2D(0, y, N, 1) mipmapLevel:0
                        withBytes:row bytesPerRow:N];
                return [t autorelease];
            };
            id<MTLTexture> current = texBGRA(0xff604020), spatial = texBGRA(0xff00ff00);
            MTLTextureDescriptor *od = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:N height:N mipmapped:NO];
            od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            id<MTLTexture> outTex = [dev newTextureWithDescriptor:od];
            MTLTextureDescriptor *rdesc = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                width:N height:N mipmapped:NO];
            id<MTLTexture> residual = [dev newTextureWithDescriptor:rdesc];
            {
                uint16_t rdata[N * N * 4];
                for (unsigned i = 0; i < N * N * 4; ++i) rdata[i] = i % 4 == 0 ? 0x3800 : 0;
                [residual replaceRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0
                    withBytes:rdata bytesPerRow:N * 8];
            }
            MTLRenderPassDescriptor *fpd = [MTLRenderPassDescriptor renderPassDescriptor];
            fpd.colorAttachments[0].texture = outTex;
            fpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            fpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            auto renderCase = ^uint32_t(uint8_t keepV, uint8_t gateV, uint32_t useS) {
                id<MTLTexture> w8 = texR8(keepV), g8 = texR8(gateV);
                id<MTLCommandBuffer> cmd = [tq commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:fpd];
                struct wgdi_temporal_parameters q = {}; q.use_spatial = useS;
                [enc setRenderPipelineState:fps];
                [enc setFragmentTexture:current atIndex:0];
                [enc setFragmentTexture:residual atIndex:1];
                [enc setFragmentTexture:w8 atIndex:2];
                [enc setFragmentTexture:g8 atIndex:3];
                [enc setFragmentTexture:spatial atIndex:4];
                [enc setFragmentBytes:&q length:sizeof(q) atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
                uint32_t pixel = 0;
                [outTex getBytes:&pixel bytesPerRow:N * 4 fromRegion:MTLRegionMake2D(0, 0, 1, 1)
                    mipmapLevel:0];
                return pixel;
            };
            auto sEnc = [](float v) { return v <= 0.0031308f ? v * 12.92f
                : 1.055f * powf(v, 1.f / 2.4f) - 0.055f; };
            auto sDec = [](float v) { return v <= 0.04045f ? v / 12.92f
                : powf((v + 0.055f) / 1.055f, 2.4f); };
            const float base3[3] = {sDec(0x60 / 255.f), sDec(0x40 / 255.f), sDec(0x20 / 255.f)};
            const float sp3[3] = {0.f, 1.f, 0.f};
            const float detail3[3] = {0.5f, 0.f, 0.f};
            auto expect = [&](float keep, float gate, int useS) {
                uint32_t px = 0xff000000u;
                const int shift[3] = {16, 8, 0};
                for (int c = 0; c < 3; ++c) {
                    float v = base3[c] + keep * detail3[c] +
                        (useS ? (1 - keep) * gate * (sp3[c] - base3[c]) : 0.f);
                    px |= (uint32_t)lroundf(fminf(fmaxf(sEnc(v), 0.f), 1.f) * 255.f) << shift[c];
                }
                return px;
            };
            struct { uint8_t keep, gate; uint32_t useS; } fcases[] = {
                {0, 255, 1}, {255, 255, 1}, {128, 255, 1}, {0, 0, 1}, {255, 255, 0}};
            for (unsigned c = 0; c < sizeof(fcases) / sizeof(fcases[0]); ++c) {
                const uint32_t got = renderCase(fcases[c].keep, fcases[c].gate, fcases[c].useS);
                const uint32_t want = expect(fcases[c].keep / 255.f, fcases[c].gate / 255.f,
                    fcases[c].useS);
                int diff = 0;
                for (int b = 0; b < 4; ++b)
                    diff = MAX(diff, abs(int((got >> (8 * b)) & 0xff) - int((want >> (8 * b)) & 0xff)));
                CHECK(diff <= 1, "sfrag formula case");
            }
            [tq release]; [lib release]; [rd release];
            }
        }

        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11p presenter created");
            TestDriver *dp = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *frame = [NSMutableData dataWithLength:FW * FH * 4];
            for (unsigned i = 0; i < 100; ++i) {
                memset(frame.mutableBytes, (i * 37) & 0xff, frame.length);
                CHECK([dp present:(const uint8_t *)frame.bytes], "s11p present");
                waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            }
            CHECK(r.testSourceSlotCount <= 3 && r.testSourceSlotCount > 0,
                  "s11p upload pool bounded");
            CHECK(r.testMetadataSlotCount <= 2 && r.testMetadataSlotCount > 0,
                  "s11p metadata pool bounded");
            [r cancel]; [r release]; r = nil;
        }
        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11t presenter created");
            TestDriver *dt = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            id<MTLBuffer> hog = [r.testDevice newBufferWithLength:64u * 1024 * 1024
                options:MTLResourceStorageModePrivate];
            id<MTLCommandBuffer> hogCmd = [r.testQueue commandBuffer];
            id<MTLBlitCommandEncoder> hb = [hogCmd blitCommandEncoder];
            [hb fillBuffer:hog range:NSMakeRange(0, hog.length) value:0xAB];
            [hb endEncoding]; [hogCmd commit];
            for (unsigned i = 0; i < 4; ++i) {
                ((uint8_t *)background.mutableBytes)[16 + i] = (uint8_t)i;
                CHECK([dt present:(const uint8_t *)background.bytes], "s11t present");
            }
            CHECK(r.testFramesInFlight <= 2, "s11t third frame throttled");
            waitFor(r, ^{ return r.testFramesInFlight == 0; }, 15.0);
            [hog release];
            [r cancel]; [r release]; r = nil;
        }
        {
            @autoreleasepool {
            unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11f presenter created");
            NSMutableData *frameA = [NSMutableData dataWithLength:FW * FH * 4];
            memset(frameA.mutableBytes, 0x41, frameA.length);
            CGImageRef imgA = makeImage((const uint8_t *)frameA.bytes, FW, FH);
            CHECK([r presentImage:imgA inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                width:FW height:FH request:nil needsDisplay:nil], "s11f present A");
            CGImageRelease(imgA);
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(r.testFramesInFlight == 0, "s11f seeded");
            NSData *mirrorCopy = [NSData dataWithBytes:r.testMirror.contents
                length:FW * FH * 4];
            const NSUInteger stride = r.testInputStride;
            NSMutableData *sourceCopy = [NSMutableData dataWithLength:FW * FH * 4];
            const uint8_t *su = (const uint8_t *)r.testAnalysedUpload.contents;
            for (NSUInteger y = 0; y < FH; ++y)
                memcpy((uint8_t *)sourceCopy.mutableBytes + y * FW * 4,
                       su + y * stride, FW * 4);
            requestCount = requestToken = 0;
            [requestInput release]; requestInput = nil;
            [r testSnapshotTile:0 request:makeRequest()];
            id<MTLCommandBuffer> owc = [r.testQueue commandBuffer];
            id<MTLBlitCommandEncoder> owb = [owc blitCommandEncoder];
            [owb fillBuffer:r.testMirror range:NSMakeRange(0, r.testMirror.length) value:0xCD];
            [owb endEncoding]; [owc commit]; [owc waitUntilCompleted];
            id<MTLBuffer> bufferB = [r.testDevice newBufferWithLength:stride * FH
                options:MTLResourceStorageModeShared];
            memset(bufferB.contents, 0x33, stride * FH);
            [r testSetAnalysedUpload:bufferB];
            for (unsigned i = 0; i < 1500 && !requestCount; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            ok = requestCount >= 1 && requestInput &&
                requestInput.length == FW * FH * 4;
            CHECK(ok, "s11f request arrived");
            NSData *mask = [r selectedTilesForToken:requestToken];
            const NSUInteger tiles = ((FW + 255) / 256) * ((FH + 255) / 256);
            ok = ok && mask && mask.length == tiles * 4;
            if (!ok) { CHECK(NO, "s11f valid request/mask");
                [bufferB release]; [r cancel]; [r release]; r = nil; }
            else {
            const uint32_t *sel = (const uint32_t *)mask.bytes;
            unsigned selectedCount = 0;
            for (NSUInteger i = 0; i < tiles; ++i) selectedCount += sel[i] != 0;
            CHECK(selectedCount == 1 && sel[0] == 1, "s11f mask selects tile0");
            const uint8_t *ri = (const uint8_t *)requestInput.bytes;
            const uint8_t *exp = (const uint8_t *)mirrorCopy.bytes;
            const uint8_t *src = (const uint8_t *)sourceCopy.bytes;
            unsigned unsel = 0; BOOL frozenOK = YES, selectedOK = YES;
            for (NSUInteger ty = 0; ty < 2; ++ty)
                for (NSUInteger tx = 0; tx < 3; ++tx) {
                    const NSUInteger t = ty * 3 + tx;
                    const NSUInteger tw = MIN(FW - tx * 256, 256) * 4;
                    for (NSUInteger y = ty * 256; y < ty * 256 + 256 && y < FH; ++y) {
                        const NSUInteger off = y * FW * 4 + tx * 1024;
                        if (!sel[t]) {
                            if (memcmp(ri + off, exp + off, tw)) frozenOK = NO;
                        } else {
                            if (memcmp(ri + off, src + off, tw)) selectedOK = NO;
                        }
                    }
                    if (!sel[t]) ++unsel;
                }
            CHECK(unsel >= 1 && frozenOK, "s11f unselected from frozen mirror");
            CHECK(selectedOK, "s11f selected from captured source");
            [bufferB release]; [r cancel]; [r release]; r = nil;
            }
            }
        }
        {
            @autoreleasepool {
            setenv("WINE_GDI_TEMPORAL_LIBRARY_MB", "0", 1);
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11c presenter created");
            TestDriver *dc = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            NSMutableData *frameA = [NSMutableData dataWithLength:FW * FH * 4];
            memset(frameA.mutableBytes, 0x41, frameA.length);
            CHECK([dc present:(const uint8_t *)frameA.bytes], "s11c present A");
            for (unsigned i = 0; i < 1500 && !requestCount; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            answerPending(r);
            for (unsigned i = 0; i < 1500 && (r.testPendingToken || r.testFramesInFlight); ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            NSMutableData *frameB = [NSMutableData dataWithData:frameA];
            for (NSUInteger y = 0; y < FH; ++y)
                memset((uint8_t *)frameB.mutableBytes + (y * FW + 256) * 4, 0x77, 4);
            requestCount = requestToken = 0;
            CHECK([dc present:(const uint8_t *)frameB.bytes], "s11c present B");
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            requestCount = requestToken = 0;
            [requestInput release]; requestInput = nil;
            [r testSnapshotTile:1 request:makeRequest()];
            for (unsigned i = 0; i < 1500 && !requestCount; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(requestCount >= 1, "s11c request arrived");
            answerPending(r);
            for (unsigned i = 0; i < 1500 && (r.testPendingToken || r.testFramesInFlight); ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            const float *times = (const float *)r.testTimes.contents;
            const unsigned BC2 = (FW + 15) / 16;
            CHECK(times[6 * BC2 + 16] >= 0, "s11c tile1 block valid");
            CHECK(times[6 * BC2 + 15] < 0, "s11c neighbor invalidated");
            CHECK(times[6 * BC2 + 2] >= 0, "s11c far block stays valid");
            unsetenv("WINE_GDI_TEMPORAL_LIBRARY_MB");
            [r cancel]; [r release]; r = nil;
            }
        }
        {
            @autoreleasepool {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> tq = [dev newCommandQueue];
            NSError *ferr = nil;
            id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:[resources
                stringByAppendingPathComponent:@"temporal.metallib"]] error:&ferr];
            id<MTLComputePipelineState> invPS = [dev newComputePipelineStateWithFunction:
                [lib newFunctionWithName:@"temporal_library_invalidate"] error:&ferr];
            id<MTLComputePipelineState> fixPS = [dev newComputePipelineStateWithFunction:
                [lib newFunctionWithName:@"temporal_library_fixup"] error:&ferr];
            CHECK(invPS && fixPS, "s11i pipelines");
            MTLTextureDescriptor *cd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                width:8 height:1 mipmapped:NO];
            cd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            id<MTLTexture> changes = [dev newTextureWithDescriptor:cd];
            {
                uint8_t row[8] = {};
                row[3] = 4;
                [changes replaceRegion:MTLRegionMake2D(0, 0, 8, 1) mipmapLevel:0
                    withBytes:row bytesPerRow:8];
            }
            float timesBuf[8]; uint32_t provBuf[8] = {}, metaBuf[8] = {};
            typedef struct { uint32_t x, y, z, w; } MatchRec;
            MatchRec matchBuf[8] = {};
            for (unsigned i = 0; i < 8; ++i) timesBuf[i] = 1.0f;
            matchBuf[3] = (MatchRec){1, 0, 0, 1};
            id<MTLBuffer> times = [dev newBufferWithBytes:timesBuf length:sizeof(timesBuf)
                options:MTLResourceStorageModeShared];
            id<MTLBuffer> prov = [dev newBufferWithBytes:provBuf length:sizeof(provBuf)
                options:MTLResourceStorageModeShared];
            id<MTLBuffer> meta = [dev newBufferWithBytes:metaBuf length:sizeof(metaBuf)
                options:MTLResourceStorageModeShared];
            id<MTLBuffer> matches = [dev newBufferWithBytes:matchBuf length:sizeof(matchBuf)
                options:MTLResourceStorageModeShared];
            struct wgdi_temporal_library_parameters lp = {};
            lp.slot_count = 1; lp.table_mask = 7; lp.width = 128; lp.height = 16;
            lp.time = 2.0f; lp.fade_seconds = 0.4f;
            id<MTLCommandBuffer> cmd = [tq commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:invPS];
            [enc setTexture:changes atIndex:0];
            [enc setTexture:changes atIndex:1];
            [enc setBuffer:times offset:0 atIndex:0];
            [enc setBuffer:prov offset:0 atIndex:1];
            [enc setBuffer:matches offset:0 atIndex:2];
            [enc setBytes:&lp length:sizeof(lp) atIndex:3];
            [enc dispatchThreadgroups:MTLSizeMake(8, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 1, 1)];
            [enc endEncoding];
            enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:fixPS];
            [enc setTexture:changes atIndex:0];
            [enc setBuffer:meta offset:0 atIndex:0];
            [enc setBuffer:times offset:0 atIndex:1];
            [enc setBuffer:prov offset:0 atIndex:2];
            [enc setBuffer:matches offset:0 atIndex:3];
            [enc setBytes:&lp length:sizeof(lp) atIndex:4];
            [enc dispatchThreadgroups:MTLSizeMake(8, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 1, 1)];
            [enc endEncoding];
            [cmd commit]; [cmd waitUntilCompleted];
            const float *tt = (const float *)times.contents;
            const uint32_t *mm = (const uint32_t *)meta.contents;
            const uint32_t *pp = (const uint32_t *)prov.contents;
            CHECK(tt[0] == 1.0f && tt[7] == 1.0f, "s11i far blocks keep times");
            CHECK(tt[2] < 0 && tt[4] < 0, "s11i neighbors invalidated");
            CHECK(tt[1] < 0 && tt[5] < 0, "s11i halo spans two blocks");
            CHECK((mm[2] & 1) && (mm[4] & 1), "s11i invalidated join dirty");
            CHECK(pp[3] == 0 && tt[3] >= 0, "s11i matched keeps exact path");
            [tq release]; [lib release]; [invPS release]; [fixPS release];
            }
        }
        {
            @autoreleasepool {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11u presenter created");
            NSDictionary *props = @{
                @"IOSurfaceWidth": @(FW), @"IOSurfaceHeight": @(FH),
                @"IOSurfacePixelFormat": @(0x42475241),
                @"IOSurfaceBytesPerElement": @4};
            IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)props);
            CHECK(surface != NULL, "s11u surface");
            IOSurfaceLock(surface, 0, NULL);
            const NSUInteger sstride = IOSurfaceGetBytesPerRow(surface);
            for (NSUInteger y = 0; y < FH; ++y) {
                uint8_t *sp = (uint8_t *)IOSurfaceGetBaseAddress(surface) + y * sstride;
                for (NSUInteger x = 0; x < FW; ++x) {
                    sp[x * 4] = 0x10; sp[x * 4 + 1] = 0x80;
                    sp[x * 4 + 2] = 0xE0; sp[x * 4 + 3] = 0xff;
                }
            }
            IOSurfaceUnlock(surface, 0, NULL);
            std::vector<std::shared_ptr<std::atomic<unsigned>>> counters;
            counters.push_back(std::make_shared<std::atomic<unsigned>>(0));
            CHECK([r presentSurface:surface inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                width:FW height:FH request:nil needsDisplay:nil
                sourceConsumed:^{ ++(*counters.back()); }], "s11u present");
            for (unsigned i = 0; i < 1500 && (r.testFramesInFlight || !*counters[0]); ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(*counters[0] == 1 && r.testFramesInFlight == 0, "s11u consumed once");
            IOSurfaceLock(surface, 0, NULL);
            memset(IOSurfaceGetBaseAddress(surface), 0x00, sstride * FH);
            IOSurfaceUnlock(surface, 0, NULL);
            NSData *cur = readTexture(r.testCurrent, r.testDevice, r.testQueue);
            const uint8_t *cp = (const uint8_t *)cur.bytes;
            CHECK(cur.length >= 16 && cp[0] == 0x10 && cp[1] == 0x80 && cp[2] == 0xE0,
                  "s11u current stays immutable");
            for (unsigned i = 0; i < 4; ++i) {
                counters.push_back(std::make_shared<std::atomic<unsigned>>(0));
                std::shared_ptr<std::atomic<unsigned>> c = counters.back();
                [r presentSurface:surface inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                    width:FW height:FH request:nil needsDisplay:nil
                    sourceConsumed:^{ ++(*c); }];
            }
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            BOOL allOnce = YES;
            for (const auto &c : counters) allOnce = allOnce && *c == 1;
            CHECK(allOnce, "s11u every request consumed once");
            CHECK(r.testSurfaceSlotCount <= 3 && r.testSurfaceCacheCount == 1,
                  "s11u pools bounded");
            CHECK(r.testBusyTotals == 0, "s11u slots all free");
            counters.push_back(std::make_shared<std::atomic<unsigned>>(0));
            std::shared_ptr<std::atomic<unsigned>> c3 = counters.back();
            [r presentSurface:nil inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                width:FW height:FH request:nil needsDisplay:nil
                sourceConsumed:^{ ++(*c3); }];
            CHECK(*c3 == 1, "s11u nil consumed once");
            {
                id<MTLBuffer> hog = [r.testDevice newBufferWithLength:64u * 1024 * 1024
                    options:MTLResourceStorageModePrivate];
                id<MTLCommandBuffer> hogCmd = [r.testQueue commandBuffer];
                id<MTLBlitCommandEncoder> hb = [hogCmd blitCommandEncoder];
                [hb fillBuffer:hog range:NSMakeRange(0, hog.length) value:0xAB];
                [hb endEncoding]; [hogCmd commit];
                IOSurfaceRef surf4[4];
                std::shared_ptr<std::atomic<unsigned>> dcounts[4];
                WGDITemporalRenderer *weakR = r;
                __block void (^redrawSurf)(void) = nil;
                void (^redrawBlock)(void) = [^{
                    [weakR presentLatestInLayer:parent frame:CGRectMake(0, 0, FW, FH)
                        width:FW height:FH request:nil needsDisplay:redrawSurf];
                } copy];
                redrawSurf = redrawBlock;
                for (unsigned k = 0; k < 4; ++k) {
                    surf4[k] = IOSurfaceCreate((CFDictionaryRef)props);
                    IOSurfaceLock(surf4[k], 0, NULL);
                    memset(IOSurfaceGetBaseAddress(surf4[k]), 0x11 * (k + 1),
                        IOSurfaceGetBytesPerRow(surf4[k]) * FH);
                    IOSurfaceUnlock(surf4[k], 0, NULL);
                    dcounts[k] = std::make_shared<std::atomic<unsigned>>(0);
                    std::shared_ptr<std::atomic<unsigned>> ck = dcounts[k];
                    [r presentSurface:surf4[k] inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                        width:FW height:FH request:nil needsDisplay:redrawSurf
                        sourceConsumed:^{ ++(*ck); }];
                }
                for (unsigned i = 0; i < 1500; ++i) {
                    BOOL done = r.testFramesInFlight == 0 && r.testBusyTotals == 0;
                    for (unsigned k = 0; k < 4; ++k) done = done && *dcounts[k] == 1;
                    if (done) break;
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
                }
                BOOL allFourOnce = YES;
                for (unsigned k = 0; k < 4; ++k) allFourOnce = allFourOnce && *dcounts[k] == 1;
                NSData *cur4 = readTexture(r.testCurrent, r.testDevice, r.testQueue);
                const uint8_t *cp4 = (const uint8_t *)cur4.bytes;
                CHECK(allFourOnce && cp4[0] == 0x44 && cp4[1] == 0x44 && cp4[2] == 0x44,
                      "s11u deferred surface lands final frame and consumes all once");
                redrawSurf = nil;
                [redrawBlock release];
                for (unsigned k = 0; k < 4; ++k) CFRelease(surf4[k]);
                [hog release];
            }
            {
                IOSurfaceRef lruSurf[10];
                for (unsigned k = 0; k < 10; ++k) {
                    lruSurf[k] = IOSurfaceCreate((CFDictionaryRef)props);
                    IOSurfaceLock(lruSurf[k], 0, NULL);
                    memset(IOSurfaceGetBaseAddress(lruSurf[k]), 0x50 + k,
                        IOSurfaceGetBytesPerRow(lruSurf[k]) * FH);
                    IOSurfaceUnlock(lruSurf[k], 0, NULL);
                    [r presentSurface:lruSurf[k] inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                        width:FW height:FH request:nil needsDisplay:nil
                        sourceConsumed:^{}];
                    for (unsigned i = 0; i < 500 && r.testFramesInFlight; ++i)
                        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
                }
                CHECK(r.testSurfaceCacheCount == 8 &&
                    CFGetRetainCount(lruSurf[0]) == 1 && CFGetRetainCount(lruSurf[1]) == 1,
                    "s11u 8-entry surface LRU evicts and releases oldest surfaces");
                for (unsigned k = 0; k < 10; ++k) CFRelease(lruSurf[k]);
            }
            CFRelease(surface);
            [r cancel]; [r release]; r = nil;
            }
        }
        {
            @autoreleasepool {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11g presenter created");
            NSMutableData *frameE = [NSMutableData dataWithLength:FW * FH * 4];
            memset(frameE.mutableBytes, 0x55, frameE.length);
            for (unsigned i = 0; i < 2; ++i) {
                CGImageRef img = makeImage((const uint8_t *)frameE.bytes, FW, FH);
                [r presentImage:img inLayer:parent frame:CGRectMake(0, 0, FW, FH)
                    width:FW height:FH request:nil needsDisplay:nil];
                CGImageRelease(img);
            }
            CHECK(r.testFramesInFlight == 2, "s11g two in flight");
            const uint64_t oldEpoch = r.testEpoch;
            setenv("WINE_GDI_UPSCALER_EXCLUDE", "8,8,64,64", 1);
            NSMutableData *frameN = [NSMutableData dataWithLength:320 * 240 * 4];
            for (NSUInteger i = 0; i < 320 * 240; ++i) {
                uint8_t *px = (uint8_t *)frameN.mutableBytes + i * 4;
                px[0] = 0x22; px[1] = 0x99; px[2] = 0xCC; px[3] = 0xff;
            }
            CGImageRef imgN = makeImage((const uint8_t *)frameN.bytes, 320, 240);
            [r presentImage:imgN inLayer:parent frame:CGRectMake(0, 0, 320, 240)
                width:320 height:240 request:nil needsDisplay:nil];
            CGImageRelease(imgN);
            CHECK(r.testEpoch != oldEpoch && !r.testFailed, "s11g epoch changed");
            for (unsigned i = 0; i < 1500 && (r.testFramesInFlight ||
                r.testBusyTotals); ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(r.testBusyTotals == 0, "s11g new pool not corrupted");
            CGImageRef imgN2 = makeImage((const uint8_t *)frameN.bytes, 320, 240);
            CHECK([r presentImage:imgN2 inLayer:parent
                frame:CGRectMake(0, 0, 320, 240) width:320 height:240
                request:nil needsDisplay:nil], "s11g new geometry present");
            CGImageRelease(imgN2);
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            NSData *curN = readTexture(r.testCurrent, r.testDevice, r.testQueue);
            const uint8_t *np = (const uint8_t *)curN.bytes;
            CHECK(r.testCurrent.width == 320 && r.testCurrent.height == 240 &&
                np[0] == 0x22 && np[1] == 0x99 && np[2] == 0xCC,
                  "s11g new current exact");
            CHECK(r.testBusyTotals == 0 && r.testSourceSlotCount <= 3 &&
                r.testSurfaceSlotCount <= 3, "s11g pools bounded");
            unsetenv("WINE_GDI_UPSCALER_EXCLUDE");
            [r cancel]; [r release]; r = nil;
            }
        }
        {
            @autoreleasepool {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11e presenter created");
            TestDriver *de = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            CHECK([de present:(const uint8_t *)background.bytes], "s11e present");
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            for (unsigned i = 0; i < 200 && (requestToken || r.testPendingToken ||
                r.testSnapshotPending || r.testFramesInFlight); ++i) {
                if (requestToken) answerPending(r);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, true);
            for (unsigned i = 0; i < 200 && (requestToken || r.testPendingToken ||
                r.testSnapshotPending); ++i) {
                if (requestToken) answerPending(r);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
            for (unsigned i = 0; i < 40; ++i) {
                NSUInteger s0 = r.testFrameSequence;
                [de present:(const uint8_t *)background.bytes];
                for (unsigned j = 0; j < 500 && r.testFramesInFlight; ++j)
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
                for (unsigned j = 0; j < 200 && (requestToken || r.testPendingToken ||
                    r.testSnapshotPending); ++j) {
                    if (requestToken) answerPending(r);
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
                }
                if (r.testFrameSequence == s0) break;
            }
            const NSUInteger seq0 = r.testFrameSequence;
            for (unsigned i = 0; i < 100; ++i)
                [r presentLatestInLayer:parent frame:CGRectMake(0, 0, FW, FH)
                    width:FW height:FH request:nil needsDisplay:nil];
            CHECK(r.testFrameSequence == seq0, "s11e presentLatest idle");
            [r testSetPendingToken:7];
            CHECK([de present:(const uint8_t *)background.bytes], "s11e pending presents");
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(r.testFrameSequence > seq0, "s11e pending commits");
            [r testSetPendingToken:0];
            const double now = [r testNow];
            [r testSetLastRendered:now - 0.1];
            [r testSetFadeUntil:now - 0.01];
            const NSUInteger seqBeforeFade = r.testFrameSequence;
            CHECK([de present:(const uint8_t *)background.bytes], "s11e fade tail presents");
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(r.testFrameSequence > seqBeforeFade, "s11e final fade frame commits");
            for (unsigned i = 0; i < 200 && (requestToken || r.testPendingToken ||
                r.testSnapshotPending); ++i) {
                if (requestToken) answerPending(r);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            const NSUInteger seq2 = r.testFrameSequence;
            [de present:(const uint8_t *)background.bytes];
            CHECK(r.testFrameSequence == seq2, "s11e idle after fade matured");
            [r.testLayer removeFromSuperlayer];
            CHECK(r.testLayer.superlayer == nil, "s11e layer detached");
            CHECK([de present:(const uint8_t *)background.bytes], "s11e layer removed");
            for (unsigned i = 0; i < 1500 && r.testFramesInFlight; ++i)
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
            CHECK(r.testLayer.superlayer == parent &&
                r.testFrameSequence > seq2, "s11e removed layer re-presents");
            [r cancel]; [r release]; r = nil;
            }
        }
        {
            base = wine_gdi_temporal_create(WGDI_TEMPORAL_PRESENTER_ABI,
                resources.fileSystemRepresentation);
            r = (WGDITemporalRenderer *)base;
            CHECK(r != nil, "s11s presenter created");
            TestDriver *ds = [[[TestDriver alloc] initWithRenderer:r parent:parent
                width:FW height:FH] autorelease];
            requestCount = requestToken = 0;
            CHECK([ds present:(const uint8_t *)background.bytes], "s11s present");
            ok = waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(ok, "s11s seeded");
            for (unsigned i = 0; i < 200 && requestToken == 0; ++i) {
                [ds present:(const uint8_t *)background.bytes];
                waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            }
            for (unsigned i = 0; i < 200 && (requestToken || r.testPendingToken); ++i) {
                if (requestToken) answerPending(r);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, true);
            for (unsigned i = 0; i < 200 && (requestToken || r.testPendingToken); ++i) {
                if (requestToken) answerPending(r);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
            }
            waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            const NSUInteger seq0 = r.testFrameSequence;
            for (unsigned i = 0; i < 100; ++i)
                [ds present:(const uint8_t *)background.bytes];
            CHECK(r.testFrameSequence == seq0, "s11s settled frames stay idle");
            ((uint8_t *)background.mutableBytes)[FW * FH * 2] ^= 0x40;
            CHECK([ds present:(const uint8_t *)background.bytes], "s11s masked text");
            waitFor(r, ^{ return r.testFramesInFlight == 0; }, 10.0);
            CHECK(r.testFrameSequence > seq0, "s11s masked change renders");
            [r cancel]; [r release]; r = nil;
        }

        printf("%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
        return failures ? 1 : 0;
    }
}
