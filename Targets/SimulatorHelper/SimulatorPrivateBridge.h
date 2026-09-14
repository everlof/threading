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
/// Whether the host-side accessibility-translation path loaded and this Xcode exposes the private
/// selectors the snapshot needs. When NO, `-copyAccessibilitySnapshotWithError:` refuses.
@property(nonatomic, readonly) BOOL supportsAccessibility;

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
- (BOOL)sendTouchAtX:(double)x
                   y:(double)y
                down:(BOOL)down
                wait:(BOOL)wait
               error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendTouch(x:y:down:wait:));
- (BOOL)sendKeyboardUsage:(uint32_t)usage
                     down:(BOOL)down
                    error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendKeyboard(usage:down:));
- (BOOL)sendButtonSource:(int32_t)source
                    down:(BOOL)down
                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendButton(source:down:));
- (BOOL)sendHIDUsagePage:(uint32_t)usagePage
                   usage:(uint32_t)usage
                    down:(BOOL)down
                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(sendHIDUsage(page:usage:down:));

/// Read the foreground app's accessibility tree host-side through the private `AXPTranslator` path.
/// Returns a nested tree of plain property-list dictionaries — one per element — with keys:
/// `role` (NSString, an AX role), `subrole` (NSString, optional), `label` (NSString, optional),
/// `value` (NSString, optional), `identifier` (NSString, optional), `enabled` (NSNumber bool),
/// `frame` (NSArray of four NSNumbers: x, y, width, height in device logical points), and
/// `children` (NSArray of the same shape). Every element carries `role`, `enabled` and `frame`.
/// The whole call runs on one serial queue (the translator singleton is process-wide and its token
/// storage is not thread-safe), and each attribute fetch is a synchronous bridge to the guest.
- (nullable NSDictionary *)accessibilitySnapshotWithError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(accessibilitySnapshot());

@end

NS_ASSUME_NONNULL_END
