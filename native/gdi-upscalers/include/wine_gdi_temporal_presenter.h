/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_TEMPORAL_PRESENTER_H
#define WINE_GDI_TEMPORAL_PRESENTER_H
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#import <QuartzCore/CALayer.h>
#import <IOSurface/IOSurface.h>

/* Snapshot BGRA is tightly packed, top row first. Neural output is always 2x.
 * Request returns YES only when the owner accepted the asynchronous job. */
typedef BOOL (^WGDITemporalRequest)(NSData *input, NSUInteger width, NSUInteger height, uint64_t token);
@protocol WGDITemporalPresenter <NSObject>
- (CALayer *)layer;
- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw;
@optional
/* The producer completes OpenGL writes before calling this method. The callback
 * releases its bounded source slot after Metal copies it to immutable storage. */
- (BOOL)presentSurface:(IOSurfaceRef)surface inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw sourceConsumed:(void (^)(void))consumed;
- (BOOL)presentLatestInLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw;
- (NSData *)selectedTilesForToken:(uint64_t)token;
@required
- (void)completeOutput:(NSData *)output token:(uint64_t)token needsDisplay:(void (^)(void))redraw;
- (void)cancel;
@end
#define WGDI_TEMPORAL_PRESENTER_ABI 1u
typedef id<WGDITemporalPresenter> (*wgdi_temporal_create_fn)(uint32_t abi, const char *resources);
#ifdef __cplusplus
extern "C" {
#endif
/* Returns a retained object. Optional extension of the unchanged upscaler ABI. */
__attribute__((visibility("default"))) id<WGDITemporalPresenter>
wine_gdi_temporal_create(uint32_t abi, const char *resources);
#ifdef __cplusplus
}
#endif
#endif
