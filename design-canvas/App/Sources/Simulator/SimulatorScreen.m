#import "SimulatorScreen.h"

#if TARGET_OS_MACCATALYST

#import <dlfcn.h>
#import <objc/message.h>
#import <stdio.h>

// SimulatorKit's message builders. The touch builder takes a point and the screen size
// in the same units and writes the unit-square point the simulator expects.
typedef void *(*IndigoMouseFunction)(CGPoint *, CGPoint *, uint32_t, NSUInteger, CGSize, uint32_t);
typedef void *(*IndigoKeyFunction)(uint32_t, uint32_t);

static const uint32_t IndigoTouchScreenTarget = 0x32;
static const uint32_t IndigoDown = 1;
static const uint32_t IndigoUp = 2;
// NSEventType values, which the touch builder takes; AppKit isn't linked under Catalyst.
static const NSUInteger LeftMouseDown = 1, LeftMouseUp = 2, LeftMouseDragged = 6;

// The private methods this file calls, declared so the compiler knows their selectors.
@protocol SimulatorPrivateMethods
+ (id)sharedServiceContextForDeveloperDir:(NSString *)directory error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (id)initWithDevice:(id)device error:(NSError **)error;
- (id)descriptor;
- (id)framebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(id)frameCallback
                surfacesChangedCallback:(id)surfacesChangedCallback
              propertiesChangedCallback:(id)propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (void)sendWithMessage:(void *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue
             completion:(id)completion;
@end

static NSError *SimulatorError(NSString *message) {
    return [NSError errorWithDomain:@"SimulatorScreen" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The developer directory `xcode-select` points at, which SimulatorKit lives next to.
static NSString *DeveloperDirectory(void) {
    NSString *environment = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (environment.length > 0) return environment;
    FILE *pipe = popen("/usr/bin/xcode-select -p", "r");
    if (pipe == NULL) return nil;
    char buffer[PATH_MAX] = {0};
    char *line = fgets(buffer, sizeof buffer, pipe);
    pclose(pipe);
    if (line == NULL) return nil;
    return [@(line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@implementation SimulatorScreen {
    id _hid;
    NSArray *_screens;
    NSMutableArray<NSUUID *> *_registrations;
    // Frames arrive and are handled here; input completes on `_inputQueue`, so a frame
    // waiting for a drawable never delays a touch.
    dispatch_queue_t _queue;
    dispatch_queue_t _inputQueue;
    IndigoMouseFunction _touch;
    IndigoKeyFunction _key;
    // Only touched on `_queue`.
    id _surface;
}

- (instancetype)initWithUDID:(NSString *)udid error:(NSError **)error {
    if (!(self = [super init])) return nil;
    @try {
        NSString *developer = DeveloperDirectory();
        NSString *kitPath = [developer.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
        void *core = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
        void *kit = developer ? dlopen(kitPath.fileSystemRepresentation, RTLD_NOW) : NULL;
        _touch = kit ? (IndigoMouseFunction)dlsym(kit, "IndigoHIDMessageForMouseNSEvent") : NULL;
        _key = kit ? (IndigoKeyFunction)dlsym(kit, "IndigoHIDMessageForKeyboardArbitrary") : NULL;
        Class contextClass = NSClassFromString(@"SimServiceContext");
        Class hidClass = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
        if (!core || !kit || !_touch || !_key || !contextClass || !hidClass) {
            if (error) *error = SimulatorError(@"This Xcode's simulator frameworks aren't the ones the preview knows.");
            return nil;
        }

        NSError *inner = nil;
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            contextClass, @selector(sharedServiceContextForDeveloperDir:error:), developer, &inner);
        id set = context ? ((id (*)(id, SEL, NSError **))objc_msgSend)(context, @selector(defaultDeviceSetWithError:), &inner) : nil;
        id device = nil;
        for (id candidate in [set valueForKey:@"devices"]) {
            if ([[[candidate valueForKey:@"UDID"] UUIDString] isEqualToString:udid]) device = candidate;
        }
        if (device == nil) {
            if (error) *error = inner ?: SimulatorError([NSString stringWithFormat:@"No simulator %@.", udid]);
            return nil;
        }
        _hid = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([hidClass alloc], @selector(initWithDevice:error:), device, &inner);
        if (_hid == nil) {
            if (error) *error = inner ?: SimulatorError(@"The simulator's input isn't available.");
            return nil;
        }

        // A device has a port per display; the ones without a framebuffer stay quiet.
        NSMutableArray *screens = [NSMutableArray array];
        for (id port in [[device valueForKey:@"io"] valueForKey:@"ioPorts"]) {
            id descriptor = [port performSelector:@selector(descriptor)];
            if ([descriptor respondsToSelector:@selector(framebufferSurface)]
                && [descriptor respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)]) {
                [screens addObject:descriptor];
            }
        }
        _screens = screens;
        _registrations = [NSMutableArray array];
        _queue = dispatch_queue_create("SimulatorScreen.frames", DISPATCH_QUEUE_SERIAL);
        _inputQueue = dispatch_queue_create("SimulatorScreen.input", DISPATCH_QUEUE_SERIAL);
        for (id screen in screens) [self watch:screen];
    } @catch (NSException *exception) {
        if (error) *error = SimulatorError(exception.reason ?: exception.name);
        return nil;
    }
    return self;
}

- (void)watch:(id)screen {
    NSUUID *registration = [NSUUID UUID];
    [_registrations addObject:registration];
    __weak SimulatorScreen *weakSelf = self;
    __weak id weakScreen = screen;
    dispatch_async(_queue, ^{
        SimulatorScreen *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        id surface = [weakScreen performSelector:@selector(framebufferSurface)];
        if (surface != nil) strongSelf->_surface = surface;
    });
    ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
        screen,
        @selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:),
        registration, _queue,
        ^{
            SimulatorScreen *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (strongSelf->_surface == nil) strongSelf->_surface = [weakScreen performSelector:@selector(framebufferSurface)];
            [strongSelf deliverFrame];
        },
        ^(id surface, id masked) {
            SimulatorScreen *strongSelf = weakSelf;
            if (strongSelf != nil && surface != nil) strongSelf->_surface = surface;
        },
        ^(id properties) {});
}

/// On `_queue`.
- (void)deliverFrame {
    void (^handler)(IOSurfaceRef) = self.frameHandler;
    if (_surface != nil && handler != nil) handler((__bridge IOSurfaceRef)_surface);
}

- (void)sendTouch:(SimulatorTouchPhase)phase at:(CGPoint)point {
    NSUInteger type = phase == SimulatorTouchPhaseBegan ? LeftMouseDown
        : phase == SimulatorTouchPhaseEnded ? LeftMouseUp : LeftMouseDragged;
    CGPoint location = CGPointMake(MIN(MAX(point.x, 0), 1), MIN(MAX(point.y, 0), 1));
    [self send:_touch(&location, NULL, IndigoTouchScreenTarget, type, CGSizeMake(1, 1), 0)];
}

- (void)sendKey:(uint32_t)usage down:(BOOL)down {
    [self send:_key(usage, down ? IndigoDown : IndigoUp)];
}

- (void)send:(void *)message {
    if (message == NULL) return;
    @try {
        ((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(
            _hid, @selector(sendWithMessage:freeWhenDone:completionQueue:completion:), message, YES, _inputQueue,
            ^(NSError *error) {});
    } @catch (NSException *exception) {
        NSLog(@"SimulatorScreen: sending input failed: %@", exception.reason);
    }
}

- (void)invalidate {
    for (NSUInteger index = 0; index < _registrations.count && index < _screens.count; index++) {
        @try {
            [_screens[index] performSelector:@selector(unregisterScreenCallbacksWithUUID:) withObject:_registrations[index]];
        } @catch (NSException *exception) {
        }
    }
    [_registrations removeAllObjects];
    self.frameHandler = nil;
}

- (void)dealloc {
    [self invalidate];
}

@end

#endif
