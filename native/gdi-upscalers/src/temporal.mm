/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dlfcn.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define WGDI_TEMPORAL_METALFX 1
#endif
#include "wine_gdi_temporal.h"
#include "wine_gdi_temporal_presenter.h"
#include "wine_gdi_exclusions.h"

static_assert(sizeof(wgdi_temporal_parameters) == 52, "Metal parameter layout changed");
static_assert(sizeof(wgdi_temporal_library_parameters) == 104, "Metal library parameter layout changed");
#define WGDI_TEMPORAL_VOLATILE_CHURN 3

@interface WGDITemporalRenderer : NSObject <WGDITemporalPresenter>
{
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> resetPS, seedPS, detectPS, maskPS, acceptPS, inputPS, residualPS, timesPS;
    id<MTLComputePipelineState> validPS, indexPS, hashPS, probePS, applyResidualPS, applyInputPS, fixupPS, invalidatePS;
    id<MTLRenderPipelineState> renderPS;
    CAMetalLayer *displayLayer;
    id<MTLTexture> referenceTexture, residualTexture, previousTexture, currentTexture, changesTexture, weightsTexture, analysedTexture;
    id<MTLBuffer> referenceTimes, previousUpload, analysedUpload;
    id<MTLTexture> exclusionTexture, exclusionWeightTexture;
    id<MTLBuffer> exclusionBuffer, exclusionWeightBuffer;
    NSUInteger exclusionWeightStride;
    struct wgdi_exclusions exclusionMask;
    unsigned exclusionCount;
    BOOL exactTranslation;
    BOOL adaptive, spatialFailed;
    CGSize attemptIn, attemptOut;
    id spatialScaler;
    id<MTLTexture> spatialIn, spatialOut;
    NSUInteger spatialInW, spatialInH, spatialOutW, spatialOutH;
    struct { id<MTLBuffer> buffer; id<MTLTexture> texture; CGContextRef bitmap;
        unsigned busy; } sourceSlots[3];
    unsigned sourceSlotCount;
    struct { id<MTLTexture> texture; unsigned busy; } surfaceSlots[3];
    unsigned surfaceSlotCount;
    struct { IOSurfaceRef surface; id<MTLTexture> wrapper; uint64_t stamp; } surfaceCache[8];
    unsigned surfaceCacheCount;
    uint64_t surfaceCacheClock;
    IOSurfaceRef deferredSurface;
    void (^deferredConsumed)(void);
    struct { id<MTLBuffer> metadata, stats, hits; unsigned busy; } metaSlots[2];
    unsigned metaSlotCount, lastMetaSubmitted;
    id<MTLBuffer> snapshotStaging;
    double lastRenderedParamTime;
    CALayer *lastPresentedParent;
    CGRect lastPresentedFrame;
    CGSize lastDrawableSize;
    id<MTLBuffer> referenceMirror;
    NSMutableData *pendingSelection, *pendingVersions;
    NSData *pendingInput;
    /* Multi-source block residual library: slots of accepted (input, residual)
     * state indexed by content hash for translation reuse. */
    id<MTLBuffer> provisionalFlags, matchRecords, libraryStats, libraryHits;
    id<MTLBuffer> libraryTable, libraryValid;
    id<MTLTexture> slotInputs[16], slotResiduals[16], dummySlotTexture;
    NSData *slotHashes[16];
    /* Per-position store-difference counter: blocks that differ across enough
     * successive snapshots (dialogue text, counters) are volatile and never
     * keep an otherwise redundant slot alive. */
    NSMutableData *blockChurn;
    NSData *lastStoredHashes;
    BOOL slotActive[16];
    double slotStoreTime[16], slotLastHit[16];
    NSUInteger librarySlots, libraryEntries, libraryBudgetMB;
    struct wgdi_temporal_scheduler schedule;
    NSUInteger inputWidth, inputHeight, inputStride, exclusionStride, framesInFlight;
    uint64_t frameSequence, nextToken, pendingToken, pendingEpoch;
    double origin, fadeUntil;
    BOOL cancelled, failed, neuralDisabled, timerPending, seeded, trace, snapshotPending;
    BOOL libraryLogged, libraryPipelines;
}
- (id)initWithResources:(NSString *)resources;
@end

@implementation WGDITemporalRenderer
- (double)now { return NSProcessInfo.processInfo.systemUptime - origin; }
- (CALayer *)layer { return displayLayer; }
- (id<MTLComputePipelineState>)pipeline:(NSString *)name library:(id<MTLLibrary>)library
{
    id<MTLFunction> function = [library newFunctionWithName:name];
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
    [function release];
    if (!pipeline) NSLog(@"Wine temporal: pipeline %@ unavailable (%@)", name, error);
    return pipeline;
}
- (id)initWithResources:(NSString *)resources
{
    self = [super init];
    if (!self) return nil;
    origin = NSProcessInfo.processInfo.systemUptime;
    const char *traceMode=getenv("WINE_GDI_TEMPORAL_TRACE");
    trace=traceMode && !strcmp(traceMode,"1");
    const char *libraryMB=getenv("WINE_GDI_TEMPORAL_LIBRARY_MB");
    libraryBudgetMB=libraryMB ? (NSUInteger)strtoul(libraryMB,NULL,10) : 384;
    const char *neuralModel=getenv("WINE_GDI_NEURAL_MODEL");
    if (neuralModel && !strcmp(neuralModel,"animevideov3")) {
        NSString *manifestPath=[[resources stringByAppendingPathComponent:@"coreml"]
            stringByAppendingPathComponent:@"manifest.json"];
        NSData *data=[NSData dataWithContentsOfFile:manifestPath];
        id manifest=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        id models=[manifest isKindOfClass:NSDictionary.class]?manifest[@"temporal_models"]:nil;
        id temporal=[models isKindOfClass:NSDictionary.class]?models[@"animevideov3"]:nil;
        id inputHalo=[temporal isKindOfClass:NSDictionary.class]?temporal[@"input_halo"]:nil;
        id dependencyHalo=[temporal isKindOfClass:NSDictionary.class]?temporal[@"dependency_halo"]:nil;
        id integerTranslation=[temporal isKindOfClass:NSDictionary.class]?temporal[@"integer_translation"]:nil;
        BOOL booleanFlag = integerTranslation &&
            CFGetTypeID((CFTypeRef)integerTranslation)==CFBooleanGetTypeID() &&
            [(__bridge NSNumber *)integerTranslation boolValue];
        exactTranslation=booleanFlag &&
            [inputHalo isKindOfClass:NSNumber.class] &&
            CFGetTypeID((CFTypeRef)inputHalo)!=CFBooleanGetTypeID() &&
            [inputHalo doubleValue]>=19.0 && [inputHalo doubleValue]<=64.0 &&
            [inputHalo doubleValue]==(double)[inputHalo longLongValue] &&
            [dependencyHalo isKindOfClass:NSNumber.class] &&
            CFGetTypeID((CFTypeRef)dependencyHalo)!=CFBooleanGetTypeID() &&
            [dependencyHalo doubleValue]==19.0 &&
            [dependencyHalo longLongValue]==19;
    }
    const char *upscalerMode=getenv("WINE_GDI_UPSCALER");
    adaptive=upscalerMode && !strcmp(upscalerMode,"adaptive");
    device = MTLCreateSystemDefaultDevice();
    queue = [device newCommandQueue];
    queue.label=@"wine.gdi.temporal";
    NSError *error = nil;
    NSString *path = [resources stringByAppendingPathComponent:@"temporal.metallib"];
    id<MTLLibrary> library = path ? [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error] : nil;
    if (!library || !queue) { NSLog(@"Wine temporal: Metal library unavailable (%@)", error); [library release]; [self release]; return nil; }
    resetPS = [self pipeline:@"temporal_reset" library:library];
    seedPS = [self pipeline:@"temporal_seed" library:library];
    detectPS = [self pipeline:@"temporal_detect" library:library];
    maskPS = [self pipeline:@"temporal_mask" library:library];
    acceptPS = [self pipeline:@"temporal_accept" library:library];
    inputPS = [self pipeline:@"temporal_commit_input" library:library];
    residualPS = [self pipeline:@"temporal_commit_residual" library:library];
    timesPS = [self pipeline:@"temporal_commit_times" library:library];
    validPS = [self pipeline:@"temporal_library_valid" library:library];
    indexPS = [self pipeline:@"temporal_library_index" library:library];
    hashPS = [self pipeline:@"temporal_library_block_hash" library:library];
    probePS = [self pipeline:@"temporal_library_probe" library:library];
    applyResidualPS = [self pipeline:@"temporal_library_apply_residual" library:library];
    applyInputPS = [self pipeline:@"temporal_library_apply_input" library:library];
    fixupPS = [self pipeline:@"temporal_library_fixup" library:library];
    invalidatePS = [self pipeline:@"temporal_library_invalidate" library:library];
    libraryPipelines = validPS && indexPS && hashPS && probePS && applyResidualPS &&
        applyInputPS && fixupPS && invalidatePS;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"temporal_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"temporal_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    renderPS = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    [descriptor.vertexFunction release]; [descriptor.fragmentFunction release];
    [descriptor release]; [library release];
    if (!resetPS || !seedPS || !detectPS || !maskPS || !acceptPS || !inputPS || !residualPS || !timesPS || !renderPS) {
        [self release]; return nil;
    }
    displayLayer = [CAMetalLayer new];
    displayLayer.device = device;
    displayLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    displayLayer.framebufferOnly = YES;
    displayLayer.opaque = YES;
    displayLayer.maximumDrawableCount = 2;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    displayLayer.colorspace = space; CGColorSpaceRelease(space);
    displayLayer.actions = @{@"contents":NSNull.null, @"bounds":NSNull.null,
        @"position":NSNull.null, @"hidden":NSNull.null};
    return self;
}
- (void)clearGeometry
{
    wgdi_temporal_clear(&schedule);
    [self clearSpatial]; spatialFailed=NO; attemptIn=attemptOut=CGSizeZero;
    [self clearPools];
    [referenceTexture release]; referenceTexture = nil;
    [residualTexture release]; residualTexture = nil;
    [previousTexture release]; previousTexture = nil;
    [currentTexture release]; currentTexture = nil;
    [changesTexture release]; changesTexture = nil;
    [weightsTexture release]; weightsTexture = nil;
    [referenceTimes release]; referenceTimes = nil;
    [previousUpload release]; previousUpload = nil;
    [analysedUpload release]; analysedUpload = nil;
    [exclusionTexture release]; exclusionTexture = nil;
    [exclusionWeightTexture release]; exclusionWeightTexture = nil;
    [exclusionBuffer release]; exclusionBuffer = nil;
    [exclusionWeightBuffer release]; exclusionWeightBuffer = nil;
    memset(&exclusionMask, 0, sizeof(exclusionMask)); exclusionCount = 0;
    [analysedTexture release]; analysedTexture = nil;
    [referenceMirror release]; referenceMirror = nil;
    [pendingInput release]; pendingInput = nil;
    [pendingSelection release]; pendingSelection = nil;
    [pendingVersions release]; pendingVersions = nil;
    [provisionalFlags release]; provisionalFlags = nil;
    [matchRecords release]; matchRecords = nil;
    [libraryStats release]; libraryStats = nil;
    [libraryHits release]; libraryHits = nil;
    [libraryTable release]; libraryTable = nil;
    [libraryValid release]; libraryValid = nil;
    [blockChurn release]; blockChurn = nil;
    [lastStoredHashes release]; lastStoredHashes = nil;
    [dummySlotTexture release]; dummySlotTexture = nil;
    for (NSUInteger i = 0; i < 16; ++i) {
        [slotInputs[i] release]; slotInputs[i] = nil;
        [slotResiduals[i] release]; slotResiduals[i] = nil;
        [slotHashes[i] release]; slotHashes[i] = nil;
        slotActive[i] = NO; slotStoreTime[i] = slotLastHit[i] = 0;
    }
    librarySlots = libraryEntries = 0;
    pendingToken = 0; inputWidth = inputHeight = inputStride = exclusionStride = exclusionWeightStride = 0;
    timerPending = seeded = snapshotPending = NO; fadeUntil = 0;
}
- (void)cancel
{
    NSAssert(NSThread.isMainThread, @"Temporal presentation state belongs to the main thread");
    cancelled = YES;
    [displayLayer removeFromSuperlayer];
    [self clearGeometry];
}
- (void)dealloc
{
    [self clearGeometry]; [displayLayer removeFromSuperlayer]; [displayLayer release];
    [resetPS release]; [seedPS release]; [detectPS release]; [maskPS release]; [acceptPS release];
    [inputPS release]; [residualPS release]; [timesPS release]; [renderPS release];
    [validPS release]; [indexPS release]; [hashPS release]; [probePS release];
    [applyResidualPS release]; [applyInputPS release]; [fixupPS release];
    [invalidatePS release];
    [queue release]; [device release]; [super dealloc];
}
- (void)clearSpatial
{
    [spatialScaler release]; spatialScaler=nil;
    [spatialIn release]; spatialIn=nil;
    [spatialOut release]; spatialOut=nil;
    spatialInW=spatialInH=spatialOutW=spatialOutH=0;
}
- (void)dropDeferredSurface
{
    void (^done)(void) = deferredConsumed;
    IOSurfaceRef surface = deferredSurface;
    deferredConsumed = nil;
    deferredSurface = NULL;
    if (done) { done(); [done release]; }
    if (surface) CFRelease(surface);
}
- (void)deferSurface:(IOSurfaceRef)surface consumed:(void (^)(void))consumed
{
    [self dropDeferredSurface];
    if (surface) {
        CFRetain(surface);
        deferredSurface = surface;
        deferredConsumed = [consumed copy];
    } else if (consumed) {
        consumed();
    }
}
- (void)clearPools
{
    [self dropDeferredSurface];
    for (unsigned i = 0; i < sourceSlotCount; ++i) {
        [sourceSlots[i].buffer release]; [sourceSlots[i].texture release];
        if (sourceSlots[i].bitmap) CGContextRelease(sourceSlots[i].bitmap);
        memset(&sourceSlots[i], 0, sizeof(sourceSlots[i]));
    }
    sourceSlotCount = 0;
    for (unsigned i = 0; i < surfaceSlotCount; ++i) {
        [surfaceSlots[i].texture release]; memset(&surfaceSlots[i], 0, sizeof(surfaceSlots[i]));
    }
    surfaceSlotCount = 0;
    for (unsigned i = 0; i < surfaceCacheCount; ++i) {
        [surfaceCache[i].wrapper release];
        if (surfaceCache[i].surface) CFRelease(surfaceCache[i].surface);
        memset(&surfaceCache[i], 0, sizeof(surfaceCache[i]));
    }
    surfaceCacheCount = 0;
    surfaceCacheClock = 0;
    for (unsigned i = 0; i < metaSlotCount; ++i) {
        [metaSlots[i].metadata release]; [metaSlots[i].stats release];
        [metaSlots[i].hits release]; memset(&metaSlots[i], 0, sizeof(metaSlots[i]));
    }
    metaSlotCount = 0;
    [snapshotStaging release]; snapshotStaging = nil;
    lastRenderedParamTime = 0; lastPresentedParent = nil;
}
- (void)pinSource:(id<MTLTexture>)t upload:(id<MTLBuffer>)u
{
    for (unsigned i = 0; i < sourceSlotCount; ++i)
        if (sourceSlots[i].texture == t || sourceSlots[i].buffer == u) ++sourceSlots[i].busy;
    for (unsigned i = 0; i < surfaceSlotCount; ++i)
        if (surfaceSlots[i].texture == t) ++surfaceSlots[i].busy;
}
- (void)unpinSource:(id<MTLTexture>)t upload:(id<MTLBuffer>)u
{
    for (unsigned i = 0; i < sourceSlotCount; ++i)
        if (sourceSlots[i].texture == t || sourceSlots[i].buffer == u)
            if (sourceSlots[i].busy) --sourceSlots[i].busy;
    for (unsigned i = 0; i < surfaceSlotCount; ++i)
        if (surfaceSlots[i].texture == t)
            if (surfaceSlots[i].busy) --surfaceSlots[i].busy;
}
- (void)pinMeta:(id<MTLBuffer>)m stats:(id<MTLBuffer>)s hits:(id<MTLBuffer>)h delta:(int)d
{
    for (unsigned i = 0; i < metaSlotCount; ++i)
        if (metaSlots[i].metadata == m || metaSlots[i].stats == s || metaSlots[i].hits == h) {
            if (d > 0) metaSlots[i].busy += d;
            else if (metaSlots[i].busy) metaSlots[i].busy += d;
        }
}
#if WGDI_TEMPORAL_METALFX
- (BOOL)spatialBind:(id<MTLTexture>)source drawable:(id<CAMetalDrawable>)drawable
{
    (void)source;
    if (!adaptive || !drawable) return NO;
    const CGSize inSize = CGSizeMake(inputWidth, inputHeight);
    const CGSize outSize = CGSizeMake(drawable.texture.width, drawable.texture.height);
    if (outSize.width <= inSize.width || outSize.height <= inSize.height ||
        outSize.width > 8192 || outSize.height > 8192) return NO;
    if (spatialScaler && spatialIn && spatialOut &&
        CGSizeEqualToSize(attemptIn, inSize) && CGSizeEqualToSize(attemptOut, outSize)) return YES;
    if (spatialFailed && CGSizeEqualToSize(attemptIn, inSize) &&
        CGSizeEqualToSize(attemptOut, outSize)) return NO;
    [self clearSpatial];
    attemptIn = inSize; attemptOut = outSize; spatialFailed = YES;
    if (@available(macOS 13.0, *)) {
        static Class descriptorClass;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            if (dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX",
                    RTLD_LAZY|RTLD_LOCAL))
                descriptorClass = NSClassFromString(@"MTLFXSpatialScalerDescriptor");
        });
        if (!descriptorClass || ![descriptorClass supportsDevice:device]) return NO;
        MTLFXSpatialScalerDescriptor *descriptor = [[descriptorClass alloc] init];
        descriptor.inputWidth = inputWidth; descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outSize.width; descriptor.outputHeight = outSize.height;
        descriptor.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLFXSpatialScaler> scaler = [descriptor newSpatialScalerWithDevice:device];
        [descriptor release];
        if (!scaler) return NO;
        const NSUInteger inUsage = scaler.colorTextureUsage;
        const NSUInteger outUsage = scaler.outputTextureUsage | MTLTextureUsageShaderRead;
        MTLTextureDescriptor *inDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:inputWidth height:inputHeight mipmapped:NO];
        inDesc.usage = (MTLTextureUsage)inUsage; inDesc.storageMode = MTLStorageModePrivate;
        spatialIn = [device newTextureWithDescriptor:inDesc];
        MTLTextureDescriptor *outDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:outSize.width height:outSize.height mipmapped:NO];
        outDesc.usage = (MTLTextureUsage)outUsage; outDesc.storageMode = MTLStorageModePrivate;
        spatialOut = [device newTextureWithDescriptor:outDesc];
        if (!spatialIn || !spatialOut) { [self clearSpatial]; [scaler release]; return NO; }
        spatialScaler = (id)scaler;
        spatialInW = inputWidth; spatialInH = inputHeight;
        spatialOutW = outSize.width; spatialOutH = outSize.height;
        spatialFailed = NO;
        if (trace) NSLog(@"Wine temporal: MetalFX spatial %lux%lu -> %lux%lu",
            (unsigned long)inputWidth, (unsigned long)inputHeight,
            (unsigned long)spatialOutW, (unsigned long)spatialOutH);
        return YES;
    }
    return NO;
}
- (void)spatialEncode:(id<MTLTexture>)source command:(id<MTLCommandBuffer>)command
{
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(inputWidth, inputHeight, 1) toTexture:spatialIn
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    if (@available(macOS 13.0, *)) {
        id<MTLFXSpatialScaler> scaler = (id<MTLFXSpatialScaler>)spatialScaler;
        scaler.colorTexture = spatialIn;
        scaler.outputTexture = spatialOut;
        scaler.inputContentWidth = inputWidth;
        scaler.inputContentHeight = inputHeight;
        [scaler encodeToCommandBuffer:command];
    }
}
#endif
- (BOOL)ensureSpatial:(id<MTLTexture>)source drawable:(id<CAMetalDrawable>)drawable
    command:(id<MTLCommandBuffer>)command
{
#if WGDI_TEMPORAL_METALFX
    if (![self spatialBind:source drawable:drawable]) return NO;
    [self spatialEncode:source command:command];
    return YES;
#else
    (void)source; (void)drawable; (void)command;
    return NO;
#endif
}
- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(NSUInteger)width height:(NSUInteger)height
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [device newTextureWithDescriptor:descriptor];
}
- (struct wgdi_temporal_parameters)parameters
{
    struct wgdi_temporal_parameters p = {};
    p.width = (uint32_t)inputWidth; p.height = (uint32_t)inputHeight;
    p.block_columns = (p.width + 15) / 16; p.block_rows = (p.height + 15) / 16;
    p.tile_columns = schedule.columns; p.tile_rows = schedule.rows;
    p.previous_valid = previousTexture != nil;
    p.excluded = exclusionTexture && exclusionCount ? 1 : 0;
    p.time = (float)[self now]; p.fade_seconds = WGDI_TEMPORAL_FADE_SECONDS;
    p.halo = WGDI_TEMPORAL_HALO; p.feather = WGDI_TEMPORAL_FEATHER;
    return p;
}
- (void)dispatch:(id<MTLComputeCommandEncoder>)encoder width:(NSUInteger)width height:(NSUInteger)height
{
    [encoder dispatchThreadgroups:MTLSizeMake((width+15)/16, (height+15)/16, 1)
               threadsPerThreadgroup:MTLSizeMake(16,16,1)];
}
- (BOOL)configureWidth:(NSUInteger)width height:(NSUInteger)height
{
    struct wgdi_exclusions mask = {0, 0, {{0, 0, 0, 0}}};
    wgdi_load_exclusions(&mask, (unsigned)width, (unsigned)height);
    if (inputWidth == width && inputHeight == height &&
        !memcmp(&mask, &exclusionMask, sizeof(mask))) return YES;
    [self clearGeometry];
    if (!wgdi_temporal_configure(&schedule, (unsigned)width, (unsigned)height, [self now])) return NO;
    inputWidth = width; inputHeight = height; inputStride = (width*4+255)&~(NSUInteger)255;
    struct wgdi_temporal_parameters p = [self parameters];
    referenceTexture = [self texture:MTLPixelFormatRGBA8Unorm width:width height:height];
    residualTexture = [self texture:MTLPixelFormatRGBA16Float width:width*2 height:height*2];
    changesTexture = [self texture:MTLPixelFormatR8Uint width:p.block_columns height:p.block_rows];
    weightsTexture = [self texture:MTLPixelFormatR8Unorm width:width height:height];
    referenceTimes = [device newBufferWithLength:(NSUInteger)p.block_columns*p.block_rows*sizeof(float)
        options:MTLResourceStorageModeShared];
    /* Tightly packed BGRA mirror of referenceTexture maintained by every kernel
     * that commits input; job snapshots compose it with fresh tile uploads. */
    referenceMirror = [device newBufferWithLength:width*height*4 options:MTLResourceStorageModeShared];
    NSUInteger blocks = (NSUInteger)p.block_columns*p.block_rows;
    provisionalFlags = [device newBufferWithLength:blocks*sizeof(uint32_t)
        options:MTLResourceStorageModeShared];
    if (provisionalFlags) memset(provisionalFlags.contents, 0, provisionalFlags.length);
    /* Slot memory: W*H*4 input + 2W*2H*8 residual + open-addressing table +
     * valid bytes. K is bounded by the budget and by the 16-slot arrays. */
    if (libraryPipelines && libraryBudgetMB) {
        NSUInteger windows = (width/2)*(height/2), entries = 1;
        while (entries < windows*2) entries <<= 1;
        NSUInteger slotBytes = width*height*4 + (width*2)*(height*2)*8 + entries*8 + blocks;
        librarySlots = MIN((NSUInteger)16, libraryBudgetMB*1024*1024/MAX(slotBytes,(NSUInteger)1));
        if (librarySlots) {
            libraryEntries = entries;
            libraryTable = [device newBufferWithLength:librarySlots*entries*8
                options:MTLResourceStorageModeShared];
            libraryValid = [device newBufferWithLength:librarySlots*blocks
                options:MTLResourceStorageModeShared];
            blockChurn = [[NSMutableData alloc] initWithLength:blocks];
            matchRecords = [device newBufferWithLength:blocks*16 options:MTLResourceStorageModeShared];
            libraryStats = [device newBufferWithLength:4*sizeof(uint32_t)
                options:MTLResourceStorageModeShared];
            libraryHits = [device newBufferWithLength:16*sizeof(uint32_t)
                options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *dummy = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                width:1 height:1 mipmapped:NO];
            dummy.storageMode = MTLStorageModePrivate;
            dummy.usage = MTLTextureUsageShaderRead;
            dummySlotTexture = [device newTextureWithDescriptor:dummy];
            if (libraryTable) memset(libraryTable.contents, 0, libraryTable.length);
            if (libraryValid) memset(libraryValid.contents, 0, libraryValid.length);
            if (!libraryTable || !libraryValid || !matchRecords || !libraryStats ||
                !libraryHits || !dummySlotTexture) {
                [libraryTable release]; libraryTable = nil;
                [libraryValid release]; libraryValid = nil;
                [matchRecords release]; matchRecords = nil;
                [libraryStats release]; libraryStats = nil;
                [libraryHits release]; libraryHits = nil;
                [dummySlotTexture release]; dummySlotTexture = nil;
                librarySlots = libraryEntries = 0;
            } else if (!libraryLogged) {
                libraryLogged = YES;
                NSLog(@"Wine temporal: block library %lu slots (%lu MB)",
                    (unsigned long)librarySlots, (unsigned long)libraryBudgetMB);
            }
        }
    }
    /* Linear textures need a row pitch aligned for the format; odd-width
     * windows otherwise trip Metal validation and abort the process. */
    NSUInteger alignment = MAX((NSUInteger)1, [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR8Uint]);
    exclusionStride = (width + alignment - 1) / alignment * alignment;
    exclusionBuffer = [device newBufferWithLength:exclusionStride*height options:MTLResourceStorageModeShared];
    if (exclusionBuffer)
    {
        memset(exclusionBuffer.contents, 0, exclusionStride*height);
        MTLTextureDescriptor *exclusionDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
            width:width height:height mipmapped:NO];
        exclusionDescriptor.storageMode = MTLStorageModeShared;
        exclusionDescriptor.usage = MTLTextureUsageShaderRead;
        exclusionTexture = [exclusionBuffer newTextureWithDescriptor:exclusionDescriptor
            offset:0 bytesPerRow:exclusionStride];
    }
    alignment = MAX((NSUInteger)1, [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR8Unorm]);
    exclusionWeightStride = (width + alignment - 1) / alignment * alignment;
    exclusionWeightBuffer = [device newBufferWithLength:exclusionWeightStride*height
        options:MTLResourceStorageModeShared];
    if (exclusionWeightBuffer)
    {
        memset(exclusionWeightBuffer.contents, 255, exclusionWeightStride*height);
        MTLTextureDescriptor *weightDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
            width:width height:height mipmapped:NO];
        weightDescriptor.storageMode = MTLStorageModeShared;
        weightDescriptor.usage = MTLTextureUsageShaderRead;
        exclusionWeightTexture = [exclusionWeightBuffer newTextureWithDescriptor:weightDescriptor
            offset:0 bytesPerRow:exclusionWeightStride];
    }
    if (!referenceTexture || !residualTexture || !changesTexture || !weightsTexture ||
        !referenceTimes || !referenceMirror || !provisionalFlags ||
        !exclusionTexture || !exclusionWeightTexture) return NO;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:resetPS];
    [encoder setTexture:referenceTexture atIndex:0]; [encoder setTexture:residualTexture atIndex:1];
    [encoder setBuffer:referenceTimes offset:0 atIndex:0]; [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [encoder setBuffer:referenceMirror offset:0 atIndex:2];
    [self dispatch:encoder width:width*2 height:height*2]; [encoder endEncoding];
    [command commit];
    [self applyExclusions:&mask];
    return YES;
}
- (id<MTLTexture>)uploadTexture:(id<MTLBuffer>)buffer width:(NSUInteger)width
    height:(NSUInteger)height stride:(NSUInteger)stride
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead;
    return [buffer newTextureWithDescriptor:descriptor offset:0 bytesPerRow:stride];
}
/* Exclusion rectangles come from the same profile the GDI path re-reads each
 * frame. Excluded pixels never flag changes and never blend neural residual. */
- (void)applyExclusions:(const struct wgdi_exclusions *)mask
{
    if (!exclusionBuffer || !exclusionTexture || !exclusionWeightBuffer ||
        !exclusionWeightTexture || !inputWidth || !inputHeight) return;
    exclusionMask = *mask;
    exclusionCount = mask->count;
    uint8_t *bytes = (uint8_t *)exclusionBuffer.contents;
    memset(bytes, 0, exclusionStride * inputHeight);
    uint8_t *weights = (uint8_t *)exclusionWeightBuffer.contents;
    memset(weights, 255, exclusionWeightStride * inputHeight);
    const int band = int(WGDI_TEMPORAL_HALO + WGDI_TEMPORAL_FEATHER) + 1;
    for (unsigned i = 0; i < mask->count; ++i)
    {
        const struct wgdi_exclusion *r = &mask->rects[i];
        if (r->x >= inputWidth || r->y >= inputHeight) continue;
        const NSUInteger right = MIN(inputWidth, (NSUInteger)r->x + r->width);
        const NSUInteger bottom = MIN(inputHeight, (NSUInteger)r->y + r->height);
        for (NSUInteger y = r->y; y < bottom; ++y)
            memset(bytes + y * exclusionStride + r->x, 1, right - r->x);
        const int x0 = MAX(0, int(r->x) - band), y0 = MAX(0, int(r->y) - band);
        const int x1 = MIN(int(inputWidth), int(right) + band);
        const int y1 = MIN(int(inputHeight), int(bottom) + band);
        for (int y = y0; y < y1; ++y)
            for (int x = x0; x < x1; ++x)
            {
                const float cx = x + 0.5f, cy = y + 0.5f;
                const float dx = MAX(0.0f, MAX(float(r->x) - cx, cx - float(right)));
                const float dy = MAX(0.0f, MAX(float(r->y) - cy, cy - float(bottom)));
                const float d = MAX(dx, dy);
                const float t = MIN(MAX((d - float(WGDI_TEMPORAL_HALO)) /
                    float(WGDI_TEMPORAL_FEATHER), 0.0f), 1.0f);
                const uint8_t value = uint8_t(t * t * (3.0f - 2.0f * t) * 255.0f + 0.5f);
                uint8_t *pixel = weights + y * exclusionWeightStride + x;
                if (value < *pixel) *pixel = value;
            }
    }
}
- (void)detect:(id<MTLCommandBuffer>)command current:(id<MTLTexture>)current
    previous:(id<MTLTexture>)previous changes:(id<MTLTexture>)changes metadata:(id<MTLBuffer>)metadata
    parameters:(struct wgdi_temporal_parameters)p
{
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:detectPS];
    [encoder setTexture:current atIndex:0]; [encoder setTexture:previous ?: current atIndex:1];
    [encoder setTexture:referenceTexture atIndex:2]; [encoder setTexture:changes atIndex:3];
    [encoder setTexture:exclusionTexture atIndex:4];
    [encoder setBuffer:referenceTimes offset:0 atIndex:0]; [encoder setBuffer:metadata offset:0 atIndex:1];
    [encoder setBytes:&p length:sizeof(p) atIndex:2];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:3];
    [self dispatch:encoder width:inputWidth height:inputHeight]; [encoder endEncoding];
}
- (void)requestLater:(double)delay request:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (timerPending || cancelled || !request || neuralDisabled) return;
    timerPending = YES; uint64_t epoch = schedule.epoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.005,delay)*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (cancelled || epoch != schedule.epoch) return;
        timerPending = NO;
        [self refine:request redraw:redraw];
    });
}
- (void)refine:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (cancelled || failed || neuralDisabled || pendingToken || !analysedTexture || snapshotPending || !request) return;
    NSUInteger count = (NSUInteger)schedule.columns*schedule.rows;
    NSMutableData *selection = [NSMutableData dataWithLength:count*sizeof(uint32_t)];
    NSMutableData *versions = [NSMutableData dataWithLength:count*sizeof(uint64_t)];
    double next = WGDI_TEMPORAL_QUIET_SECONDS;
    unsigned ready = wgdi_temporal_select(&schedule, [self now], (uint32_t *)selection.mutableBytes,
                                          (uint64_t *)versions.mutableBytes, &next);
    if (!ready) {
        BOOL dirty = NO;
        for (NSUInteger i=0;i<count;++i) dirty |= schedule.tiles[i].dirty != 0;
        if (dirty) [self requestLater:next request:request redraw:redraw];
        return;
    }
    [self snapshot:selection versions:versions request:request redraw:redraw];
}
- (void)submitSnapshot:(id<MTLBuffer>)frozen source:(id<MTLBuffer>)sourceBuffer
    selection:(NSMutableData *)selection versions:(NSMutableData *)versions
    request:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (!frozen || !sourceBuffer || pendingToken || cancelled || failed || neuralDisabled) return;
    NSUInteger count=(NSUInteger)schedule.columns*schedule.rows;
    unsigned ready=wgdi_temporal_revalidate(&schedule,schedule.epoch,(uint32_t *)selection.mutableBytes,
        (const uint64_t *)versions.bytes);
    if (!ready) { if (redraw) redraw(); return; }
    NSMutableData *candidate = [[[NSData dataWithBytes:frozen.contents
        length:inputWidth*inputHeight*4] mutableCopy] autorelease];
    const uint8_t *source = (const uint8_t *)sourceBuffer.contents;
    uint8_t *destination = (uint8_t *)candidate.mutableBytes;
    const uint32_t *selected = (const uint32_t *)selection.bytes;
    for (NSUInteger ty=0;ty<schedule.rows;++ty) for (NSUInteger tx=0;tx<schedule.columns;++tx) {
        if (!selected[ty*schedule.columns+tx]) continue;
        NSUInteger x=tx*256, y=ty*256, right=MIN(inputWidth,x+256), bottom=MIN(inputHeight,y+256);
        for (NSUInteger row=y;row<bottom;++row)
            memcpy(destination+(row*inputWidth+x)*4,source+row*inputStride+x*4,(right-x)*4);
    }
    for (unsigned i = 0; i < exclusionMask.count; ++i)
    {
        const struct wgdi_exclusion *r = &exclusionMask.rects[i];
        if (r->x >= inputWidth || r->y >= inputHeight) continue;
        const NSUInteger right = MIN(inputWidth, (NSUInteger)r->x + r->width);
        const NSUInteger bottom = MIN(inputHeight, (NSUInteger)r->y + r->height);
        for (NSUInteger y = r->y; y < bottom; ++y)
            for (NSUInteger x = r->x; x < right; ++x)
            {
                uint8_t *pixel = destination + (y * inputWidth + x) * 4;
                pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 255;
            }
    }
    pendingToken = ++nextToken; pendingEpoch = schedule.epoch;
    if (trace) NSLog(@"Wine temporal: request %llu epoch %llu tiles %u/%lu",
        (unsigned long long)pendingToken,(unsigned long long)pendingEpoch,ready,(unsigned long)count);
    pendingInput = [candidate copy]; pendingSelection = [selection mutableCopy]; pendingVersions = [versions mutableCopy];
    if (!request(pendingInput,inputWidth,inputHeight,pendingToken)) {
        pendingToken = 0; [pendingInput release]; pendingInput=nil;
        [pendingSelection release]; pendingSelection=nil; [pendingVersions release]; pendingVersions=nil;
        [self requestLater:WGDI_TEMPORAL_QUIET_SECONDS request:request redraw:redraw];
    }
}
- (void)snapshot:(NSMutableData *)selection versions:(NSMutableData *)versions
    request:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (snapshotPending || !analysedTexture || !referenceMirror) return;
    if (!snapshotStaging)
        snapshotStaging=[device newBufferWithLength:inputWidth*inputHeight*4
            options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback=analysedUpload ? nil :
        [device newBufferWithLength:inputStride*inputHeight options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!snapshotStaging || !command || (!analysedUpload && !readback)) {
        [readback release]; neuralDisabled=YES; if (redraw) redraw(); return;
    }
    id<MTLTexture> pinTexture=analysedTexture;
    id<MTLBuffer> pinBuffer=analysedUpload;
    id<MTLBuffer> frozen=snapshotStaging, source=pinBuffer ? pinBuffer : readback;
    [self pinSource:pinTexture upload:pinBuffer];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromBuffer:referenceMirror sourceOffset:0 toBuffer:frozen
        destinationOffset:0 size:inputWidth*inputHeight*4];
    if (readback) {
        const uint32_t *selected=(const uint32_t *)selection.bytes;
        for (NSUInteger ty=0;ty<schedule.rows;++ty)
            for (NSUInteger tx=0;tx<schedule.columns;++tx) {
                if (!selected[ty*schedule.columns+tx]) continue;
                NSUInteger x=tx*256, y=ty*256;
                NSUInteger w=MIN((NSUInteger)256,inputWidth-x);
                NSUInteger h=MIN((NSUInteger)256,inputHeight-y);
                [blit copyFromTexture:pinTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0)
                    sourceSize:MTLSizeMake(w,h,1) toBuffer:readback destinationOffset:y*inputStride+x*4
                    destinationBytesPerRow:inputStride destinationBytesPerImage:inputStride*inputHeight];
            }
    }
    [blit endEncoding];
    snapshotPending=YES; uint64_t epoch=schedule.epoch;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled || epoch!=schedule.epoch) {
                [self unpinSource:pinTexture upload:pinBuffer];
                return;
            }
            snapshotPending=NO;
            if (completed.status==MTLCommandBufferStatusError) {
                neuralDisabled=YES; NSLog(@"Wine temporal: inference snapshot failed (%@)",completed.error);
                [self unpinSource:pinTexture upload:pinBuffer];
                if (redraw) redraw(); return;
            }
            [self submitSnapshot:frozen source:source
                selection:selection versions:versions request:request redraw:redraw];
            [self unpinSource:pinTexture upload:pinBuffer];
        });
    }];
    [command commit]; [readback release];
}
- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw
{
    if (!image || cancelled || failed) return NO;
    [self dropDeferredSurface];
    NSUInteger iw=CGImageGetWidth(image), ih=CGImageGetHeight(image);
    if (![self configureWidth:iw height:ih]) { failed=YES; return NO; }
    NSUInteger si=NSNotFound;
    for (unsigned i=0;i<sourceSlotCount;++i)
        if (!sourceSlots[i].busy && sourceSlots[i].texture!=currentTexture &&
            sourceSlots[i].texture!=previousTexture && sourceSlots[i].texture!=analysedTexture &&
            sourceSlots[i].buffer!=previousUpload && sourceSlots[i].buffer!=analysedUpload) { si=i; break; }
    if (si==NSNotFound && sourceSlotCount<3) {
        id<MTLBuffer> buffer=[device newBufferWithLength:inputStride*ih options:MTLResourceStorageModeShared];
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap=buffer ? CGBitmapContextCreate(buffer.contents,iw,ih,8,inputStride,space,
            kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst) : NULL;
        CGColorSpaceRelease(space);
        id<MTLTexture> tex=bitmap ? [self uploadTexture:buffer width:iw height:ih stride:inputStride] : nil;
        if (!tex) { CGContextRelease(bitmap); [buffer release]; failed=YES; return NO; }
        si=sourceSlotCount++;
        sourceSlots[si].buffer=buffer; sourceSlots[si].bitmap=bitmap;
        sourceSlots[si].texture=tex; sourceSlots[si].busy=0;
    }
    if (si==NSNotFound) {
        displayLayer.hidden=NO; displayLayer.frame=frame;
        if (redraw) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        return YES;
    }
    CGContextSetBlendMode(sourceSlots[si].bitmap,kCGBlendModeCopy);
    /* Same rasterization as conventional Wine GDI; OpenGL normalizes in its blit. */
    CGContextDrawImage(sourceSlots[si].bitmap,CGRectMake(0,0,iw,ih),image);
    return [self presentTexture:sourceSlots[si].texture upload:sourceSlots[si].buffer external:nil surface:NULL
        inLayer:parent frame:frame width:width height:height request:request needsDisplay:redraw
        sourceConsumed:nil];
}
- (BOOL)presentSurface:(IOSurfaceRef)surface inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw sourceConsumed:(void (^)(void))consumed
{
    if (!surface || cancelled || failed) { [self dropDeferredSurface]; if (consumed) consumed(); return NO; }
    [self dropDeferredSurface];
    NSUInteger iw=IOSurfaceGetWidth(surface),ih=IOSurfaceGetHeight(surface);
    if (![self configureWidth:iw height:ih]) { if (consumed) consumed(); return NO; }
    id<MTLTexture> external=nil;
    for (unsigned i=0;i<surfaceCacheCount;++i)
        if (surfaceCache[i].surface==surface) {
            surfaceCache[i].stamp=++surfaceCacheClock;
            external=surfaceCache[i].wrapper;
            break;
        }
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:iw height:ih mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared; descriptor.usage=MTLTextureUsageShaderRead;
    if (!external) {
        external=[device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
        if (!external) { if (consumed) consumed(); failed=YES; return NO; }
        unsigned ci=0;
        if (surfaceCacheCount<8) {
            ci=surfaceCacheCount++;
        } else {
            uint64_t oldest=surfaceCache[0].stamp;
            for (unsigned i=1;i<8;++i)
                if (surfaceCache[i].stamp<oldest) { oldest=surfaceCache[i].stamp; ci=i; }
            [surfaceCache[ci].wrapper release];
            if (surfaceCache[ci].surface) CFRelease(surfaceCache[ci].surface);
        }
        surfaceCache[ci].surface=(IOSurfaceRef)CFRetain(surface);
        surfaceCache[ci].wrapper=external;
        surfaceCache[ci].stamp=++surfaceCacheClock;
    }
    NSUInteger si=NSNotFound;
    for (unsigned i=0;i<surfaceSlotCount;++i)
        if (!surfaceSlots[i].busy && surfaceSlots[i].texture!=currentTexture &&
            surfaceSlots[i].texture!=previousTexture && surfaceSlots[i].texture!=analysedTexture) { si=i; break; }
    if (si==NSNotFound && surfaceSlotCount<3) {
        descriptor.storageMode=MTLStorageModePrivate;
        id<MTLTexture> immutable=[device newTextureWithDescriptor:descriptor];
        if (!immutable) { if (consumed) consumed(); failed=YES; return NO; }
        si=surfaceSlotCount++;
        surfaceSlots[si].texture=immutable; surfaceSlots[si].busy=0;
    }
    if (si==NSNotFound) {
        displayLayer.hidden=NO; displayLayer.frame=frame;
        if (redraw) {
            [self deferSurface:surface consumed:consumed];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        } else if (consumed) {
            consumed();
        }
        return YES;
    }
    return [self presentTexture:surfaceSlots[si].texture upload:nil external:external surface:surface
        inLayer:parent frame:frame width:width height:height request:request
        needsDisplay:redraw sourceConsumed:consumed];
}
- (BOOL)presentLatestInLayer:(CALayer *)parent frame:(CGRect)frame width:(NSUInteger)width
    height:(NSUInteger)height request:(WGDITemporalRequest)request needsDisplay:(void (^)(void))redraw
{
    if (deferredSurface) {
        IOSurfaceRef pending=deferredSurface;
        void (^done)(void)=deferredConsumed;
        deferredSurface=NULL;
        deferredConsumed=nil;
        BOOL ok=[self presentSurface:pending inLayer:parent frame:frame width:width
            height:height request:request needsDisplay:redraw sourceConsumed:done];
        [done release];
        CFRelease(pending);
        return ok;
    }
    id<MTLTexture> latest=[[currentTexture retain] autorelease];
    if (!latest) return NO;
    return [self presentTexture:latest upload:previousUpload external:nil surface:NULL inLayer:parent frame:frame
        width:width height:height request:request needsDisplay:redraw sourceConsumed:nil];
}
- (BOOL)presentTexture:(id<MTLTexture>)texture upload:(id<MTLBuffer>)upload external:(id<MTLTexture>)external
    surface:(IOSurfaceRef)surface
    inLayer:(CALayer *)parent frame:(CGRect)frame width:(NSUInteger)width height:(NSUInteger)height
    request:(WGDITemporalRequest)request needsDisplay:(void (^)(void))redraw sourceConsumed:(void (^)(void))consumed
{
    NSAssert(NSThread.isMainThread, @"Temporal presentation requires main-thread ownership");
    if (cancelled || failed || !texture || !parent || !width || !height || width>8192 || height>8192 ||
        (uint64_t)width*height>32u*1024u*1024u || CGRectIsEmpty(frame) || (consumed && !external)) {
        if (consumed) consumed(); return NO;
    }
    texture = [[texture retain] autorelease];
    upload = [[upload retain] autorelease];
    if (![self configureWidth:texture.width height:texture.height]) {
        if (consumed) consumed(); failed = YES; return NO;
    }
    if (framesInFlight>=2) {
        displayLayer.hidden=NO; displayLayer.frame=frame;
        if (redraw) {
            if (surface) [self deferSurface:surface consumed:consumed];
            else if (consumed) consumed();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        } else if (consumed) {
            consumed();
        }
        return YES;
    }
    NSUInteger iw=inputWidth,ih=inputHeight;
    if (seeded && !framesInFlight && !pendingToken && !snapshotPending && !external &&
        displayLayer.superlayer==parent &&
        lastPresentedParent==parent && CGRectEqualToRect(lastPresentedFrame,frame) &&
        CGSizeEqualToSize(lastDrawableSize,CGSizeMake(width,height)) &&
        lastRenderedParamTime>=fadeUntil && previousUpload) {
        BOOL clean=YES;
        for (NSUInteger i=0;i<(NSUInteger)schedule.columns*schedule.rows && clean;++i)
            clean=schedule.tiles[i].dirty==0;
        if (clean) {
            BOOL same=!upload || upload==previousUpload;
            if (!same && upload) {
                same=YES;
                const uint8_t *a=(const uint8_t *)upload.contents, *b=(const uint8_t *)previousUpload.contents;
                for (NSUInteger y=0;y<ih && same;++y)
                    same=!memcmp(a+y*inputStride,b+y*inputStride,iw*4);
            }
            if (same) { displayLayer.hidden=NO; return YES; }
        }
    }
    BOOL seedReference=!seeded;
    if (displayLayer.superlayer != parent) { [displayLayer removeFromSuperlayer]; [parent addSublayer:displayLayer]; }
    displayLayer.frame=frame; displayLayer.contentsScale=width/frame.size.width;
    displayLayer.drawableSize=CGSizeMake(width,height); displayLayer.hidden=NO;
    id<CAMetalDrawable> drawable=[displayLayer nextDrawable];
    if (!drawable) { if (consumed) consumed(); return NO; }
    struct wgdi_temporal_parameters p=[self parameters];
    NSUInteger mi=NSNotFound;
    for (unsigned i=0;i<metaSlotCount;++i) if (!metaSlots[i].busy) { mi=i; break; }
    if (mi==NSNotFound && metaSlotCount<2) {
        id<MTLBuffer> m=[device newBufferWithLength:(NSUInteger)p.block_columns*p.block_rows*sizeof(uint32_t)
            options:MTLResourceStorageModeShared];
        id<MTLBuffer> s=[device newBufferWithLength:4*sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> h=[device newBufferWithLength:16*sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (!m || !s || !h) { [m release]; [s release]; [h release];
            if (consumed) consumed(); failed=YES; return NO; }
        mi=metaSlotCount++;
        metaSlots[mi].metadata=m; metaSlots[mi].stats=s; metaSlots[mi].hits=h; metaSlots[mi].busy=0;
    }
    id<MTLBuffer> metadata=mi!=NSNotFound ? metaSlots[mi].metadata : nil;
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!metadata || !command) { if (consumed) consumed(); failed=YES; return NO; }
    metaSlots[mi].busy=1;
    [self pinSource:texture upload:upload];
    if (external) {
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromTexture:external sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(iw,ih,1) toTexture:texture destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];
    }
    if (seedReference) {
        id<MTLComputeCommandEncoder> seed = [command computeCommandEncoder];
        [seed setComputePipelineState:seedPS]; [seed setTexture:texture atIndex:0];
        [seed setTexture:referenceTexture atIndex:1];
        [seed setTexture:exclusionTexture atIndex:2];
        [seed setBuffer:referenceMirror offset:0 atIndex:0];
        [seed setBytes:&p length:sizeof(p) atIndex:1];
        [self dispatch:seed width:iw height:ih]; [seed endEncoding];
    }
    [self detect:command current:texture previous:previousTexture changes:changesTexture metadata:metadata parameters:p];
    BOOL probedLibrary=[self probeLibrary:command current:texture metadata:metadata
        stats:metaSlots[mi].stats hits:metaSlots[mi].hits parameters:p];
    id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
    [compute setComputePipelineState:maskPS]; [compute setTexture:changesTexture atIndex:0];
    [compute setTexture:weightsTexture atIndex:1]; [compute setTexture:exclusionTexture atIndex:2];
    [compute setTexture:exclusionWeightTexture atIndex:3];
    [compute setBuffer:referenceTimes offset:0 atIndex:0];
    [compute setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:compute width:iw height:ih]; [compute endEncoding];
    const BOOL useSpatial=[self ensureSpatial:texture drawable:drawable command:command];
    p.use_spatial = useSpatial ? 1u : 0u;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionDontCare; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];
    [render setRenderPipelineState:renderPS]; [render setFragmentTexture:texture atIndex:0];
    [render setFragmentTexture:residualTexture atIndex:1]; [render setFragmentTexture:weightsTexture atIndex:2];
    [render setFragmentTexture:exclusionWeightTexture atIndex:3];
    [render setFragmentTexture:useSpatial ? spatialOut : texture atIndex:4];
    [render setFragmentBytes:&p length:sizeof(p) atIndex:0];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [render endEncoding];
    uint64_t epoch=schedule.epoch, sequence=++frameSequence;
    double captured=[self now]; id<MTLBuffer> metaStats=metaSlots[mi].stats,
        metaHits=metaSlots[mi].hits;
    ++framesInFlight;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (consumed) consumed();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (framesInFlight) --framesInFlight;
            [self unpinSource:texture upload:upload];
            [self pinMeta:metadata stats:metaStats hits:metaHits delta:-1];
            if (cancelled || epoch!=schedule.epoch) return;
            if (completed.status==MTLCommandBufferStatusError) {
                failed=YES; NSLog(@"Wine temporal: GPU presentation failed (%@)",completed.error);
                [displayLayer removeFromSuperlayer]; if (redraw) redraw(); return;
            }
            lastRenderedParamTime=p.time;
            lastPresentedParent=parent; lastPresentedFrame=frame;
            lastDrawableSize=CGSizeMake(width,height);
            if (sequence==1) NSLog(@"Wine temporal: GPU presentation active, %lux%lu source, %lu metadata bytes",
                (unsigned long)iw,(unsigned long)ih,(unsigned long)metadata.length);
            if (trace && sequence%120==0 && completed.GPUEndTime>completed.GPUStartTime)
                NSLog(@"Wine temporal: frame %llu GPU %.3f ms",(unsigned long long)sequence,
                    (completed.GPUEndTime-completed.GPUStartTime)*1000.0);
            if (probedLibrary) {
                const uint32_t *stats=(const uint32_t *)metaStats.contents;
                const uint32_t *hits=(const uint32_t *)metaHits.contents;
                double hitTime=[self now];
                for (NSUInteger s=0;s<librarySlots;++s) if (hits[s]) slotLastHit[s]=hitTime;
                if (trace && stats[0])
                    NSLog(@"Wine temporal: library probed %u exact %u provisional %u slots %u",
                        stats[0],stats[1],stats[2],[self libraryActiveCount]);
            }
            if (sequence>schedule.observed_sequence) {
                wgdi_temporal_observe(&schedule,(const uint32_t *)metadata.contents,epoch,sequence,captured);
                [analysedUpload release]; analysedUpload=[upload retain];
                [analysedTexture release]; analysedTexture=[texture retain];
                [self refine:request redraw:redraw];
            }
            if (deferredSurface && redraw)
                redraw();
            else if ([self now]<fadeUntil && redraw)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        });
    }];
    [previousTexture release]; previousTexture=[texture retain];
    [currentTexture release]; currentTexture=[texture retain];
    [upload retain]; [previousUpload release]; previousUpload=upload;
    [command presentDrawable:drawable]; [command commit]; seeded=YES;
    lastMetaSubmitted=(unsigned)mi;
    return YES;
}
- (unsigned)libraryActiveCount
{
    unsigned count=0;
    for (NSUInteger i=0;i<librarySlots;++i) if (slotActive[i]) ++count;
    return count;
}
/* Probe every reference-dirty 16x16 block against the slot library, copy any
 * matched translated residual, publish matched input as the new reference and
 * demote the block (exact) or mark it provisional for later refinement. */
- (BOOL)probeLibrary:(id<MTLCommandBuffer>)command current:(id<MTLTexture>)texture
    metadata:(id<MTLBuffer>)metadata stats:(id<MTLBuffer>)stats hits:(id<MTLBuffer>)hits
    parameters:(struct wgdi_temporal_parameters)p
{
    if (!librarySlots || !libraryTable || !matchRecords) return NO;
    struct wgdi_temporal_library_parameters lp={};
    lp.width=(uint32_t)inputWidth; lp.height=(uint32_t)inputHeight;
    lp.table_mask=(uint32_t)(libraryEntries-1);
    lp.time=p.time; lp.fade_seconds=p.fade_seconds;
    lp.halo=WGDI_TEMPORAL_HALO; lp.exact_translation=exactTranslation?1u:0u;
    lp.excluded=p.excluded; lp.ring_only=0;
    NSUInteger order[16]; unsigned count=0;
    for (NSUInteger i=0;i<librarySlots;++i) if (slotActive[i]) order[count++]=i;
    for (unsigned a=0;a<count;++a)
        for (unsigned b=a+1;b<count;++b)
            if (slotStoreTime[order[b]]>slotStoreTime[order[a]]) {
                NSUInteger swap=order[a]; order[a]=order[b]; order[b]=swap;
            }
    for (unsigned i=0;i<count;++i) lp.slot_order[i]=(uint32_t)order[i];
    lp.slot_count=count;
    if (!count) return NO;
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit fillBuffer:stats range:NSMakeRange(0,stats.length) value:0];
    [blit fillBuffer:hits range:NSMakeRange(0,hits.length) value:0];
    [blit endEncoding];
    id<MTLTexture> inputs[16], residuals[16];
    for (NSUInteger i=0;i<16;++i) {
        inputs[i]=slotInputs[i] ? slotInputs[i] : dummySlotTexture;
        residuals[i]=slotResiduals[i] ? slotResiduals[i] : dummySlotTexture;
    }
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:probePS];
    [encoder setTexture:texture atIndex:0];
    [encoder setTextures:inputs withRange:NSMakeRange(1,16)];
    [encoder setTexture:changesTexture atIndex:17];
    [encoder setTexture:exclusionTexture atIndex:18];
    [encoder setBuffer:libraryValid offset:0 atIndex:0];
    [encoder setBuffer:libraryTable offset:0 atIndex:1];
    [encoder setBuffer:matchRecords offset:0 atIndex:2];
    [encoder setBuffer:stats offset:0 atIndex:3];
    [encoder setBuffer:hits offset:0 atIndex:4];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:5];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:6];
    [encoder dispatchThreadgroups:MTLSizeMake(p.block_columns,p.block_rows,1)
            threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:invalidatePS];
    [encoder setTexture:changesTexture atIndex:0];
    [encoder setTexture:exclusionTexture atIndex:1];
    [encoder setBuffer:referenceTimes offset:0 atIndex:0];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:1];
    [encoder setBuffer:matchRecords offset:0 atIndex:2];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:3];
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    if (exactTranslation) {
        lp.ring_only=1;
        encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:probePS];
        [encoder setTexture:texture atIndex:0];
        [encoder setTextures:inputs withRange:NSMakeRange(1,16)];
        [encoder setTexture:changesTexture atIndex:17];
        [encoder setTexture:exclusionTexture atIndex:18];
        [encoder setBuffer:libraryValid offset:0 atIndex:0];
        [encoder setBuffer:libraryTable offset:0 atIndex:1];
        [encoder setBuffer:matchRecords offset:0 atIndex:2];
        [encoder setBuffer:stats offset:0 atIndex:3];
        [encoder setBuffer:hits offset:0 atIndex:4];
        [encoder setBytes:&lp length:sizeof(lp) atIndex:5];
        [encoder setBuffer:provisionalFlags offset:0 atIndex:6];
        [encoder dispatchThreadgroups:MTLSizeMake(p.block_columns,p.block_rows,1)
                threadsPerThreadgroup:MTLSizeMake(16,16,1)];
        [encoder endEncoding];
        lp.ring_only=0;
    }
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:applyResidualPS];
    [encoder setTexture:residualTexture atIndex:0];
    [encoder setTextures:residuals withRange:NSMakeRange(1,16)];
    [encoder setBuffer:matchRecords offset:0 atIndex:0];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:1];
    [self dispatch:encoder width:inputWidth*2 height:inputHeight*2]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:applyInputPS];
    [encoder setTexture:texture atIndex:0]; [encoder setTexture:referenceTexture atIndex:1];
    [encoder setTexture:exclusionTexture atIndex:2];
    [encoder setBuffer:referenceMirror offset:0 atIndex:0];
    [encoder setBuffer:matchRecords offset:0 atIndex:1];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:2];
    [self dispatch:encoder width:inputWidth height:inputHeight]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:fixupPS];
    [encoder setTexture:changesTexture atIndex:0];
    [encoder setBuffer:metadata offset:0 atIndex:0];
    [encoder setBuffer:referenceTimes offset:0 atIndex:1];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:2];
    [encoder setBuffer:matchRecords offset:0 atIndex:3];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:4];
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    return YES;
}
/* After an admission commits, snapshot the whole reference/residual pair into a
 * slot so translated content can be reused later. Slots are indexed on the GPU;
 * near-duplicate older slots are freed once their distinct coverage is gone. */
- (void)storeLibrarySlot
{
    if (!librarySlots || !libraryTable || !libraryValid) return;
    NSUInteger blocks=((inputWidth+15)/16)*((inputHeight+15)/16);
    NSInteger s=-1;
    for (NSUInteger i=0;i<librarySlots;++i) if (!slotActive[i]) { s=(NSInteger)i; break; }
    if (s<0) {
        double bestHit=DBL_MAX, oldest=DBL_MAX;
        for (NSUInteger i=0;i<librarySlots;++i)
            if (slotLastHit[i]<bestHit || (slotLastHit[i]==bestHit && slotStoreTime[i]<oldest)) {
                s=(NSInteger)i; bestHit=slotLastHit[i]; oldest=slotStoreTime[i];
            }
        if (trace) NSLog(@"Wine temporal: library evict slot %ld",(long)s);
    }
    if (!slotInputs[s]) {
        slotInputs[s]=[self texture:MTLPixelFormatRGBA8Unorm width:inputWidth height:inputHeight];
        slotResiduals[s]=[self texture:MTLPixelFormatRGBA16Float width:inputWidth*2 height:inputHeight*2];
        if (!slotInputs[s] || !slotResiduals[s]) {
            [slotInputs[s] release]; slotInputs[s]=nil;
            [slotResiduals[s] release]; slotResiduals[s]=nil;
            return;
        }
    }
    id<MTLBuffer> hashOut=[device newBufferWithLength:blocks*sizeof(uint32_t)
        options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!hashOut || !command) { [hashOut release]; return; }
    struct wgdi_temporal_library_parameters lp={};
    lp.width=(uint32_t)inputWidth; lp.height=(uint32_t)inputHeight;
    lp.table_mask=(uint32_t)(libraryEntries-1);
    lp.halo=WGDI_TEMPORAL_HALO; lp.exact_translation=exactTranslation?1u:0u;
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:referenceTexture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(inputWidth,inputHeight,1)
        toTexture:slotInputs[s] destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0,0,0)];
    [blit copyFromTexture:residualTexture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(inputWidth*2,inputHeight*2,1)
        toTexture:slotResiduals[s] destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0,0,0)];
    [blit fillBuffer:libraryTable range:NSMakeRange((NSUInteger)s*libraryEntries*8,libraryEntries*8) value:0];
    [blit endEncoding];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:validPS];
    [encoder setBuffer:libraryValid offset:(NSUInteger)s*blocks atIndex:0];
    [encoder setBuffer:referenceTimes offset:0 atIndex:1];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:2];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:3];
    [encoder dispatchThreads:MTLSizeMake(blocks,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
    [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:indexPS];
    [encoder setTexture:slotInputs[s] atIndex:0];
    [encoder setBuffer:libraryTable offset:(NSUInteger)s*libraryEntries*8 atIndex:0];
    [encoder setBuffer:libraryValid offset:(NSUInteger)s*blocks atIndex:1];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:2];
    [self dispatch:encoder width:(inputWidth+1)/2 height:(inputHeight+1)/2]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:hashPS];
    [encoder setTexture:slotInputs[s] atIndex:0];
    [encoder setBuffer:hashOut offset:0 atIndex:0];
    [encoder setBuffer:libraryValid offset:(NSUInteger)s*blocks atIndex:1];
    [encoder setBytes:&lp length:sizeof(lp) atIndex:2];
    [self dispatch:encoder width:(inputWidth+15)/16 height:(inputHeight+15)/16]; [encoder endEncoding];
    uint64_t epoch=schedule.epoch;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled || epoch!=schedule.epoch ||
                completed.status==MTLCommandBufferStatusError) return;
            NSData *fresh=[NSData dataWithBytes:hashOut.contents length:blocks*sizeof(uint32_t)];
            const uint32_t *newHash=(const uint32_t *)fresh.bytes;
            uint8_t *churn=(uint8_t *)blockChurn.mutableBytes;
            if (lastStoredHashes) {
                const uint32_t *prev=(const uint32_t *)lastStoredHashes.bytes;
                for (NSUInteger i=0;i<blocks;++i)
                    if (prev[i] && newHash[i] && prev[i]!=newHash[i] && churn[i]<255)
                        ++churn[i];
            }
            [lastStoredHashes release]; lastStoredHashes=[fresh retain];
            for (NSUInteger t=0;t<librarySlots;++t) {
                if (t==(NSUInteger)s || !slotActive[t] || !slotHashes[t]) continue;
                const uint32_t *old=(const uint32_t *)slotHashes[t].bytes;
                NSUInteger total=0, equal=0;
                for (NSUInteger i=0;i<blocks;++i) {
                    if (!old[i] || churn[i]>=WGDI_TEMPORAL_VOLATILE_CHURN) continue;
                    ++total;
                    if (old[i]==newHash[i]) ++equal;
                }
                if (!total || (double)equal/(double)total<0.90) continue;
                /* The older slot is redundant only if its differing blocks are
                 * volatile or still covered by another active slot, otherwise
                 * its unique content would be lost. */
                BOOL redundant=YES;
                for (NSUInteger i=0;redundant && i<blocks;++i) {
                    if (!old[i] || old[i]==newHash[i] ||
                        churn[i]>=WGDI_TEMPORAL_VOLATILE_CHURN) continue;
                    BOOL covered=NO;
                    for (NSUInteger u=0;u<librarySlots && !covered;++u) {
                        if (u==t || u==(NSUInteger)s || !slotActive[u] || !slotHashes[u]) continue;
                        covered=((const uint32_t *)slotHashes[u].bytes)[i]==old[i];
                    }
                    if (!covered) redundant=NO;
                }
                if (redundant) {
                    if (trace) NSLog(@"Wine temporal: library slot %lu redundant, freed",
                        (unsigned long)t);
                    slotActive[t]=NO; [slotHashes[t] release]; slotHashes[t]=nil;
                }
            }
            [slotHashes[s] release]; slotHashes[s]=[fresh retain];
            slotActive[s]=YES; slotStoreTime[s]=slotLastHit[s]=[self now];
            if (trace) NSLog(@"Wine temporal: library stored slot %ld (%u active)",
                (long)s,[self libraryActiveCount]);
        });
    }];
    [command commit]; [hashOut release];
}
- (NSData *)selectedTilesForToken:(uint64_t)token
{
    NSAssert(NSThread.isMainThread, @"Temporal selection requires main-thread ownership");
    if (cancelled || failed || !token || token!=pendingToken || !pendingSelection) return nil;
    return [[pendingSelection copy] autorelease];
}
- (void)clearPending
{
    pendingToken=0; pendingEpoch=0;
    [pendingInput release]; pendingInput=nil;
    [pendingSelection release]; pendingSelection=nil;
    [pendingVersions release]; pendingVersions=nil;
}
- (void)completeOutput:(NSData *)output token:(uint64_t)token needsDisplay:(void (^)(void))redraw
{
    NSAssert(NSThread.isMainThread, @"Temporal admission requires main-thread ownership");
    if (cancelled || failed || !token || token!=pendingToken || pendingEpoch!=schedule.epoch) return;
    {
        struct wgdi_exclusions mask = {0, 0, {{0, 0, 0, 0}}};
        if (inputWidth && inputHeight)
            wgdi_load_exclusions(&mask, (unsigned)inputWidth, (unsigned)inputHeight);
        if (memcmp(&mask, &exclusionMask, sizeof(mask))) {
            [self clearPending]; if (redraw) redraw(); return;
        }
    }
    if (!output || output.length!=inputWidth*inputHeight*16) {
        neuralDisabled=YES; [self clearPending]; if (redraw) redraw(); return;
    }
    NSMutableData *selection=[[pendingSelection mutableCopy] autorelease];
    unsigned ready=wgdi_temporal_revalidate(&schedule,pendingEpoch,(uint32_t *)selection.mutableBytes,
        (const uint64_t *)pendingVersions.bytes);
    if (!ready || !currentTexture) { [self clearPending]; if (redraw) redraw(); return; }
    NSUInteger neuralStride=(inputWidth*8+255)&~(NSUInteger)255;
    id<MTLBuffer> jobBuffer=[device newBufferWithLength:inputStride*inputHeight options:MTLResourceStorageModeShared];
    id<MTLBuffer> neuralBuffer=[device newBufferWithLength:neuralStride*inputHeight*2 options:MTLResourceStorageModeShared];
    id<MTLBuffer> selected=[device newBufferWithBytes:selection.bytes length:selection.length options:MTLResourceStorageModeShared];
    struct wgdi_temporal_parameters p=[self parameters]; p.previous_valid=1;
    NSUInteger blocks=(NSUInteger)p.block_columns*p.block_rows;
    id<MTLBuffer> accepted=[device newBufferWithLength:blocks*sizeof(uint32_t) options:MTLResourceStorageModeShared];
    id<MTLBuffer> metadata=[device newBufferWithLength:blocks*sizeof(uint32_t) options:MTLResourceStorageModeShared];
    id<MTLTexture> admissionChanges=[self texture:MTLPixelFormatR8Uint width:p.block_columns height:p.block_rows];
    if (!jobBuffer || !neuralBuffer || !selected || !accepted || !metadata || !admissionChanges) {
        [jobBuffer release]; [neuralBuffer release]; [selected release]; [accepted release];
        [metadata release]; [admissionChanges release];
        neuralDisabled=YES; [self clearPending]; if (redraw) redraw(); return;
    }
    for (NSUInteger y=0;y<inputHeight;++y)
        memcpy((uint8_t *)jobBuffer.contents+y*inputStride,(const uint8_t *)pendingInput.bytes+y*inputWidth*4,inputWidth*4);
    {
        const uint32_t *sel=(const uint32_t *)selection.bytes;
        for (NSUInteger ty=0;ty<schedule.rows;++ty)
            for (NSUInteger tx=0;tx<schedule.columns;++tx) {
                if (!sel[ty*schedule.columns+tx]) continue;
                const NSUInteger x0=tx*512, x1=MIN(inputWidth*2,tx*512+512);
                const NSUInteger y1=MIN(inputHeight*2,ty*512+512);
                for (NSUInteger y=ty*512;y<y1;++y)
                    memcpy((uint8_t *)neuralBuffer.contents+y*neuralStride+x0*4,
                           (const uint8_t *)output.bytes+y*inputWidth*8+x0*4,(x1-x0)*4);
            }
    }
    id<MTLTexture> job=[self uploadTexture:jobBuffer width:inputWidth height:inputHeight stride:inputStride];
    id<MTLTexture> neural=[self uploadTexture:neuralBuffer width:inputWidth*2 height:inputHeight*2 stride:neuralStride];
    if (!job || !neural) {
        [job release]; [neural release]; [jobBuffer release]; [neuralBuffer release];
        [selected release]; [accepted release]; [metadata release]; [admissionChanges release];
        neuralDisabled=YES; [self clearPending]; if (redraw) redraw(); return;
    }
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!command) {
        [job release]; [neural release]; [jobBuffer release]; [neuralBuffer release];
        [selected release]; [accepted release]; [metadata release]; [admissionChanges release];
        failed=YES; [self clearPending]; if (redraw) redraw(); return;
    }
    [self detect:command current:currentTexture previous:job changes:admissionChanges metadata:metadata parameters:p];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:acceptPS]; [encoder setTexture:admissionChanges atIndex:0];
    [encoder setBuffer:selected offset:0 atIndex:0]; [encoder setBuffer:accepted offset:0 atIndex:1];
    [encoder setBuffer:referenceTimes offset:0 atIndex:2]; [encoder setBytes:&p length:sizeof(p) atIndex:3];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:4];
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:inputPS]; [encoder setTexture:job atIndex:0]; [encoder setTexture:referenceTexture atIndex:1];
    [encoder setBuffer:accepted offset:0 atIndex:0]; [encoder setBuffer:referenceMirror offset:0 atIndex:1];
    [encoder setBytes:&p length:sizeof(p) atIndex:2];
    [self dispatch:encoder width:inputWidth height:inputHeight]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:residualPS]; [encoder setTexture:job atIndex:0];
    [encoder setTexture:neural atIndex:1]; [encoder setTexture:residualTexture atIndex:2];
    [encoder setBuffer:accepted offset:0 atIndex:0]; [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:encoder width:inputWidth*2 height:inputHeight*2]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:timesPS]; [encoder setBuffer:accepted offset:0 atIndex:0];
    [encoder setBuffer:referenceTimes offset:0 atIndex:1]; [encoder setBytes:&p length:sizeof(p) atIndex:2];
    [encoder setBuffer:provisionalFlags offset:0 atIndex:3]; [encoder setTexture:admissionChanges atIndex:0];
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    uint64_t epoch=pendingEpoch;
    id<MTLTexture> pinnedCurrent=currentTexture;
    [self pinSource:pinnedCurrent upload:nil];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)jobBuffer; (void)neuralBuffer;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self unpinSource:pinnedCurrent upload:nil];
            if (cancelled || epoch!=schedule.epoch || token!=pendingToken) return;
            if (completed.status==MTLCommandBufferStatusError) {
                failed=YES; NSLog(@"Wine temporal: reference admission failed (%@)",completed.error);
                [displayLayer removeFromSuperlayer]; [self clearPending]; if (redraw) redraw(); return;
            }
            const uint32_t *valid=(const uint32_t *)accepted.contents;
            NSUInteger updated=0;
            for (NSUInteger i=0;i<blocks;++i) if (valid[i]) ++updated;
            if (trace) NSLog(@"Wine temporal: admitted %lu/%lu blocks for request %llu",
                (unsigned long)updated,(unsigned long)blocks,(unsigned long long)token);
            if (updated) fadeUntil=MAX(fadeUntil,[self now]+WGDI_TEMPORAL_FADE_SECONDS);
            if (updated && librarySlots) [self storeLibrarySlot];
            [self clearPending]; if (redraw) redraw();
        });
    }];
    [command commit];
    [job release]; [neural release]; [jobBuffer release]; [neuralBuffer release];
    [selected release]; [accepted release]; [metadata release]; [admissionChanges release];
}
@end

extern "C" __attribute__((visibility("default"))) id<WGDITemporalPresenter>
wine_gdi_temporal_create(uint32_t abi, const char *resources)
{
    if (abi!=WGDI_TEMPORAL_PRESENTER_ABI || !resources || resources[0]!='/') return nil;
    id<WGDITemporalPresenter> presenter=[[WGDITemporalRenderer alloc] initWithResources:[NSString stringWithUTF8String:resources]];
    if (presenter) NSLog(@"Wine temporal: GPU residual enabled, 16x16 detection, 256x256 scheduling, 200 ms quiet interval");
    return presenter;
}
