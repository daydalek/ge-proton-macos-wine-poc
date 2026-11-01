/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "wine_gdi_temporal.h"
#include "wine_gdi_temporal_presenter.h"

static_assert(sizeof(wgdi_temporal_parameters) == 48, "Metal parameter layout changed");

@interface WGDITemporalRenderer : NSObject <WGDITemporalPresenter>
{
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> resetPS, seedPS, detectPS, maskPS, acceptPS, inputPS, residualPS, timesPS;
    id<MTLRenderPipelineState> renderPS;
    CAMetalLayer *displayLayer;
    id<MTLTexture> referenceTexture, residualTexture, previousTexture, currentTexture, changesTexture, weightsTexture, analysedTexture;
    id<MTLBuffer> referenceTimes, previousUpload, analysedUpload;
    NSMutableData *referenceCPU, *pendingSelection, *pendingVersions;
    NSData *pendingInput;
    struct wgdi_temporal_scheduler schedule;
    NSUInteger inputWidth, inputHeight, inputStride, framesInFlight;
    uint64_t frameSequence, nextToken, pendingToken, pendingEpoch;
    double origin, fadeUntil;
    BOOL cancelled, failed, neuralDisabled, timerPending, seeded, trace, referenceCPUSeeded, snapshotPending;
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
    device = MTLCreateSystemDefaultDevice();
    queue = [device newCommandQueue];
    queue.label=@"wine.gdi.temporal";
    NSError *error = nil;
    NSString *path = [resources stringByAppendingPathComponent:@"temporal.metallib"];
    id<MTLLibrary> library = [device newLibraryWithFile:path error:&error];
    if (!library || !queue) { NSLog(@"Wine temporal: Metal library unavailable (%@)", error); [library release]; [self release]; return nil; }
    resetPS = [self pipeline:@"temporal_reset" library:library];
    seedPS = [self pipeline:@"temporal_seed" library:library];
    detectPS = [self pipeline:@"temporal_detect" library:library];
    maskPS = [self pipeline:@"temporal_mask" library:library];
    acceptPS = [self pipeline:@"temporal_accept" library:library];
    inputPS = [self pipeline:@"temporal_commit_input" library:library];
    residualPS = [self pipeline:@"temporal_commit_residual" library:library];
    timesPS = [self pipeline:@"temporal_commit_times" library:library];
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
    [referenceTexture release]; referenceTexture = nil;
    [residualTexture release]; residualTexture = nil;
    [previousTexture release]; previousTexture = nil;
    [currentTexture release]; currentTexture = nil;
    [changesTexture release]; changesTexture = nil;
    [weightsTexture release]; weightsTexture = nil;
    [referenceTimes release]; referenceTimes = nil;
    [previousUpload release]; previousUpload = nil;
    [analysedUpload release]; analysedUpload = nil;
    [analysedTexture release]; analysedTexture = nil;
    [referenceCPU release]; referenceCPU = nil;
    [pendingInput release]; pendingInput = nil;
    [pendingSelection release]; pendingSelection = nil;
    [pendingVersions release]; pendingVersions = nil;
    pendingToken = 0; inputWidth = inputHeight = inputStride = 0;
    timerPending = seeded = referenceCPUSeeded = snapshotPending = NO; fadeUntil = 0;
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
    [queue release]; [device release]; [super dealloc];
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
    if (inputWidth == width && inputHeight == height) return YES;
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
    referenceCPU = [[NSMutableData alloc] initWithLength:width*height*4];
    if (!referenceTexture || !residualTexture || !changesTexture || !weightsTexture || !referenceTimes || !referenceCPU) return NO;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:resetPS];
    [encoder setTexture:referenceTexture atIndex:0]; [encoder setTexture:residualTexture atIndex:1];
    [encoder setBuffer:referenceTimes offset:0 atIndex:0]; [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:encoder width:width*2 height:height*2]; [encoder endEncoding];
    [command commit];
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
- (void)detect:(id<MTLCommandBuffer>)command current:(id<MTLTexture>)current
    previous:(id<MTLTexture>)previous changes:(id<MTLTexture>)changes metadata:(id<MTLBuffer>)metadata
    parameters:(struct wgdi_temporal_parameters)p
{
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:detectPS];
    [encoder setTexture:current atIndex:0]; [encoder setTexture:previous ?: current atIndex:1];
    [encoder setTexture:referenceTexture atIndex:2]; [encoder setTexture:changes atIndex:3];
    [encoder setBuffer:referenceTimes offset:0 atIndex:0]; [encoder setBuffer:metadata offset:0 atIndex:1];
    [encoder setBytes:&p length:sizeof(p) atIndex:2];
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
    if (analysedUpload) {
        [self submitSnapshot:analysedUpload selection:selection versions:versions request:request redraw:redraw];
    } else {
        [self readSnapshot:selection versions:versions request:request redraw:redraw];
    }
}
- (void)submitSnapshot:(id<MTLBuffer>)sourceBuffer selection:(NSMutableData *)selection
    versions:(NSMutableData *)versions request:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (!sourceBuffer || pendingToken || cancelled || failed || neuralDisabled) return;
    NSUInteger count=(NSUInteger)schedule.columns*schedule.rows;
    unsigned ready=wgdi_temporal_revalidate(&schedule,schedule.epoch,(uint32_t *)selection.mutableBytes,
        (const uint64_t *)versions.bytes);
    if (!ready) { if (redraw) redraw(); return; }
    NSMutableData *candidate = [[referenceCPU mutableCopy] autorelease];
    const uint8_t *source = (const uint8_t *)sourceBuffer.contents;
    uint8_t *destination = (uint8_t *)candidate.mutableBytes;
    const uint32_t *selected = (const uint32_t *)selection.bytes;
    for (NSUInteger ty=0;ty<schedule.rows;++ty) for (NSUInteger tx=0;tx<schedule.columns;++tx) {
        if (!selected[ty*schedule.columns+tx]) continue;
        NSUInteger x=tx*256, y=ty*256, right=MIN(inputWidth,x+256), bottom=MIN(inputHeight,y+256);
        for (NSUInteger row=y;row<bottom;++row)
            memcpy(destination+(row*inputWidth+x)*4,source+row*inputStride+x*4,(right-x)*4);
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
- (void)readSnapshot:(NSMutableData *)selection versions:(NSMutableData *)versions
    request:(WGDITemporalRequest)request redraw:(void (^)(void))redraw
{
    if (snapshotPending || !analysedTexture) return;
    id<MTLBuffer> readback=[device newBufferWithLength:inputStride*inputHeight options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!readback || !command) {
        [readback release]; neuralDisabled=YES; if (redraw) redraw(); return;
    }
    BOOL seedCPU=!referenceCPUSeeded;
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    const uint32_t *selected=(const uint32_t *)selection.bytes;
    for (NSUInteger ty=0;ty<(seedCPU ? 1 : schedule.rows);++ty)
        for (NSUInteger tx=0;tx<(seedCPU ? 1 : schedule.columns);++tx) {
            if (!seedCPU && !selected[ty*schedule.columns+tx]) continue;
            NSUInteger x=seedCPU ? 0 : tx*256, y=seedCPU ? 0 : ty*256;
            NSUInteger w=seedCPU ? inputWidth : MIN((NSUInteger)256,inputWidth-x);
            NSUInteger h=seedCPU ? inputHeight : MIN((NSUInteger)256,inputHeight-y);
            [blit copyFromTexture:analysedTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0)
                sourceSize:MTLSizeMake(w,h,1) toBuffer:readback destinationOffset:y*inputStride+x*4
                destinationBytesPerRow:inputStride destinationBytesPerImage:inputStride*inputHeight];
        }
    [blit endEncoding];
    snapshotPending=YES; uint64_t epoch=schedule.epoch;
    NSUInteger iw=inputWidth,ih=inputHeight,stride=inputStride;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled || epoch!=schedule.epoch) return;
            snapshotPending=NO;
            if (completed.status==MTLCommandBufferStatusError) {
                neuralDisabled=YES; NSLog(@"Wine temporal: inference snapshot failed (%@)",completed.error);
                if (redraw) redraw(); return;
            }
            if (seedCPU) {
                for (NSUInteger y=0;y<ih;++y) memcpy((uint8_t *)referenceCPU.mutableBytes+y*iw*4,
                    (const uint8_t *)readback.contents+y*stride,iw*4);
                referenceCPUSeeded=YES;
            }
            [self submitSnapshot:readback selection:selection versions:versions request:request redraw:redraw];
        });
    }];
    [command commit]; [readback release];
}
- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw
{
    if (!image || cancelled || failed) return NO;
    NSUInteger iw=CGImageGetWidth(image), ih=CGImageGetHeight(image);
    if (![self configureWidth:iw height:ih]) { failed=YES; return NO; }
    id<MTLBuffer> upload=[device newBufferWithLength:inputStride*ih options:MTLResourceStorageModeShared];
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap=upload ? CGBitmapContextCreate(upload.contents,iw,ih,8,inputStride,space,
        kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst) : NULL;
    CGColorSpaceRelease(space);
    if (!bitmap) { [upload release]; failed=YES; return NO; }
    CGContextSetBlendMode(bitmap,kCGBlendModeCopy);
    /* Same rasterization as conventional Wine GDI; OpenGL normalizes in its blit. */
    CGContextDrawImage(bitmap,CGRectMake(0,0,iw,ih),image); CGContextRelease(bitmap);
    id<MTLTexture> texture=[self uploadTexture:upload width:iw height:ih stride:inputStride];
    if (!referenceCPUSeeded) {
        for (NSUInteger y=0;y<ih;++y) memcpy((uint8_t *)referenceCPU.mutableBytes+y*iw*4,
            (const uint8_t *)upload.contents+y*inputStride,iw*4);
        referenceCPUSeeded=YES;
    }
    BOOL result=[self presentTexture:texture upload:upload external:nil inLayer:parent frame:frame
        width:width height:height request:request needsDisplay:redraw sourceConsumed:nil];
    [texture release]; [upload release]; return result;
}
- (BOOL)presentSurface:(IOSurfaceRef)surface inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw sourceConsumed:(void (^)(void))consumed
{
    if (!surface || cancelled || failed) { if (consumed) consumed(); return NO; }
    NSUInteger iw=IOSurfaceGetWidth(surface),ih=IOSurfaceGetHeight(surface);
    if (![self configureWidth:iw height:ih]) { if (consumed) consumed(); return NO; }
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:iw height:ih mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared; descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> external=[device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    descriptor.storageMode=MTLStorageModePrivate;
    id<MTLTexture> immutable=[device newTextureWithDescriptor:descriptor];
    CFRetain(surface);
    BOOL result=[self presentTexture:immutable upload:nil external:external inLayer:parent frame:frame
        width:width height:height request:request needsDisplay:redraw sourceConsumed:^{
            if (consumed) consumed(); CFRelease(surface);
        }];
    [external release]; [immutable release]; return result;
}
- (BOOL)presentLatestInLayer:(CALayer *)parent frame:(CGRect)frame width:(NSUInteger)width
    height:(NSUInteger)height request:(WGDITemporalRequest)request needsDisplay:(void (^)(void))redraw
{
    id<MTLTexture> latest=[[currentTexture retain] autorelease];
    if (!latest) return NO;
    return [self presentTexture:latest upload:previousUpload external:nil inLayer:parent frame:frame
        width:width height:height request:request needsDisplay:redraw sourceConsumed:nil];
}
- (BOOL)presentTexture:(id<MTLTexture>)texture upload:(id<MTLBuffer>)upload external:(id<MTLTexture>)external
    inLayer:(CALayer *)parent frame:(CGRect)frame width:(NSUInteger)width height:(NSUInteger)height
    request:(WGDITemporalRequest)request needsDisplay:(void (^)(void))redraw sourceConsumed:(void (^)(void))consumed
{
    NSAssert(NSThread.isMainThread, @"Temporal presentation requires main-thread ownership");
    if (cancelled || failed || !texture || !parent || !width || !height || width>8192 || height>8192 ||
        (uint64_t)width*height>32u*1024u*1024u || CGRectIsEmpty(frame) || (consumed && !external)) {
        if (consumed) consumed(); return NO;
    }
    if (framesInFlight>=2) {
        displayLayer.hidden=NO; displayLayer.frame=frame;
        if (redraw) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        if (consumed) consumed(); return YES;
    }
    NSUInteger iw=inputWidth,ih=inputHeight;
    BOOL seedReference=!seeded;
    if (displayLayer.superlayer != parent) { [displayLayer removeFromSuperlayer]; [parent addSublayer:displayLayer]; }
    displayLayer.frame=frame; displayLayer.contentsScale=width/frame.size.width;
    displayLayer.drawableSize=CGSizeMake(width,height); displayLayer.hidden=NO;
    id<CAMetalDrawable> drawable=[displayLayer nextDrawable];
    if (!drawable) { if (consumed) consumed(); return NO; }
    struct wgdi_temporal_parameters p=[self parameters];
    id<MTLBuffer> metadata=[device newBufferWithLength:(NSUInteger)p.block_columns*p.block_rows*sizeof(uint32_t)
        options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    if (!metadata || !command) { [metadata release]; if (consumed) consumed(); failed=YES; return NO; }
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
        [seed setTexture:referenceTexture atIndex:1]; [seed setBytes:&p length:sizeof(p) atIndex:0];
        [self dispatch:seed width:iw height:ih]; [seed endEncoding];
    }
    [self detect:command current:texture previous:previousTexture changes:changesTexture metadata:metadata parameters:p];
    id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
    [compute setComputePipelineState:maskPS]; [compute setTexture:changesTexture atIndex:0];
    [compute setTexture:weightsTexture atIndex:1]; [compute setBuffer:referenceTimes offset:0 atIndex:0];
    [compute setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:compute width:iw height:ih]; [compute endEncoding];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionDontCare; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];
    [render setRenderPipelineState:renderPS]; [render setFragmentTexture:texture atIndex:0];
    [render setFragmentTexture:residualTexture atIndex:1]; [render setFragmentTexture:weightsTexture atIndex:2];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [render endEncoding];
    uint64_t epoch=schedule.epoch, sequence=++frameSequence;
    double captured=[self now]; id<MTLBuffer> oldUpload=previousUpload;
    ++framesInFlight;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)oldUpload;
        if (consumed) consumed();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (framesInFlight) --framesInFlight;
            if (cancelled || epoch!=schedule.epoch) return;
            if (completed.status==MTLCommandBufferStatusError) {
                failed=YES; NSLog(@"Wine temporal: GPU presentation failed (%@)",completed.error);
                [displayLayer removeFromSuperlayer]; if (redraw) redraw(); return;
            }
            if (sequence==1) NSLog(@"Wine temporal: GPU presentation active, %lux%lu source, %lu metadata bytes",
                (unsigned long)iw,(unsigned long)ih,(unsigned long)metadata.length);
            if (trace && sequence%120==0 && completed.GPUEndTime>completed.GPUStartTime)
                NSLog(@"Wine temporal: frame %llu GPU %.3f ms",(unsigned long long)sequence,
                    (completed.GPUEndTime-completed.GPUStartTime)*1000.0);
            if (sequence>schedule.observed_sequence) {
                wgdi_temporal_observe(&schedule,(const uint32_t *)metadata.contents,epoch,sequence,captured);
                [analysedUpload release]; analysedUpload=[upload retain];
                [analysedTexture release]; analysedTexture=[texture retain];
                [self refine:request redraw:redraw];
            }
            if ([self now]<fadeUntil && redraw)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/60),dispatch_get_main_queue(),redraw);
        });
    }];
    [previousTexture release]; previousTexture=[texture retain];
    [currentTexture release]; currentTexture=[texture retain];
    [upload retain]; [previousUpload release]; previousUpload=upload;
    [command presentDrawable:drawable]; [command commit]; seeded=YES;
    [metadata release];
    return YES;
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
    for (NSUInteger y=0;y<inputHeight*2;++y)
        memcpy((uint8_t *)neuralBuffer.contents+y*neuralStride,(const uint8_t *)output.bytes+y*inputWidth*8,inputWidth*8);
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
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:inputPS]; [encoder setTexture:job atIndex:0]; [encoder setTexture:referenceTexture atIndex:1];
    [encoder setBuffer:accepted offset:0 atIndex:0]; [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:encoder width:inputWidth height:inputHeight]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:residualPS]; [encoder setTexture:job atIndex:0];
    [encoder setTexture:neural atIndex:1]; [encoder setTexture:residualTexture atIndex:2];
    [encoder setBuffer:accepted offset:0 atIndex:0]; [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [self dispatch:encoder width:inputWidth*2 height:inputHeight*2]; [encoder endEncoding];
    encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:timesPS]; [encoder setBuffer:accepted offset:0 atIndex:0];
    [encoder setBuffer:referenceTimes offset:0 atIndex:1]; [encoder setBytes:&p length:sizeof(p) atIndex:2];
    [self dispatch:encoder width:p.block_columns height:p.block_rows]; [encoder endEncoding];
    NSData *jobInput=pendingInput; uint64_t epoch=pendingEpoch;
    NSUInteger iw=inputWidth, ih=inputHeight;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)jobBuffer; (void)neuralBuffer;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled || epoch!=schedule.epoch || token!=pendingToken) return;
            if (completed.status==MTLCommandBufferStatusError) {
                failed=YES; NSLog(@"Wine temporal: reference admission failed (%@)",completed.error);
                [displayLayer removeFromSuperlayer]; [self clearPending]; if (redraw) redraw(); return;
            }
            const uint32_t *valid=(const uint32_t *)accepted.contents;
            NSUInteger updated=0;
            for (NSUInteger by=0;by<p.block_rows;++by) for (NSUInteger bx=0;bx<p.block_columns;++bx) {
                if (!valid[by*p.block_columns+bx]) continue;
                NSUInteger x=bx*16, y=by*16, right=MIN(iw,x+16), bottom=MIN(ih,y+16);
                for (NSUInteger row=y;row<bottom;++row)
                    memcpy((uint8_t *)referenceCPU.mutableBytes+(row*iw+x)*4,
                        (const uint8_t *)jobInput.bytes+(row*iw+x)*4,(right-x)*4);
                ++updated;
            }
            if (trace) NSLog(@"Wine temporal: admitted %lu/%lu blocks for request %llu",
                (unsigned long)updated,(unsigned long)blocks,(unsigned long long)token);
            if (updated) fadeUntil=MAX(fadeUntil,[self now]+WGDI_TEMPORAL_FADE_SECONDS);
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
