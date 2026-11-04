/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Included once by cocoa_upscaler.m. Selection uses the supplied GDI image;
 * all window interaction and profile writes run on the Cocoa main thread.
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#include "wine_gdi_exclusions.h"
#include <math.h>

BOOL wine_gdi_region_picker_is_window(NSWindow *window);
BOOL wine_gdi_region_picker_blocks_window(NSWindow *window);
BOOL wine_gdi_region_picker_is_active(void);

static BOOL wgdi_picker_active, wgdi_picker_deferred;
static NSWindow *wgdi_picker_owner;
static NSPanel *wgdi_picker_panel;
static NSView *wgdi_picker_offer_view;
static CGImageRef wgdi_picker_image;
static IOSurfaceRef wgdi_picker_surface;
static void (^wgdi_picker_redraw)(void);
static NSTimeInterval wgdi_picker_first_frame;

BOOL wine_gdi_region_picker_is_window(NSWindow *window)
{
    return wgdi_picker_panel && window == wgdi_picker_panel;
}

BOOL wine_gdi_region_picker_blocks_window(NSWindow *window)
{
    return wgdi_picker_active && window && window == wgdi_picker_owner;
}

BOOL wine_gdi_region_picker_is_active(void)
{
    return wgdi_picker_active;
}

static NSString *wgdi_picker_token(void)
{
    const char *value = getenv("WINE_GDI_UPSCALER_PICK");
    NSString *raw = value ? [NSString stringWithUTF8String:value] : @"auto";
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    NSString *token = [[raw componentsSeparatedByCharactersInSet:[allowed invertedSet]] componentsJoinedByString:@""];
    return token.length ? [token substringToIndex:MIN((NSUInteger)100, token.length)] : @"auto";
}

@protocol WGDIRegionClipController <NSObject>
+ (instancetype)sharedController;
- (void)suspendClippingForRegionPicker;
- (void)resumeClippingForRegionPicker:(BOOL)ownerVisible;
- (void)releaseMouseCapture;
@end

static id<WGDIRegionClipController> wgdi_clip_controller(void)
{
    Class cls = NSClassFromString(@"WineApplicationController");
    if (!cls || ![cls respondsToSelector:@selector(sharedController)]) return nil;
    id<WGDIRegionClipController> controller = [cls sharedController];
    return controller;
}

/* The OpenGL presentation path keeps the latest IOSurface; a CGImage snapshot
 * is materialized only when the panel actually opens. The provider holds a
 * read lock for the image lifetime. */
static void wgdi_picker_unlock_surface(void *info, const void *data, size_t size)
{
    (void)data; (void)size;
    IOSurfaceRef surface = (IOSurfaceRef)info;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
}

static CGImageRef wgdi_picker_snapshot(void)
{
    if (wgdi_picker_image || !wgdi_picker_surface) return wgdi_picker_image;
    IOSurfaceRef surface = wgdi_picker_surface;
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    if (!width || !height || stride < width * 4 ||
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess)
        return NULL;
    CFRetain(surface);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithData(surface,
        IOSurfaceGetBaseAddress(surface), stride * height, wgdi_picker_unlock_surface);
    wgdi_picker_image = CGImageCreate(width, height, 8, 32, stride, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, NO,
        kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return wgdi_picker_image;
}

static void wgdi_region_picker_teardown(BOOL ownerAlive);

@interface WineGDIRegionPickerView : NSView
{
    NSImage *snapshot;
    NSString *profile, *message;
    NSMutableArray *selections;
    NSPoint anchor;
    NSRect dragRect;
    BOOL dragging;
    double sourceAspect;
}
- (id)initWithImage:(CGImageRef)image profile:(NSString *)path;
+ (BOOL)shouldOfferForImage:(CGImageRef)image profile:(NSString *)file;
@end

@interface WineGDIRegionPickerPanel : NSPanel <NSWindowDelegate>
- (id)initWithImage:(CGImageRef)image profile:(NSString *)path;
- (void)placeOnScreen:(NSScreen *)screen;
@end

@implementation WineGDIRegionPickerView
+ (BOOL)shouldOfferForImage:(CGImageRef)image profile:(NSString *)file
{
    (void)image;
    if ([wgdi_picker_token() isEqualToString:@"off"]) return NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:file];
    BOOL needed = !exists;
    if (exists) {
        NSString *content = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
        char savedToken[128] = {0};
        if (content) sscanf(content.UTF8String, "# request=%127s", savedToken);
        NSString *request = wgdi_picker_token();
        if (![request isEqualToString:@"auto"] && ![request isEqualToString:[NSString stringWithUTF8String:savedToken]]) needed = YES;
    }
    return needed;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (id)initWithImage:(CGImageRef)image profile:(NSString *)path
{
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    snapshot = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(CGImageGetWidth(image), CGImageGetHeight(image))];
    sourceAspect = (double)CGImageGetWidth(image) / CGImageGetHeight(image);
    profile = [path copy]; selections = [[NSMutableArray alloc] init];
    message = [@"拖动框选文字区；可添加多个选区。⌘⇧U 可再次打开。" copy];
    NSArray *titles = @[@"保存", @"全部超分", @"稍后", @"清空"];
    SEL actions[] = {@selector(save:), @selector(clearAndSave:), @selector(postpone:), @selector(clear:)};
    CGFloat x = 12;
    for (NSUInteger i = 0; i < titles.count; ++i)
    {
        CGFloat width = i == 1 ? 80 : 60;
        NSButton *button = [NSButton buttonWithTitle:titles[i] target:self action:actions[i]];
        button.frame = NSMakeRect(x, 40, width, 28);
        [self addSubview:button]; x += width + 8;
    }
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self restoreProfile];
    return self;
}
- (void)restoreProfile
{
    NSString *content = [NSString stringWithContentsOfFile:profile encoding:NSUTF8StringEncoding error:NULL];
    if (!content) return;
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]])
    {
        if ([line hasPrefix:@"#"]) continue;
        struct wgdi_exclusions mask;
        if (!wgdi_parse_exclusions(line.UTF8String, &mask)) return;
        CGFloat width = mask.relative ? 10000 : snapshot.size.width;
        CGFloat height = mask.relative ? 10000 : snapshot.size.height;
        for (unsigned i = 0; i < mask.count; ++i)
        {
            const struct wgdi_exclusion *r = &mask.rects[i];
            NSRect rect = NSIntersectionRect(NSMakeRect(r->x / width, r->y / height,
                r->width / width, r->height / height), NSMakeRect(0, 0, 1, 1));
            if (!NSIsEmptyRect(rect)) [selections addObject:[NSValue valueWithRect:rect]];
        }
        return;
    }
}
- (void)dealloc
{
    [snapshot release]; [profile release]; [message release]; [selections release];
    [super dealloc];
}
- (NSRect)imageRect
{
    NSRect area = NSInsetRect(self.bounds, 12, 12);
    area.origin.y += 94; area.size.height = MAX(1, area.size.height - 94);
    CGFloat width = MIN(area.size.width, area.size.height * sourceAspect);
    CGFloat height = width / sourceAspect;
    return NSMakeRect(NSMidX(area) - width / 2, NSMidY(area) - height / 2, width, height);
}
- (NSRect)selectionDisplayRect:(NSRect)rect
{
    NSRect image = [self imageRect];
    return NSMakeRect(image.origin.x + rect.origin.x * image.size.width,
        image.origin.y + rect.origin.y * image.size.height,
        rect.size.width * image.size.width, rect.size.height * image.size.height);
}
- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
    [@"为此游戏选择超分屏蔽区域" drawAtPoint:NSMakePoint(12, 13) withAttributes:@{
        NSFontAttributeName:[NSFont boldSystemFontOfSize:14], NSForegroundColorAttributeName:NSColor.labelColor}];
    [message drawInRect:NSMakeRect(12, 75, self.bounds.size.width - 24, 30) withAttributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:11], NSForegroundColorAttributeName:NSColor.secondaryLabelColor}];
    NSRect image = [self imageRect];
    [snapshot drawInRect:image fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    for (NSValue *value in selections)
    {
        NSRect rect = [self selectionDisplayRect:value.rectValue];
        [[NSColor colorWithCalibratedRed:0 green:0.8 blue:0.7 alpha:0.25] setFill]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
        [NSColor.systemTealColor setStroke]; NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect]; path.lineWidth = 2; [path stroke];
    }
    if (dragging) { [NSColor.systemYellowColor setStroke]; NSBezierPath *path = [NSBezierPath bezierPathWithRect:dragRect]; path.lineWidth = 2; [path stroke]; }
}
- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, [self imageRect]) || selections.count >= WGDI_EXCLUSION_LIMIT) return;
    anchor = point; dragRect = NSMakeRect(point.x, point.y, 0, 0); dragging = YES;
}
- (void)mouseDragged:(NSEvent *)event
{
    if (!dragging) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect image = [self imageRect];
    point.x = MAX(NSMinX(image), MIN(NSMaxX(image), point.x));
    point.y = MAX(NSMinY(image), MIN(NSMaxY(image), point.y));
    dragRect = NSMakeRect(MIN(anchor.x, point.x), MIN(anchor.y, point.y), fabs(point.x-anchor.x), fabs(point.y-anchor.y));
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)event
{
    [self mouseDragged:event];
    if (dragging && dragRect.size.width >= 3 && dragRect.size.height >= 3)
    {
        NSRect image = [self imageRect];
        NSRect normalized = NSMakeRect((dragRect.origin.x-image.origin.x)/image.size.width,
            (dragRect.origin.y-image.origin.y)/image.size.height,
            dragRect.size.width/image.size.width, dragRect.size.height/image.size.height);
        [selections addObject:[NSValue valueWithRect:normalized]];
    }
    dragging = NO; [self setNeedsDisplay:YES];
}
- (void)writeSelection
{
    NSMutableArray *parts = [NSMutableArray array];
    for (NSValue *value in selections)
    {
        NSRect r = value.rectValue;
        unsigned x = (unsigned)floor(r.origin.x * 10000), y = (unsigned)floor(r.origin.y * 10000);
        unsigned right = MIN(10000u, (unsigned)ceil(NSMaxX(r) * 10000));
        unsigned bottom = MIN(10000u, (unsigned)ceil(NSMaxY(r) * 10000));
        [parts addObject:[NSString stringWithFormat:@"%u,%u,%u,%u", x,y,right-x,bottom-y]];
    }
    NSString *content = [NSString stringWithFormat:@"# request=%@ aspect=%.8f\nrelative:%@\n",
        wgdi_picker_token(), sourceAspect, [parts componentsJoinedByString:@";"]];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[profile stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error && [content writeToFile:profile atomically:YES encoding:NSUTF8StringEncoding error:&error]) { wgdi_region_picker_teardown(YES); return; }
    [message release]; message = [[NSString stringWithFormat:@"保存失败：%@", error.localizedDescription] copy]; [self setNeedsDisplay:YES];
}
- (void)save:(id)sender { (void)sender; [self writeSelection]; }
- (void)clearAndSave:(id)sender { (void)sender; [selections removeAllObjects]; [self writeSelection]; }
- (void)postpone:(id)sender { (void)sender; wgdi_picker_deferred = YES; wgdi_region_picker_teardown(YES); }
- (void)clear:(id)sender { (void)sender; [selections removeAllObjects]; [self setNeedsDisplay:YES]; }
- (void)keyDown:(NSEvent *)event { if (event.keyCode == 53) { wgdi_picker_deferred = YES; wgdi_region_picker_teardown(YES); } else [super keyDown:event]; }
@end

static NSRect wgdi_panel_frame(NSRect visible, NSSize size)
{
    size.width = MIN(size.width, MAX((CGFloat)308, visible.size.width - 40));
    size.height = MIN(size.height, MAX((CGFloat)120, visible.size.height - 40));
    size.width = MIN(size.width, visible.size.width);
    size.height = MIN(size.height, visible.size.height);
    NSRect frame = NSMakeRect(NSMidX(visible) - size.width / 2,
        NSMidY(visible) - size.height / 2, size.width, size.height);
    frame.origin.x = MAX(NSMinX(visible), MIN(NSMaxX(visible) - frame.size.width, frame.origin.x));
    frame.origin.y = MAX(NSMinY(visible), MIN(NSMaxY(visible) - frame.size.height, frame.origin.y));
    return frame;
}

@implementation WineGDIRegionPickerPanel
- (id)initWithImage:(CGImageRef)image profile:(NSString *)path
{
    self = [super initWithContentRect:NSMakeRect(0, 0, 720, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:YES];
    if (!self) return nil;
    self.title = @"超分屏蔽区域";
    self.delegate = self;
    self.floatingPanel = YES;
    self.releasedWhenClosed = NO;
    self.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorMoveToActiveSpace;
    WineGDIRegionPickerView *picker = [[WineGDIRegionPickerView alloc] initWithImage:image profile:path];
    picker.frame = NSMakeRect(0, 0, 720, 560);
    self.contentView = picker;
    [picker release];
    self.minSize = NSMakeSize(480, 360);
    return self;
}
- (void)placeOnScreen:(NSScreen *)screen
{
    NSScreen *target = screen ? screen : [NSScreen mainScreen];
    if (!target) target = NSScreen.screens.firstObject;
    if (!target) return;
    NSRect frame = wgdi_panel_frame(target.visibleFrame, self.frame.size);
    self.minSize = NSMakeSize(MIN((CGFloat)480, frame.size.width), MIN((CGFloat)360, frame.size.height));
    [self setFrame:frame display:NO];
}
- (void)ownerWillClose:(NSNotification *)notification
{
    (void)notification;
    wgdi_region_picker_teardown(NO);
}
- (void)ownerScreenChanged:(NSNotification *)notification
{
    (void)notification;
    if (wgdi_picker_owner)
        [self placeOnScreen:wgdi_picker_owner.screen];
}
- (void)windowWillClose:(NSNotification *)notification
{
    if (notification.object == wgdi_picker_owner)
        wgdi_region_picker_teardown(NO);
}
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    wgdi_picker_deferred = YES;
    wgdi_region_picker_teardown(YES);
    return NO;
}
@end

static void wgdi_region_picker_teardown(BOOL ownerAlive)
{
    if (!wgdi_picker_panel) { wgdi_picker_active = NO; return; }
    NSPanel *panel = wgdi_picker_panel;
    NSWindow *owner = wgdi_picker_owner;
    wgdi_picker_active = NO;
    wgdi_picker_panel = nil;
    wgdi_picker_owner = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:panel];
    if (owner) [owner removeChildWindow:panel];
    [panel close];
    [panel autorelease];
    BOOL ownerVisible = ownerAlive && owner && owner.isVisible;
    if (ownerVisible) [owner makeKeyWindow];
    if (ownerVisible && wgdi_picker_offer_view.window == owner)
        [wgdi_picker_offer_view setNeedsDisplay:YES];
    if (wgdi_picker_redraw) {
        void (^redraw)(void) = [wgdi_picker_redraw retain];
        [wgdi_picker_redraw release];
        wgdi_picker_redraw = nil;
        if (ownerVisible) redraw();
        [redraw release];
    }
    [wgdi_clip_controller() resumeClippingForRegionPicker:ownerVisible];
    if (!ownerAlive)
    {
        wgdi_picker_offer_view = nil;
        CGImageRelease(wgdi_picker_image);
        wgdi_picker_image = NULL;
        if (wgdi_picker_surface) { CFRelease(wgdi_picker_surface); wgdi_picker_surface = NULL; }
    }
}

static void wgdi_show_region_picker(NSView *view, CGImageRef image)
{
    const char *path = getenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
    if (!path || !*path || !view.window || !image || wgdi_picker_active) return;
    WineGDIRegionPickerPanel *panel = [[WineGDIRegionPickerPanel alloc]
        initWithImage:image profile:[NSString stringWithUTF8String:path]];
    [panel placeOnScreen:view.window.screen];
    CGImageRef snapshot = CGImageRetain(image);
    CGImageRelease(wgdi_picker_image);
    wgdi_picker_image = snapshot;
    wgdi_picker_offer_view = view;
    wgdi_picker_panel = panel;
    wgdi_picker_owner = view.window;
    wgdi_picker_active = YES;
    [view.window addChildWindow:panel ordered:NSWindowAbove];
    [[NSNotificationCenter defaultCenter] addObserver:panel selector:@selector(ownerWillClose:)
        name:NSWindowWillCloseNotification object:view.window];
    [[NSNotificationCenter defaultCenter] addObserver:panel selector:@selector(ownerScreenChanged:)
        name:NSWindowDidChangeScreenNotification object:view.window];
    id<WGDIRegionClipController> controller = wgdi_clip_controller();
    [controller suspendClippingForRegionPicker];
    [controller releaseMouseCapture];
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:panel.contentView];
}

static void wgdi_forget_region_view(NSView *view)
{
    if (wgdi_picker_owner == view.window) wgdi_region_picker_teardown(NO);
    if (wgdi_picker_offer_view != view) return;
    wgdi_picker_offer_view = nil;
    [wgdi_picker_redraw release];
    wgdi_picker_redraw = nil;
    if (wgdi_picker_image) { CGImageRelease(wgdi_picker_image); wgdi_picker_image = NULL; }
    if (wgdi_picker_surface) { CFRelease(wgdi_picker_surface); wgdi_picker_surface = NULL; }
}

static BOOL wgdi_picker_offer_allowed(NSView *view)
{
    const char *path = getenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
    if (!view || !path || !*path || [wgdi_picker_token() isEqualToString:@"off"]) return NO;
    if (!view.window.isVisible || view.bounds.size.width < 320 || view.bounds.size.height < 180) return NO;
    if (!wgdi_picker_active && !view.window.isKeyWindow) return NO;
    if (wgdi_picker_active && view.window != wgdi_picker_owner) return NO;
    return YES;
}

static void wgdi_offer_frame(NSView *view, void (^redraw)(void))
{
    if (wgdi_picker_active)
    {
        [wgdi_picker_redraw release];
        wgdi_picker_redraw = redraw ? [redraw copy] : nil;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            if ((flags & (NSEventModifierFlagCommand|NSEventModifierFlagShift)) == (NSEventModifierFlagCommand|NSEventModifierFlagShift) &&
                [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"u"] && wgdi_picker_offer_view &&
                (wgdi_picker_image || wgdi_picker_surface) && event.window == wgdi_picker_offer_view.window) {
                wgdi_show_region_picker(wgdi_picker_offer_view, wgdi_picker_snapshot()); return nil;
            }
            return event;
        }];
    });
    if (wgdi_picker_active) return;
    if (wgdi_picker_deferred) return;
    if (!wgdi_picker_first_frame) {
        wgdi_picker_first_frame = NSProcessInfo.processInfo.systemUptime;
        if (redraw) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), redraw);
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime - wgdi_picker_first_frame < 0.9) return;
    const char *path = getenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE");
    NSString *file = [NSString stringWithUTF8String:path];
    if ([WineGDIRegionPickerView shouldOfferForImage:NULL profile:file])
        wgdi_show_region_picker(view, wgdi_picker_snapshot());
}

static void wgdi_offer_region_picker(NSView *view, CGImageRef image, void (^redraw)(void))
{
    if (!image || !wgdi_picker_offer_allowed(view)) return;
    wgdi_picker_offer_view = view;
    CGImageRelease(wgdi_picker_image); wgdi_picker_image = CGImageRetain(image);
    if (wgdi_picker_surface) { CFRelease(wgdi_picker_surface); wgdi_picker_surface = NULL; }
    wgdi_offer_frame(view, redraw);
}

static void wgdi_offer_region_picker_surface(NSView *view, IOSurfaceRef surface, void (^redraw)(void))
{
    if (!surface || !wgdi_picker_offer_allowed(view)) return;
    wgdi_picker_offer_view = view;
    CFRetain(surface);
    if (wgdi_picker_surface) CFRelease(wgdi_picker_surface);
    wgdi_picker_surface = surface;
    CGImageRelease(wgdi_picker_image); wgdi_picker_image = NULL;
    wgdi_offer_frame(view, redraw);
}
