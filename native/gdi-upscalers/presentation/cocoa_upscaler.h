/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import "cocoa_spatial.h"
#include "wine_gdi_upscaler.h"
#include "wine_gdi_frame_diff.h"
#include "wine_gdi_upscale_policy.h"
#import "wine_gdi_temporal_presenter.h"

@interface WineGDIUpscaler : NSObject
{
    WineSpatialScaler *metalFX;
    id<WGDITemporalPresenter> temporal;
    unsigned algorithm;
    void *context;
    BOOL inFlight, failed;
    NSData *latestInput, *resultInput;
    NSMutableData *capture;
    CGContextRef captureBitmap;
    NSUInteger captureWidth, captureHeight;
    NSUInteger inferenceCount, cacheHitCount;
    NSUInteger fastInferenceCount;
    BOOL neuralFailed, fastFailed, stabilityTimerPending;
    struct wgdi_stability stability;
    NSData *fastInput;
    CGImageRef fastResult;
    NSUInteger fastWidth, fastHeight;
    NSUInteger fastInputWidth, fastInputHeight;
    CGImageRef result;
    NSUInteger latestWidth, latestHeight, latestOutputWidth, latestOutputHeight;
    NSUInteger resultWidth, resultHeight, resultOutputWidth, resultOutputHeight;
}
+ (BOOL) enabled;
+ (BOOL)temporalEnabled;
- (BOOL)supportsTemporalSurfaces;
- (void)cancelTemporalPresentation;
- (BOOL)presentSurface:(IOSurfaceRef)surface inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height needsDisplay:(void (^)(void))redraw
    sourceConsumed:(void (^)(void))consumed;
- (BOOL)redrawTemporalInLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height needsDisplay:(void (^)(void))redraw;
- (void)hideTemporalPresentation;
- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height needsDisplay:(void (^)(void))redraw;
- (NSUInteger) inferenceCount;
- (NSUInteger) cacheHitCount;
- (NSUInteger) neuralInferenceCount;
- (NSUInteger) fastInferenceCount;
- (CGImageRef) copyScaledImage:(CGImageRef)image width:(NSUInteger)width height:(NSUInteger)height
                 needsDisplay:(void (^)(void))needsDisplay;
@end
