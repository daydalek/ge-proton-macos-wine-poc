/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import "cocoa_app.h"
#import "cocoa_region_picker.h"
#include <objc/runtime.h>
#include <stdio.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %d: %s\n", __LINE__, #c); ++failures; } } while (0)

@implementation WineApplicationController
static WineApplicationController *shared;
+ (WineApplicationController *)sharedController { if (!shared) shared = [[WineApplicationController alloc] init]; return shared; }
- (void)suspendClippingForRegionPicker { self.suspended = YES; }
- (void)resumeClippingForRegionPicker:(BOOL)ownerVisible { self.suspended = NO; self.resumedVisible = ownerVisible; }
- (void)releaseMouseCapture { }
@end

static CGImageRef makeImage(unsigned w, unsigned h)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 0.2, 0.4, 0.6, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); CGColorSpaceRelease(space);
    return image;
}

static NSEvent *mouse(NSEventType type, NSPoint p, NSWindow *w)
{
    return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0
        windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

static NSEvent *view_mouse(NSEventType type, NSPoint point, NSView *view)
{
    return mouse(type, [view convertPoint:point toView:nil], view.window);
}

static void check_buttons(WineGDIRegionPickerView *view)
{
    unsigned count = 0;
    for (NSView *child in view.subviews)
    {
        if (![child isKindOfClass:[NSButton class]]) continue;
        CHECK(NSContainsRect(view.bounds, child.frame));
        NSPoint center = NSMakePoint(NSMidX(child.frame), NSMidY(child.frame));
        CHECK([view hitTest:[view convertPoint:center toView:view.superview]] == child);
        ++count;
    }
    CHECK(count == 4);
}

static NSArray *selectionsOf(WineGDIRegionPickerView *view)
{
    for (NSView *v in view.subviews) (void)v;
    Ivar ivar = class_getInstanceVariable([view class], "selections");
    return object_getIvar(view, ivar);
}

int main(void)
{
    @autoreleasepool {
    [NSApplication sharedApplication];
    setenv("WINE_GDI_UPSCALER_PICK", "auto", 1);
    CGImageRef image = makeImage(640, 480);
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"wgdi-picker-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *profile = [dir stringByAppendingPathComponent:@"probe.regions"];
    setenv("WINE_GDI_UPSCALER_EXCLUDE_PROFILE", profile.fileSystemRepresentation, 1);
    wgdi_offer_region_picker(nil, image, nil);
    wgdi_offer_region_picker_surface(nil, NULL, nil);

    {
        IOSurfaceRef probeSurface = IOSurfaceCreate((CFDictionaryRef)@{
            (id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @48,
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @256,
            (id)kIOSurfacePixelFormat: @(0x42475241u)});
        CHECK(probeSurface != NULL);
        wgdi_offer_region_picker_surface(nil, probeSurface, nil);
        wgdi_picker_surface = probeSurface;
        CGImageRef snapshot = wgdi_picker_snapshot();
        CHECK(snapshot && CGImageGetWidth(snapshot) == 64 && CGImageGetHeight(snapshot) == 48);
        CGImageRelease(snapshot); wgdi_picker_image = NULL;
        wgdi_picker_surface = NULL;
        CFRelease(probeSurface);
    }

    {
        NSRect f = wgdi_panel_frame(NSMakeRect(0, 0, 1920, 1080), NSMakeSize(720, 560));
        CHECK(f.origin.x == 600 && f.origin.y == 260 && f.size.width == 720);
        f = wgdi_panel_frame(NSMakeRect(-1920, 0, 1920, 1080), NSMakeSize(720, 560));
        CHECK(f.origin.x == -1320 && f.origin.y == 260);
        CHECK(NSMinX(f) >= -1920 && NSMaxX(f) <= 0);
        f = wgdi_panel_frame(NSMakeRect(-500, -500, 400, 300), NSMakeSize(720, 560));
        CHECK(NSMinX(f) >= -500 && NSMinY(f) >= -500);
        CHECK(NSMaxX(f) <= -100 && NSMaxY(f) <= -200);
    }

    NSWindow *owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    owner.releasedWhenClosed = NO;
    NSView *gameView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
    owner.contentView = gameView;

    [[NSFileManager defaultManager] removeItemAtPath:profile error:NULL];
    WineGDIRegionPickerPanel *panel = [[WineGDIRegionPickerPanel alloc] initWithImage:image profile:profile];
    WineGDIRegionPickerView *picker = (WineGDIRegionPickerView *)panel.contentView;
    [panel setContentSize:NSMakeSize(720, 560)];
    [picker layoutSubtreeIfNeeded];
    check_buttons(picker);
    [panel setContentSize:NSMakeSize(900, 700)];
    [picker layoutSubtreeIfNeeded];
    check_buttons(picker);
    panel.minSize = NSMakeSize(308, 120);
    [panel setContentSize:NSMakeSize(308, 210)];
    [picker layoutSubtreeIfNeeded];
    check_buttons(picker);
    [panel setContentSize:NSMakeSize(720, 560)];
    [picker layoutSubtreeIfNeeded];

    {
        NSArray *sel = selectionsOf(picker);
        CHECK(sel.count == 0);
        NSRect img = [picker imageRect];
        [picker clear:nil];
        CHECK(sel.count == 0);
        [picker mouseDown:view_mouse(NSEventTypeLeftMouseDown, NSMakePoint(5, 5), picker)];
        [picker mouseUp:view_mouse(NSEventTypeLeftMouseUp, NSMakePoint(6, 6), picker)];
        CHECK(sel.count == 0);
        NSPoint a = NSMakePoint(NSMidX(img) + 50, NSMidY(img) + 40);
        NSPoint b = NSMakePoint(NSMinX(img) - 40, NSMinY(img) - 60);
        [picker mouseDown:view_mouse(NSEventTypeLeftMouseDown, a, picker)];
        [picker mouseDragged:view_mouse(NSEventTypeLeftMouseDragged, b, picker)];
        [picker mouseUp:view_mouse(NSEventTypeLeftMouseUp, b, picker)];
        CHECK(sel.count == 1);
        NSRect n = [sel.lastObject rectValue];
        CHECK(n.origin.x >= 0 && n.origin.y >= 0 && NSMaxX(n) <= 1 && NSMaxY(n) <= 1);
        CHECK(n.size.width > 0 && n.size.height > 0);
        CHECK(n.origin.x == 0 && n.origin.y == 0);
        CHECK(fabs(n.size.width - (a.x - img.origin.x) / img.size.width) < 0.00001);
        CHECK(fabs(n.size.height - (a.y - img.origin.y) / img.size.height) < 0.00001);
        [picker save:nil];
        NSString *saved = [NSString stringWithContentsOfFile:profile encoding:NSUTF8StringEncoding error:NULL];
        CHECK(saved && [saved containsString:@"relative:"] && [saved containsString:@"# request="]);
    }

    {
        WineGDIRegionPickerView *restored = [[WineGDIRegionPickerView alloc] initWithImage:image profile:profile];
        CHECK(selectionsOf(restored).count == 1);
        [restored release];
    }

    {
        [owner orderFront:nil];
        wgdi_show_region_picker(gameView, image);
        [gameView setNeedsDisplay:NO];
        for (NSView *button in wgdi_picker_panel.contentView.subviews)
            if ([button isKindOfClass:[NSButton class]] && [[(NSButton *)button title] isEqualToString:@"保存"])
                [(NSButton *)button performClick:nil];
        CHECK(!wine_gdi_region_picker_is_active());
        CHECK(gameView.needsDisplay);
        wgdi_show_region_picker(gameView, image);
        CHECK(wine_gdi_region_picker_is_active());
        CHECK(wine_gdi_region_picker_is_window(wgdi_picker_panel));
        CHECK(!wine_gdi_region_picker_is_window(owner));
        CHECK(wine_gdi_region_picker_blocks_window(owner));
        NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        CHECK(!wine_gdi_region_picker_blocks_window(other));
        [other release];
        NSPanel *shown = wgdi_picker_panel;
        [owner close];
        CHECK(!wine_gdi_region_picker_is_active());
        CHECK(wgdi_picker_panel == nil && wgdi_picker_owner == nil);
        (void)shown;
        CHECK(![WineApplicationController sharedController].suspended);
    }

    {
        NSWindow *owner2 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        owner2.releasedWhenClosed = NO;
        NSView *v2 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        owner2.contentView = v2;
        wgdi_show_region_picker(v2, image);
        CHECK(wine_gdi_region_picker_is_active());
        WineGDIRegionPickerView *pv = (WineGDIRegionPickerView *)wgdi_picker_panel.contentView;
        [pv postpone:nil];
        CHECK(!wine_gdi_region_picker_is_active());
        CHECK(wgdi_picker_panel == nil);
        [owner2 close];
        [v2 release];
        [owner2 release];
    }

    {
        [[NSFileManager defaultManager] removeItemAtPath:profile error:NULL];
        WineGDIRegionPickerPanel *empty = [[WineGDIRegionPickerPanel alloc] initWithImage:image profile:profile];
        WineGDIRegionPickerView *pv = (WineGDIRegionPickerView *)empty.contentView;
        [pv clearAndSave:nil];
        NSString *saved = [NSString stringWithContentsOfFile:profile encoding:NSUTF8StringEncoding error:NULL];
        CHECK(saved && [saved containsString:@"relative:\n"]);
        CHECK(![WineGDIRegionPickerView shouldOfferForImage:image profile:profile]);
        [empty close];
        [empty release];
    }

    CGImageRelease(image);
    wgdi_forget_region_view(gameView);
    [panel close];
    [panel release];
    [owner release];
    [gameView release];
    if (failures) { fprintf(stderr, "%d picker probe checks failed\n", failures); return 1; }
    puts("region-picker-probe: all checks passed");
    }
    return 0;
}
