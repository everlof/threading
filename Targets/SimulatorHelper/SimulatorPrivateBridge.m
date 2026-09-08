#import "SimulatorPrivateBridge.h"

#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString * const SimulatorBridgeErrorDomain = @"codes.threading.simulator-helper";
static const NSUInteger SimulatorTouchMessageBytes = 0x140;
static const NSUInteger SimulatorPayloadBytes = 0x90;

typedef id (*ObjectGetter)(id, SEL);
typedef id (*ObjectErrorGetter)(id, SEL, NSError **);
typedef id (*ContextFactory)(Class, SEL, id, NSError **);
typedef id (*ScreenInitializer)(id, SEL, id, uint32_t);
typedef id (*HIDInitializer)(id, SEL, id, NSError **);
typedef void (*HIDSender)(id, SEL, void *, BOOL, dispatch_queue_t, void (^)(NSError *));
typedef void *(*MouseMessageBuilder)(CGPoint *, CGPoint *, int32_t, int32_t, BOOL);
typedef void *(*KeyboardMessageBuilder)(int32_t, int32_t);
typedef void *(*ButtonMessageBuilder)(int32_t, int32_t, int32_t);
// IndigoHIDMessageForHIDArbitrary(target, usagePage, usage, op) — the path volume and other
// consumer-page buttons take, unlike home/lock which use the button-key builder above.
typedef void *(*HIDArbitraryMessageBuilder)(int32_t, int32_t, int32_t, int32_t);

static NSError *BridgeError(NSInteger code, NSString *detail) {
    return [NSError errorWithDomain:SimulatorBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: detail}];
}

static id SendObject(id object, NSString *selector) {
    return ((ObjectGetter)objc_msgSend)(object, NSSelectorFromString(selector));
}

static NSDictionary *SigningInformation(SecCodeRef code) {
    CFDictionaryRef information = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) != errSecSuccess) {
        return nil;
    }
    return [(NSDictionary *)information autorelease];
}

static BOOL StaticCodeIsAppleSigned(NSString *path, NSError **error) {
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((CFURLRef)[NSURL fileURLWithPath:path], 0, &code);
    if (status == errSecSuccess) {
        status = SecRequirementCreateWithString(CFSTR("anchor apple"), 0, &requirement);
    }
    if (status == errSecSuccess) {
        status = SecStaticCodeCheckValidity(code, kSecCSCheckAllArchitectures, requirement);
    }
    if (code != NULL) { CFRelease(code); }
    if (requirement != NULL) { CFRelease(requirement); }
    if (status == errSecSuccess) { return YES; }
    if (error != NULL) {
        *error = BridgeError(10, [NSString stringWithFormat:
            @"The active Xcode Simulator framework is not Apple-signed (status %d).", status]);
    }
    return NO;
}

@interface SimulatorPrivateBridge () {
    id _device;
    id _deviceScreen;
    id _screenProxy;
    id _hidClient;
    void *_simulatorKitHandle;
    MouseMessageBuilder _mouseMessageBuilder;
    KeyboardMessageBuilder _keyboardMessageBuilder;
    ButtonMessageBuilder _buttonMessageBuilder;
    HIDArbitraryMessageBuilder _hidArbitraryMessageBuilder;
}
@property(nonatomic, readwrite, copy) NSString *coreSimulatorVersion;
@property(nonatomic, readwrite, copy) NSString *simulatorKitVersion;
@end

@implementation SimulatorPrivateBridge

+ (BOOL)hostProcessIsTrusted {
    SecCodeRef ownCode = NULL;
    SecCodeRef parentCode = NULL;
    OSStatus ownStatus = SecCodeCopySelf(0, &ownCode);
    pid_t parentPID = getppid();
    CFNumberRef parentNumber = CFNumberCreate(NULL, kCFNumberIntType, &parentPID);
    NSDictionary *attributes = @{(id)kSecGuestAttributePid: (id)parentNumber};
    OSStatus parentStatus = SecCodeCopyGuestWithAttributes(
        NULL,
        (CFDictionaryRef)attributes,
        kSecCSDefaultFlags,
        &parentCode
    );
    CFRelease(parentNumber);
    if (ownStatus != errSecSuccess || parentStatus != errSecSuccess) {
        if (ownCode != NULL) { CFRelease(ownCode); }
        if (parentCode != NULL) { CFRelease(parentCode); }
        return NO;
    }

    NSDictionary *own = SigningInformation(ownCode);
    NSDictionary *parent = SigningInformation(parentCode);
    CFRelease(ownCode);
    CFRelease(parentCode);
    NSString *ownTeam = own[(id)kSecCodeInfoTeamIdentifier];
    NSString *parentTeam = parent[(id)kSecCodeInfoTeamIdentifier];
    if (ownTeam.length > 0 || parentTeam.length > 0) {
        BOOL trusted = ownTeam.length > 0 && [ownTeam isEqualToString:parentTeam];
        return trusted;
    }

    // A clean checkout is ad-hoc signed. There is no team to compare, so keep the development
    // exception structural: the direct parent must be the Threading executable inside an app.
    NSURL *parentExecutable = parent[(id)kSecCodeInfoMainExecutable];
    BOOL trusted = [parentExecutable.path hasSuffix:@"/Threading.app/Contents/MacOS/Threading"];
    return trusted;
}

- (instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory
                                    deviceID:(NSUUID *)deviceID
                                       error:(NSError **)error {
    self = [super init];
    if (self == nil) { return nil; }

    NSString *resolvedDeveloper = [[developerDirectory stringByResolvingSymlinksInPath]
        stringByStandardizingPath];
    if (![resolvedDeveloper hasSuffix:@".app/Contents/Developer"] ||
        ![resolvedDeveloper hasPrefix:@"/Applications/"]) {
        if (error != NULL) {
            *error = BridgeError(20, @"The active developer directory is not an Xcode app in /Applications.");
        }
        [self release];
        return nil;
    }

    NSString *corePath = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator";
    NSString *kitPath = [resolvedDeveloper stringByAppendingPathComponent:
        @"Library/PrivateFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit"];
    BOOL coreIsDirectory = NO;
    BOOL kitIsDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:corePath isDirectory:&coreIsDirectory] ||
        coreIsDirectory ||
        ![[NSFileManager defaultManager] fileExistsAtPath:kitPath isDirectory:&kitIsDirectory] ||
        kitIsDirectory ||
        !StaticCodeIsAppleSigned(corePath, error) ||
        !StaticCodeIsAppleSigned(kitPath, error)) {
        if (error != NULL && *error == nil) {
            *error = BridgeError(21, @"The active Xcode does not contain the required Simulator frameworks.");
        }
        [self release];
        return nil;
    }

    void *coreHandle = dlopen(corePath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    _simulatorKitHandle = dlopen(kitPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (coreHandle == NULL || _simulatorKitHandle == NULL) {
        if (error != NULL) { *error = BridgeError(22, @"The Simulator frameworks could not be loaded."); }
        [self release];
        return nil;
    }

    Class contextClass = NSClassFromString(@"SimServiceContext");
    Class screenClass = NSClassFromString(@"SimulatorKit.SimDeviceScreen");
    Class hidClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    SEL contextSelector = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
    SEL deviceSetSelector = NSSelectorFromString(@"defaultDeviceSetWithError:");
    SEL devicesSelector = NSSelectorFromString(@"devicesByUDID");
    SEL screenSelector = NSSelectorFromString(@"initWithDevice:screenID:");
    if (contextClass == Nil || screenClass == Nil ||
        ![contextClass respondsToSelector:contextSelector] ||
        ![screenClass instancesRespondToSelector:screenSelector] ||
        ![screenClass instancesRespondToSelector:NSSelectorFromString(@"screen")]) {
        if (error != NULL) { *error = BridgeError(23, @"This Xcode's Simulator screen API is incompatible."); }
        [self release];
        return nil;
    }

    NSError *underlying = nil;
    id context = ((ContextFactory)objc_msgSend)(
        contextClass,
        contextSelector,
        resolvedDeveloper,
        &underlying
    );
    id deviceSet = context == nil ? nil : ((ObjectErrorGetter)objc_msgSend)(
        context,
        deviceSetSelector,
        &underlying
    );
    NSDictionary *devices = deviceSet == nil ? nil : ((ObjectGetter)objc_msgSend)(
        deviceSet,
        devicesSelector
    );
    _device = [[devices objectForKey:deviceID] retain];
    if (_device == nil) {
        if (error != NULL) {
            *error = BridgeError(24, @"The adopted Simulator device is unavailable.");
        }
        [self release];
        return nil;
    }

    @try {
        // CoreSimulator's integrated display is screen 1. The compatibility probe below checks
        // the surface selector and waits for the actual device surface before admitting it.
        _deviceScreen = ((ScreenInitializer)objc_msgSend)(
            [screenClass alloc],
            screenSelector,
            _device,
            1
        );
        _screenProxy = [SendObject(_deviceScreen, @"screen") retain];
    } @catch (NSException *exception) {
        if (error != NULL) { *error = BridgeError(25, exception.reason ?: @"The Simulator screen refused the connection."); }
        [self release];
        return nil;
    }
    if (_screenProxy == nil ||
        ![_screenProxy respondsToSelector:NSSelectorFromString(@"framebufferSurface")]) {
        if (error != NULL) { *error = BridgeError(26, @"This Xcode does not expose a compatible framebuffer surface."); }
        [self release];
        return nil;
    }

    _mouseMessageBuilder = (MouseMessageBuilder)dlsym(_simulatorKitHandle, "IndigoHIDMessageForMouseNSEvent");
    _keyboardMessageBuilder = (KeyboardMessageBuilder)dlsym(_simulatorKitHandle, "IndigoHIDMessageForKeyboardArbitrary");
    _buttonMessageBuilder = (ButtonMessageBuilder)dlsym(_simulatorKitHandle, "IndigoHIDMessageForButton");
    _hidArbitraryMessageBuilder = (HIDArbitraryMessageBuilder)dlsym(_simulatorKitHandle, "IndigoHIDMessageForHIDArbitrary");
    if (hidClass != Nil &&
        [hidClass instancesRespondToSelector:NSSelectorFromString(@"initWithDevice:error:")] &&
        [hidClass instancesRespondToSelector:NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:")] &&
        _mouseMessageBuilder != NULL && _keyboardMessageBuilder != NULL && _buttonMessageBuilder != NULL) {
        @try {
            _hidClient = ((HIDInitializer)objc_msgSend)(
                [hidClass alloc],
                NSSelectorFromString(@"initWithDevice:error:"),
                _device,
                &underlying
            );
        } @catch (__unused NSException *exception) {
            _hidClient = nil;
        }
    }

    NSBundle *coreBundle = [NSBundle bundleWithPath:[corePath stringByDeletingLastPathComponent]];
    NSBundle *kitBundle = [NSBundle bundleWithPath:[kitPath stringByDeletingLastPathComponent]];
    self.coreSimulatorVersion = [coreBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    self.simulatorKitVersion = [kitBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    return self;
}

- (BOOL)supportsInput {
    return _hidClient != nil && _mouseMessageBuilder != NULL &&
        _keyboardMessageBuilder != NULL && _buttonMessageBuilder != NULL;
}

- (IOSurfaceRef)copyCurrentSurface {
    @try {
        id surface = SendObject(_screenProxy, @"framebufferSurface");
        if (surface == nil) { return NULL; }
        return (IOSurfaceRef)CFRetain((CFTypeRef)surface);
    } @catch (__unused NSException *exception) {
        return NULL;
    }
}

- (BOOL)sendTouchAtX:(double)x y:(double)y down:(BOOL)down error:(NSError **)error {
    return [self sendTouchAtX:x y:y down:down wait:YES error:error];
}

- (BOOL)sendTouchAtX:(double)x y:(double)y down:(BOOL)down wait:(BOOL)wait error:(NSError **)error {
    if (!self.supportsInput || !isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
        if (error != NULL) { *error = BridgeError(30, @"The touch is outside the adopted screen."); }
        return NO;
    }
    CGPoint point = CGPointMake(x, y);
    void *source = _mouseMessageBuilder(&point, NULL, 0x32, down ? 1 : 2, NO);
    if (source == NULL || malloc_size(source) < 0xA0) {
        if (source != NULL) { free(source); }
        if (error != NULL) { *error = BridgeError(31, @"SimulatorKit did not construct a touch message."); }
        return NO;
    }

    void *message = calloc(1, SimulatorTouchMessageBytes);
    if (message == NULL) {
        free(source);
        if (error != NULL) { *error = BridgeError(32, @"The touch message could not be allocated."); }
        return NO;
    }
    *(uint32_t *)(message + 0x18) = (uint32_t)SimulatorPayloadBytes;
    *(uint8_t *)(message + 0x1c) = 2;
    *(uint32_t *)(message + 0x20) = 0xB;
    *(uint64_t *)(message + 0x24) = mach_absolute_time();
    memcpy(message + 0x30, source + 0x30, 0x70);
    *(double *)(message + 0x3c) = x;
    *(double *)(message + 0x44) = y;
    free(source);
    memcpy(message + 0xB0, message + 0x20, SimulatorPayloadBytes);
    *(uint32_t *)(message + 0xC0) = 1;
    *(uint32_t *)(message + 0xC4) = 2;
    return [self sendMessage:message waitForCompletion:wait error:error];
}

- (BOOL)sendKeyboardUsage:(uint32_t)usage down:(BOOL)down error:(NSError **)error {
    if (!self.supportsInput || usage > 0xE7) {
        if (error != NULL) { *error = BridgeError(33, @"The keyboard usage is unsupported."); }
        return NO;
    }
    void *message = _keyboardMessageBuilder((int32_t)usage, down ? 1 : 2);
    if (message == NULL) {
        if (error != NULL) { *error = BridgeError(34, @"SimulatorKit did not construct a keyboard message."); }
        return NO;
    }
    return [self sendMessage:message error:error];
}

- (BOOL)sendButtonSource:(int32_t)source down:(BOOL)down error:(NSError **)error {
    if (!self.supportsInput || (source != 0 && source != 1 && source != 3000)) {
        if (error != NULL) { *error = BridgeError(35, @"The hardware button is unsupported."); }
        return NO;
    }
    void *message = _buttonMessageBuilder(source, down ? 1 : 2, 0x33);
    if (message == NULL) {
        if (error != NULL) { *error = BridgeError(36, @"SimulatorKit did not construct a button message."); }
        return NO;
    }
    return [self sendMessage:message error:error];
}

- (BOOL)sendHIDUsagePage:(uint32_t)usagePage
                   usage:(uint32_t)usage
                    down:(BOOL)down
                   error:(NSError * _Nullable * _Nullable)error {
    if (!self.supportsInput || _hidArbitraryMessageBuilder == NULL) {
        if (error != NULL) { *error = BridgeError(38, @"Arbitrary HID input is unavailable in this Xcode."); }
        return NO;
    }
    // 0x32 is the digitizer routing target the mouse path uses; consumer-page usages (volume) go
    // through here rather than the button-key builder.
    void *message = _hidArbitraryMessageBuilder(0x32, (int32_t)usagePage, (int32_t)usage, down ? 1 : 2);
    if (message == NULL) {
        if (error != NULL) { *error = BridgeError(39, @"SimulatorKit did not construct an HID message."); }
        return NO;
    }
    return [self sendMessage:message error:error];
}

- (BOOL)sendMessage:(void *)message error:(NSError **)error {
    return [self sendMessage:message waitForCompletion:YES error:error];
}

- (BOOL)sendMessage:(void *)message waitForCompletion:(BOOL)wait error:(NSError **)error {
    if (_hidClient == nil) {
        free(message);
        if (error != NULL) { *error = BridgeError(37, @"Simulator input is unavailable in this Xcode."); }
        return NO;
    }
    if (!wait) {
        // Fire-and-forget: dispatch the HID send and return without blocking on its completion.
        // This is the streamed-move path — waiting on each move's HID completion serialized
        // panning at the HID rate. `freeWhenDone:YES` still frees the message.
        @try {
            ((HIDSender)objc_msgSend)(
                _hidClient,
                NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"),
                message,
                YES,
                dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                ^(NSError *sendError) { (void)sendError; }
            );
        } @catch (NSException *exception) {
            if (error != NULL) { *error = BridgeError(38, exception.reason ?: @"Simulator input failed."); }
            return NO;
        }
        return YES;
    }
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    __block NSError *completionError = nil;
    @try {
        ((HIDSender)objc_msgSend)(
            _hidClient,
            NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"),
            message,
            YES,
            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
            ^(NSError *sendError) {
                completionError = [sendError retain];
                dispatch_semaphore_signal(completion);
            }
        );
    } @catch (NSException *exception) {
        // Ownership may already have crossed the private call; leaking one bounded message is
        // safer than guessing and double-freeing it.
        if (error != NULL) { *error = BridgeError(38, exception.reason ?: @"Simulator input failed."); }
        dispatch_release(completion);
        return NO;
    }
    long waitResult = dispatch_semaphore_wait(
        completion,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)
    );
    dispatch_release(completion);
    if (waitResult != 0) {
        if (error != NULL) { *error = BridgeError(39, @"Simulator input was not acknowledged."); }
        return NO;
    }
    if (completionError != nil && error != NULL) { *error = [[completionError retain] autorelease]; }
    [completionError release];
    return completionError == nil;
}

- (void)dealloc {
    [_coreSimulatorVersion release];
    [_simulatorKitVersion release];
    [_hidClient release];
    [_screenProxy release];
    [_deviceScreen release];
    [_device release];
    if (_simulatorKitHandle != NULL) { dlclose(_simulatorKitHandle); }
    [super dealloc];
}

@end
