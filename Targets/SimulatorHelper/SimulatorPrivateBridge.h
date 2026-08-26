#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// The only file that knows the runtime names in CoreSimulator and SimulatorKit.
///
/// The target is compiled without ARC because SimulatorKit's Swift-native screen initializer has
/// an Objective-C selector but non-standard ownership metadata; an ARC `objc_msgSend` trampoline
/// over-releases its result. Keeping that boundary here also means the app never links a private
/// framework or imports a private header.
@interface SimulatorPrivateBridge : NSObject

@property(nonatomic, readonly) NSString *coreSimulatorVersion;
@property(nonatomic, readonly) NSString *simulatorKitVersion;
@property(nonatomic, readonly) BOOL supportsInput;

+ (BOOL)hostProcessIsTrusted;

- (nullable instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory
                                             deviceID:(NSUUID *)deviceID
                                                error:(NSError * _Nullable * _Nullable)error;

- (nullable IOSurfaceRef)copyCurrentSurface CF_RETURNS_RETAINED;

- (BOOL)sendTouchAtX:(double)x
                   y:(double)y
                down:(BOOL)down
               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendTouch(x:y:down:));
- (BOOL)sendKeyboardUsage:(uint32_t)usage
                     down:(BOOL)down
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendKeyboard(usage:down:));
- (BOOL)sendButtonSource:(int32_t)source
                    down:(BOOL)down
                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendButton(source:down:));

@end

NS_ASSUME_NONNULL_END
