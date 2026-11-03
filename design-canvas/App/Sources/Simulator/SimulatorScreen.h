#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>

#if TARGET_OS_MACCATALYST

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SimulatorTouchPhase) {
    SimulatorTouchPhaseBegan,
    SimulatorTouchPhaseMoved,
    SimulatorTouchPhaseEnded,
};

/// A booted iOS Simulator's screen and input, through CoreSimulator and SimulatorKit: the
/// private frameworks Simulator.app and Xcode's previews use. Frames are the simulator's
/// own framebuffer, and touches and keys arrive as if from the Simulator window.
@interface SimulatorScreen : NSObject

/// Nil, with `error` saying why, when this Xcode's frameworks or the device aren't there.
- (nullable instancetype)initWithUDID:(NSString *)udid error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

/// Called on a private serial queue with the framebuffer each time the simulator draws a
/// frame, so drawing it never waits for the main thread.
@property (atomic, copy, nullable) void (^NS_SWIFT_SENDABLE frameHandler)(IOSurfaceRef surface);

/// A touch at a point in the unit square of the screen, top-left origin.
- (void)sendTouch:(SimulatorTouchPhase)phase at:(CGPoint)point;
/// A key by its HID usage code, as in `UIKeyboardHIDUsage`.
- (void)sendKey:(uint32_t)usage down:(BOOL)down;

/// Stops frames. The screen also stops when it's deallocated.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

#endif
