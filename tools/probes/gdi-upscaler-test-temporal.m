/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "wine_gdi_temporal_presenter.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

static unsigned mockPresentCount, mockCancelCount, mockCompleteCount;

@interface MockTemporalPresenter : NSObject <WGDITemporalPresenter>
@end
@implementation MockTemporalPresenter {
#ifdef WGDI_MOCK_HAS_SELECTION
    NSUInteger mockWidth, mockHeight;
#endif
}
- (CALayer *)layer { return nil; }
- (BOOL)presentImage:(CGImageRef)image inLayer:(CALayer *)parent frame:(CGRect)frame
    width:(NSUInteger)width height:(NSUInteger)height request:(WGDITemporalRequest)request
    needsDisplay:(void (^)(void))redraw
{
    (void)image; (void)parent; (void)frame;
    (void)redraw;
    ++mockPresentCount;
    if (getenv("WGDI_MOCK_SELECTION") && request) {
#ifdef WGDI_MOCK_HAS_SELECTION
        mockWidth = width; mockHeight = height;
#endif
        request([NSMutableData dataWithLength:width * height * 4], width, height, 1);
    }
    return YES;
}
#ifdef WGDI_MOCK_HAS_SELECTION
- (NSData *)selectedTilesForToken:(uint64_t)token
{
    if (token != 1 || !getenv("WGDI_MOCK_SELECTION") || !mockWidth || !mockHeight)
        return nil;
    const NSUInteger count = ((mockWidth + 255) / 256) * ((mockHeight + 255) / 256);
    NSMutableData *mask = [NSMutableData dataWithLength:count * sizeof(uint32_t)];
    *(uint32_t *)mask.mutableBytes = 1;
    return mask;
}
#endif
- (void)completeOutput:(NSData *)output token:(uint64_t)token needsDisplay:(void (^)(void))redraw
{
    (void)output; (void)token; (void)redraw;
    ++mockCompleteCount;
}
- (void)cancel { ++mockCancelCount; }
@end

id<WGDITemporalPresenter> wine_gdi_temporal_create(uint32_t abi, const char *resources)
{
    (void)resources;
    if (abi != WGDI_TEMPORAL_PRESENTER_ABI) return nil;
    return [[MockTemporalPresenter alloc] init];
}

unsigned wgdi_mock_temporal_present_count(void) { return mockPresentCount; }
unsigned wgdi_mock_temporal_cancel_count(void) { return mockCancelCount; }
unsigned wgdi_mock_temporal_complete_count(void) { return mockCompleteCount; }
