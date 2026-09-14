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

#pragma mark - Accessibility snapshot support

// The private AXPTranslator path, validated live and recorded in
// docs/feature-drafts/simulator-accessibility-interaction.md. The host-side framework a host
// process links (the macOS copy, not the runtime's iOS one).
static NSString * const SimulatorAXPFrameworkPath =
    @"/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation";

// AXPTranslator MultipleAttribute request type and the attribute numbers we read. Sourced from idb's
// SimulatorFrameworkBridge (FBAXPRequestTypeMultipleAttribute = 5; the attribute enum) and confirmed
// against the live device — the recipe is in the feature draft.
static const NSUInteger SimulatorAXRequestTypeMultipleAttribute = 5;
static const NSUInteger SimulatorAXAttributeChildren = 8;
static const NSUInteger SimulatorAXAttributeFrame = 21;
static const NSUInteger SimulatorAXAttributeIdentifier = 25;
static const NSUInteger SimulatorAXAttributeIsEnabled = 27;
static const NSUInteger SimulatorAXAttributeLabel = 33;
static const NSUInteger SimulatorAXAttributeRole = 45;
static const NSUInteger SimulatorAXAttributeSubrole = 51;
static const NSUInteger SimulatorAXAttributeValue = 53;

// Bounds on a whole-tree read (idb caps depth 50 / 3000 nodes) so a pathological hierarchy cannot
// stall the helper or exhaust memory.
static const NSInteger SimulatorAXMaxDepth = 50;
static const NSInteger SimulatorAXMaxNodes = 3000;

// AXPUIElementType (numeric guest role) → AX role string. The six confirmed against the live device
// by zipping idb's ordered string types against these numbers; unmapped values become "AXType<n>" so
// they stay distinguishable rather than collapsing. The table is verified per Xcode (see the draft's
// per-Xcode signature note); it is a hint layer, with identifier/label/frame carrying addressing.
static NSString *SimulatorAXRoleString(NSNumber *roleNumber) {
    if (![roleNumber isKindOfClass:[NSNumber class]]) { return @"AXUnknown"; }
    switch (roleNumber.integerValue) {
        case 1: return @"AXApplication";
        case 2: return @"AXButton";
        case 5: return @"AXGroup";
        case 6: return @"AXHeading";
        case 7: return @"AXImage";
        case 14: return @"AXStaticText";
        default: return [NSString stringWithFormat:@"AXType%ld", (long)roleNumber.integerValue];
    }
}

// Relay one opaque AXPTranslatorRequest to the guest via `-[SimDevice sendAccessibilityRequestAsync:]`,
// bridging the async XPC to a synchronous return with a semaphore (5 s timeout). Returns the
// AXPTranslatorResponse (autoreleased) or nil. This is the single host→guest hop; both the token
// delegate callback and the per-element attribute fetch go through it.
static id SimulatorAXRelayRequest(id device, id request) {
    if (device == nil || request == nil) { return nil; }
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    __block id response = nil;
    void (^handler)(id) = ^(id result) {
        response = [result retain];
        dispatch_semaphore_signal(completion);
    };
    @try {
        ((void (*)(id, SEL, id, dispatch_queue_t, id))objc_msgSend)(
            device,
            NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:"),
            request,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            handler
        );
    } @catch (__unused NSException *exception) {
        dispatch_release(completion);
        return nil;
    }
    long waitResult = dispatch_semaphore_wait(
        completion, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    dispatch_release(completion);
    if (waitResult != 0) { return nil; }
    return [response autorelease];
}

// Fetch a fixed set of attributes for one translation object with a single MultipleAttribute request
// (requestType 5). `clientType` is deliberately left unset — setting it makes the guest answer from a
// stale automation override and children come back empty. Returns the response's `resultData`
// dictionary (keyed by NSNumber attribute id) or nil.
static NSDictionary *SimulatorAXFetchAttributes(id device, id translation) {
    Class requestClass = NSClassFromString(@"AXPTranslatorRequest");
    if (requestClass == Nil || translation == nil) { return nil; }
    id request = ((id (*)(id, SEL, id))objc_msgSend)(
        requestClass, NSSelectorFromString(@"requestWithTranslation:"), translation);
    if (request == nil) { return nil; }
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
        request, NSSelectorFromString(@"setRequestType:"), SimulatorAXRequestTypeMultipleAttribute);
    NSArray *attributes = @[
        @(SimulatorAXAttributeChildren), @(SimulatorAXAttributeFrame),
        @(SimulatorAXAttributeIdentifier), @(SimulatorAXAttributeIsEnabled),
        @(SimulatorAXAttributeLabel), @(SimulatorAXAttributeRole),
        @(SimulatorAXAttributeSubrole), @(SimulatorAXAttributeValue)
    ];
    ((void (*)(id, SEL, id))objc_msgSend)(
        request, NSSelectorFromString(@"setParameters:"), @{@"attributes": attributes});
    id response = SimulatorAXRelayRequest(device, request);
    if (response == nil) { return nil; }
    id data = ((id (*)(id, SEL))objc_msgSend)(response, NSSelectorFromString(@"resultData"));
    return [data isKindOfClass:[NSDictionary class]] ? data : nil;
}

// The bridge/token delegate the translator calls back into. Its one job is to relay each opaque
// AXPTranslatorRequest the translator builds to the guest, bridging that async XPC to the
// translator's synchronous delegate contract. Holds the device unretained — the owning bridge
// outlives it.
@interface SimulatorAXBridgeDelegate : NSObject
@property(nonatomic, assign) id device;
@end

@implementation SimulatorAXBridgeDelegate

- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(id)token {
    SimulatorAXBridgeDelegate *__unsafe_unretained weakSelf = self;
    id block = ^id(id request) {
        return SimulatorAXRelayRequest(weakSelf.device, request);
    };
    return [[block copy] autorelease];
}

- (id)accessibilityTranslationRootParentWithToken:(id)token {
    return nil;
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)frame withToken:(id)token {
    // idb's implementation is identity — the frames already arrive in screen space.
    return frame;
}

@end

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
    // Accessibility snapshot state. `_axQueue` serializes every translator interaction because the
    // AXPTranslator singleton's token storage is not thread-safe (concurrent use over-releases it →
    // EXC_BAD_ACCESS). Set up lazily on the first snapshot.
    void *_axpHandle;
    id _axTranslator;
    SimulatorAXBridgeDelegate *_axBridgeDelegate;
    dispatch_queue_t _axQueue;
    BOOL _axSetupAttempted;
    BOOL _axSupported;
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
    _axQueue = dispatch_queue_create("codes.threading.simulator-helper.accessibility", DISPATCH_QUEUE_SERIAL);
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

#pragma mark - Accessibility snapshot

// Build one node's plain-dictionary form from a translation object, recursing on its children.
// Bounded by depth and a running node count. Returns an autoreleased dictionary, or nil when the
// element could not be read or a bound was hit.
static NSDictionary *SimulatorAXBuildNode(id device, id translation, NSInteger depth, NSInteger *nodeCount) {
    if (depth > SimulatorAXMaxDepth || *nodeCount >= SimulatorAXMaxNodes) { return nil; }
    NSDictionary *attributes = SimulatorAXFetchAttributes(device, translation);
    if (attributes == nil) { return nil; }
    (*nodeCount)++;

    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"role"] = SimulatorAXRoleString(attributes[@(SimulatorAXAttributeRole)]);

    id label = attributes[@(SimulatorAXAttributeLabel)];
    if ([label isKindOfClass:[NSString class]] && [label length] > 0) { node[@"label"] = label; }
    id value = attributes[@(SimulatorAXAttributeValue)];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) { node[@"value"] = value; }
    id identifier = attributes[@(SimulatorAXAttributeIdentifier)];
    if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) {
        node[@"identifier"] = identifier;
    }
    id subrole = attributes[@(SimulatorAXAttributeSubrole)];
    if ([subrole isKindOfClass:[NSString class]] && [subrole length] > 0) { node[@"subrole"] = subrole; }

    id enabled = attributes[@(SimulatorAXAttributeIsEnabled)];
    node[@"enabled"] = @([enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES);

    NSRect frame = NSZeroRect;
    id frameValue = attributes[@(SimulatorAXAttributeFrame)];
    if ([frameValue isKindOfClass:[NSValue class]] &&
        [frameValue respondsToSelector:@selector(rectValue)]) {
        frame = [frameValue rectValue];
    }
    node[@"frame"] = @[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)];

    id children = attributes[@(SimulatorAXAttributeChildren)];
    if ([children isKindOfClass:[NSArray class]] && [children count] > 0) {
        NSMutableArray *childNodes = [NSMutableArray array];
        for (id child in children) {
            if (*nodeCount >= SimulatorAXMaxNodes) { break; }
            NSDictionary *childNode = SimulatorAXBuildNode(device, child, depth + 1, nodeCount);
            if (childNode != nil) { [childNodes addObject:childNode]; }
        }
        if ([childNodes count] > 0) { node[@"children"] = childNodes; }
    }
    return node;
}

- (BOOL)ensureAccessibilityReadyLocked {
    if (_axSetupAttempted) { return _axSupported; }
    _axSetupAttempted = YES;

    _axpHandle = dlopen(SimulatorAXPFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    Class translatorClass = NSClassFromString(@"AXPTranslator");
    Class requestClass = NSClassFromString(@"AXPTranslatorRequest");
    SEL sharedSelector = NSSelectorFromString(@"sharedmacOSInstance");
    SEL frontmostSelector = NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:");
    SEL tokenSelector = NSSelectorFromString(@"accessibilityPlatformTranslationToken");
    SEL relaySelector = NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:");
    if (_axpHandle == NULL || translatorClass == Nil || requestClass == Nil ||
        ![translatorClass respondsToSelector:sharedSelector] ||
        ![translatorClass instancesRespondToSelector:frontmostSelector] ||
        ![translatorClass instancesRespondToSelector:NSSelectorFromString(@"setBridgeDelegate:")] ||
        ![translatorClass instancesRespondToSelector:NSSelectorFromString(@"setSupportsDelegateTokens:")] ||
        ![requestClass respondsToSelector:NSSelectorFromString(@"requestWithTranslation:")] ||
        _device == nil ||
        ![_device respondsToSelector:tokenSelector] ||
        ![_device respondsToSelector:relaySelector]) {
        _axSupported = NO;
        return NO;
    }

    id translator = ((id (*)(id, SEL))objc_msgSend)(translatorClass, sharedSelector);
    if (translator == nil) { _axSupported = NO; return NO; }
    _axTranslator = [translator retain];

    if ([_axTranslator respondsToSelector:NSSelectorFromString(@"setAccessibilityEnabled:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            _axTranslator, NSSelectorFromString(@"setAccessibilityEnabled:"), YES);
    }
    if ([_axTranslator respondsToSelector:NSSelectorFromString(@"enableAccessibility")]) {
        @try { SendObject(_axTranslator, @"enableAccessibility"); } @catch (__unused NSException *e) {}
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        _axTranslator, NSSelectorFromString(@"setSupportsDelegateTokens:"), YES);

    _axBridgeDelegate = [[SimulatorAXBridgeDelegate alloc] init];
    _axBridgeDelegate.device = _device;
    ((void (*)(id, SEL, id))objc_msgSend)(
        _axTranslator, NSSelectorFromString(@"setBridgeDelegate:"), _axBridgeDelegate);
    if ([_axTranslator respondsToSelector:NSSelectorFromString(@"setBridgeTokenDelegate:")]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            _axTranslator, NSSelectorFromString(@"setBridgeTokenDelegate:"), _axBridgeDelegate);
    }

    _axSupported = YES;
    return YES;
}

- (BOOL)supportsAccessibility {
    __block BOOL supported = NO;
    dispatch_sync(_axQueue, ^{ supported = [self ensureAccessibilityReadyLocked]; });
    return supported;
}

- (NSDictionary *)accessibilitySnapshotWithError:(NSError **)error {
    __block NSDictionary *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_axQueue, ^{
        if (![self ensureAccessibilityReadyLocked]) {
            failure = [BridgeError(40, @"This Xcode does not expose the accessibility-translation path.") retain];
            return;
        }
        id token = SendObject(_device, @"accessibilityPlatformTranslationToken");
        id root = ((id (*)(id, SEL, int, id))objc_msgSend)(
            _axTranslator,
            NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:"),
            0, token);
        if (root == nil) {
            failure = [BridgeError(41, @"No foreground application is available to snapshot.") retain];
            return;
        }
        NSInteger nodeCount = 0;
        NSDictionary *tree = SimulatorAXBuildNode(_device, root, 0, &nodeCount);
        if (tree == nil) {
            failure = [BridgeError(42, @"The accessibility tree could not be read (automation may be off).") retain];
            return;
        }
        result = [tree retain];
    });
    if (result == nil) {
        if (error != NULL) { *error = [failure autorelease]; }
        else { [failure release]; }
        return nil;
    }
    [failure release];
    return [result autorelease];
}

- (void)dealloc {
    [_coreSimulatorVersion release];
    [_simulatorKitVersion release];
    [_hidClient release];
    [_screenProxy release];
    [_deviceScreen release];
    [_axTranslator release];
    [_axBridgeDelegate release];
    if (_axQueue != NULL) { dispatch_release(_axQueue); }
    [_device release];
    // `_axpHandle` is intentionally not dlclosed: the translator singleton it vends is process-wide
    // and may still be referenced; the helper process is short-lived and exits right after.
    if (_simulatorKitHandle != NULL) { dlclose(_simulatorKitHandle); }
    [super dealloc];
}

@end
