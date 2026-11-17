//go:build darwin && arm64 && cgo && !no_vz
#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import "bridge.h"
#import "../../scripts/guest-os/macos-setup-view.m"

static VZVirtualMachine *machine;
static CageGuestSetupView *loginView;
static NSWindow *desktopWindow;
static VZVirtualMachineView *desktopView;

// VZ's Mac keyboard uses device-specific modifier bits as well as AppKit's
// aggregate flags. App-scoped input tools may supply only the latter.
static NSEvent *desktopKeyboardEvent(NSEvent *event) {
    BOOL flagsOnly = event.type == NSEventTypeFlagsChanged;
    NSEventModifierFlags flags = event.modifierFlags;
    if (flags & NSEventModifierFlagShift) flags |= NX_DEVICELSHIFTKEYMASK;
    if (flags & NSEventModifierFlagControl) flags |= NX_DEVICELCTLKEYMASK;
    if (flags & NSEventModifierFlagOption) flags |= NX_DEVICELALTKEYMASK;
    if (flags & NSEventModifierFlagCommand) flags |= NX_DEVICELCMDKEYMASK;
    return [NSEvent keyEventWithType:event.type location:event.locationInWindow modifierFlags:flags
        timestamp:event.timestamp windowNumber:event.windowNumber context:nil
        characters:flagsOnly ? @"" : event.characters ?: @"" charactersIgnoringModifiers:flagsOnly ? @"" : event.charactersIgnoringModifiers ?: @""
        isARepeat:!flagsOnly && event.isARepeat keyCode:event.keyCode];
}
@interface CageDesktopView : VZVirtualMachineView {
    NSEventModifierFlags _guestModifiers;
}
@end
@implementation CageDesktopView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)syncModifiers:(NSEventModifierFlags)flags {
    const NSEventModifierFlags bits[] = { NSEventModifierFlagShift, NSEventModifierFlagControl, NSEventModifierFlagOption, NSEventModifierFlagCommand };
    const unsigned short codes[] = {56,59,58,55};
    for (int i=0;i<4;i++) {
        if ((_guestModifiers & bits[i]) == (flags & bits[i])) continue;
        BOOL down = (flags & bits[i]) != 0;
        if (down) _guestModifiers |= bits[i]; else _guestModifiers &= ~bits[i];
        NSEvent *change = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:_guestModifiers
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:self.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:codes[i]];
        [super flagsChanged:desktopKeyboardEvent(change)];
        NSEvent *physical = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint modifierFlags:_guestModifiers
            timestamp:change.timestamp windowNumber:change.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:codes[i]];
        if (down) [super keyDown:desktopKeyboardEvent(physical)]; else [super keyUp:desktopKeyboardEvent(physical)];
    }
}
- (void)keyDown:(NSEvent *)event { [self syncModifiers:event.modifierFlags]; [super keyDown:desktopKeyboardEvent(event)]; }
- (void)keyUp:(NSEvent *)event { [super keyUp:desktopKeyboardEvent(event)]; [self syncModifiers:event.modifierFlags]; }
- (void)flagsChanged:(NSEvent *)event { [self syncModifiers:event.modifierFlags]; [super flagsChanged:desktopKeyboardEvent(event)]; }
- (void)resetGuestModifiers { [self syncModifiers:0]; }
@end

@interface CageNativeApplication : NSApplication
@end
@implementation CageNativeApplication
- (void)sendEvent:(NSEvent *)event {
    BOOL keyboard = event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged;
    BOOL targeted = desktopWindow && (event.window == desktopWindow || (!event.window && keyboard && self.keyWindow == desktopWindow));
    // VZ's local event monitor consumes app-scoped modifier events before the
    // window responder receives them. Deliver keys through its public view API.
    if (keyboard && targeted && desktopView) {
        if (event.type == NSEventTypeKeyDown) [desktopView keyDown:event];
        else if (event.type == NSEventTypeKeyUp) [desktopView keyUp:event];
        else [desktopView flagsChanged:event];
        return;
    }
    [super sendEvent:event];
}
@end

@interface CageDesktopDelegate : NSObject <NSWindowDelegate>
@end
@implementation CageDesktopDelegate
- (void)windowDidResignKey:(NSNotification *)notification {
    [(CageDesktopView *)desktopView resetGuestModifiers];
}
- (void)windowWillClose:(NSNotification *)notification {
    [(CageDesktopView *)desktopView resetGuestModifiers];
    desktopView.virtualMachine = nil;
    desktopWindow.contentView = nil;
    desktopView = nil;
    desktopWindow = nil;
}
@end
static CageDesktopDelegate *desktopDelegate;
// Match the virtual Mac's scanout. The input protocol retains its original
// 16:10 coordinate system, regardless of host window size or display scaling.
static const CGFloat scanWidth = 1920, scanHeight = 1200;

void cageLoginLoop(void *ref) {
    @autoreleasepool {
        machine = (__bridge VZVirtualMachine *)ref;
        NSApplication *app = [CageNativeApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app run];
        [desktopWindow close]; [loginView close]; loginView = nil; machine = nil;
    }
}
bool cageDesktopOpen(void) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!machine) return;
        if (desktopWindow) { [desktopWindow makeKeyAndOrderFront:nil]; ok = YES; return; }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSRect rect = NSMakeRect(0, 0, 1200, 750);
        desktopWindow = [[NSWindow alloc] initWithContentRect:rect
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        desktopWindow.releasedWhenClosed = NO;
        desktopWindow.title = @"Cage Dev — 虚拟 Mac 桌面";
        desktopWindow.contentAspectRatio = NSMakeSize(1920, 1200);
        desktopWindow.minSize = NSMakeSize(640, 400);
        desktopView = [[CageDesktopView alloc] initWithFrame:rect];
        desktopView.virtualMachine = machine;
        desktopView.capturesSystemKeys = YES;
        desktopView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        desktopWindow.contentView = desktopView;
        desktopDelegate = [CageDesktopDelegate new];
        desktopWindow.delegate = desktopDelegate;
        [desktopWindow center];
        [desktopWindow makeKeyAndOrderFront:nil];
        [desktopWindow makeFirstResponder:desktopView];
        [NSApp activateIgnoringOtherApps:YES];
        ok = YES;
    });
    return ok;
}
void cageDesktopClose(void) {
    dispatch_sync(dispatch_get_main_queue(), ^{ [desktopWindow close]; });
}
bool cageDesktopIsOpen(void) {
    __block BOOL result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = desktopWindow != nil; });
    return result;
}
void cageLoginStop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
    });
}
void cageLoginEnable(bool enabled) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [loginView close]; loginView = nil;
        if (enabled && machine) loginView = [[CageGuestSetupView alloc] initWithMachine:machine size:NSMakeSize(scanWidth,scanHeight)
            setupAuthorized:^BOOL { return machine != nil; }];
    });
}
void *cageLoginImage(int *size) {
    __block void *copy = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSData *image = [loginView snapshotJPEG];
            if (image.length && image.length <= (4<<20)) {
                copy = malloc(image.length);
                if (copy) { memcpy(copy, image.bytes, image.length); *size = (int)image.length; }
            }
        }
    });
    return copy;
}
void *cageLoginImageRegion(int x, int y, int width, int height, int *size) {
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > 1024 || y + height > 640) return NULL;
    __block void *copy = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSData *frame = [loginView snapshotJPEG];
            if (!frame.length) return;
            NSBitmapImageRep *source = [NSBitmapImageRep imageRepWithData:frame];
            if (!source.CGImage) return;
            CGRect region = CGRectMake(x * source.pixelsWide / 1024.0, y * source.pixelsHigh / 640.0,
                                       width * source.pixelsWide / 1024.0, height * source.pixelsHigh / 640.0);
            CGImageRef cropped = CGImageCreateWithImageInRect(source.CGImage, region);
            if (!cropped) return;
            NSBitmapImageRep *output = [[NSBitmapImageRep alloc] initWithCGImage:cropped];
            CGImageRelease(cropped);
            NSData *image = [output representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor:@0.92}];
            if (image.length && image.length <= (4<<20)) {
                copy = malloc(image.length);
                if (copy) { memcpy(copy, image.bytes, image.length); *size = (int)image.length; }
            }
        }
    });
    return copy;
}
bool cageLoginClick(int x, int y) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{ ok = [loginView clickAtX:x * scanWidth / 1024.0 y:y * scanHeight / 640.0]; });
    return ok;
}
bool cageLoginKey(int code, bool shift) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!loginView) return;
        // A hardware modifier carries both the aggregate flag and the left/right
        // device bit. The offscreen view has no host keyboard state to inherit.
        NSEventModifierFlags flags = shift ? NSEventModifierFlagShift | NX_DEVICELSHIFTKEYMASK : 0;
        NSEvent *(^event)(NSEventType, int, NSEventModifierFlags) = ^NSEvent *(NSEventType kind, int key, NSEventModifierFlags mods) {
            return [NSEvent keyEventWithType:kind location:NSZeroPoint modifierFlags:mods timestamp:NSProcessInfo.processInfo.systemUptime
                windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:(unsigned short)key];
        };
        if (shift) {
            [loginView sendKey:event(NSEventTypeFlagsChanged,56,flags)];
            [loginView sendKey:event(NSEventTypeKeyDown,56,flags)];
        }
        ok = [loginView sendKey:event(NSEventTypeKeyDown,code,flags)] && [loginView sendKey:event(NSEventTypeKeyUp,code,flags)];
        if (shift) {
            [loginView sendKey:event(NSEventTypeKeyUp,56,0)];
            [loginView sendKey:event(NSEventTypeFlagsChanged,56,0)];
        }
    });
    return ok;
}
bool cageLoginSelectAll(void) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!loginView) return;
        NSEventModifierFlags command = NSEventModifierFlagCommand | NX_DEVICELCMDKEYMASK;
        NSEvent *(^event)(NSEventType, int, NSEventModifierFlags) = ^NSEvent *(NSEventType kind, int key, NSEventModifierFlags flags) {
            return [NSEvent keyEventWithType:kind location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime
                windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:(unsigned short)key];
        };
        [loginView sendKey:event(NSEventTypeFlagsChanged,55,command)];
        [loginView sendKey:event(NSEventTypeKeyDown,55,command)];
        ok = [loginView sendKey:event(NSEventTypeKeyDown,0,command)] && [loginView sendKey:event(NSEventTypeKeyUp,0,command)];
        [loginView sendKey:event(NSEventTypeKeyUp,55,0)];
        [loginView sendKey:event(NSEventTypeFlagsChanged,55,0)];
    });
    return ok;
}
bool cageLoginScroll(int x, int y, int deltaX, int deltaY) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = [loginView scrollAtX:x * scanWidth / 1024.0 y:y * scanHeight / 640.0
            deltaX:deltaX * scanWidth / 1024.0 deltaY:deltaY * scanHeight / 640.0];
    });
    return ok;
}
