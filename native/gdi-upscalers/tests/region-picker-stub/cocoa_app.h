#import <AppKit/AppKit.h>
@interface WineApplicationController : NSObject
+ (WineApplicationController *)sharedController;
- (void)suspendClippingForRegionPicker;
- (void)resumeClippingForRegionPicker:(BOOL)ownerVisible;
- (void)releaseMouseCapture;
@property (nonatomic) BOOL suspended, resumedVisible;
@end
