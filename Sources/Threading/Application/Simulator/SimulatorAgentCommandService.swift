import Foundation

/// Owns validation and stable response payloads for Simulator MCP commands.
///
/// The coordinator remains a thin adapter over the session's visible pane. This service has no
/// window authority and cannot create a second device lease or launch Simulator.app.
enum SimulatorAgentCommandService {
    private static let validTextPunctuation = Set("-_=+[]{}\\|;:'\"`~,<>./?!@#$%^&*()")

    enum Input: Sendable {
        case tap(x: Double, y: Double)
        case swipe(
            fromX: Double,
            fromY: Double,
            toX: Double,
            toY: Double,
            durationMilliseconds: Int
        )
        case text(String)
        case button(Button)
    }

    enum Button: String, Sendable, CaseIterable {
        case home
        case lock
        case side
        case volumeUp
        case volumeDown
        // Android. `power` is Android's name for the button iOS calls lock.
        case back
        case overview
        case power
        case rotateLeft
        case rotateRight

        static let iOS: [Button] = [.home, .lock, .side, .volumeUp, .volumeDown]
        static let androidDevice: [Button] = [.back, .home, .overview, .power, .volumeUp, .volumeDown]
        static let androidEmulator: [Button] = androidDevice + [.rotateLeft, .rotateRight]

        static func available(on platform: SimulatorDevicePlatform) -> [Button] {
            switch platform {
            case .iOSSimulator: return iOS
            case .androidEmulator: return androidEmulator
            case .androidDevice: return androidDevice
            }
        }
    }

    struct LaunchRequest {
        let applicationURL: URL
        let bundleIdentifier: String
        let arguments: [String]
    }

    enum Request<Value> {
        case accepted(Value)
        case rejected(MCPToolResult)
    }

    /// A resolved target for a tap or type: an `eN` ref, or a semantic locator (a label/identifier to
    /// match, optionally narrowed by role). Plain strings only — resolving it to an element needs the
    /// accessibility tree and so happens in the UI layer, which may import the Simulator wire types.
    struct ElementLocator: Sendable, Equatable {
        let ref: String?
        let role: String?
        let label: String?
        let identifier: String?

        var isEmpty: Bool {
            (ref?.isEmpty ?? true) && (role?.isEmpty ?? true)
                && (label?.isEmpty ?? true) && (identifier?.isEmpty ?? true)
        }
    }

    /// How a tap was addressed. Coordinate mode is validated here; locator mode is resolved against a
    /// fresh snapshot in the UI layer immediately before acting.
    enum TapAddressing {
        case coordinate(x: Double, y: Double)
        case locator(ElementLocator)
        case rejected(MCPToolResult)
    }

    enum TypeAddressing {
        /// Type into whatever the device currently has focused.
        case focused(text: String)
        /// Focus the located element (a tap) before typing.
        case located(ElementLocator, text: String)
        case rejected(MCPToolResult)
    }

    /// A locator to crop a screenshot to, or nil for the whole framebuffer.
    static func screenshotLocator(from arguments: SimulatorScreenshotArguments) -> ElementLocator? {
        let hasTarget = !(arguments.ref?.isEmpty ?? true)
            || !(arguments.label?.isEmpty ?? true)
            || !(arguments.identifier?.isEmpty ?? true)
        guard hasTarget else { return nil }
        return ElementLocator(
            ref: arguments.ref,
            role: arguments.role,
            label: arguments.label,
            identifier: arguments.identifier
        )
    }

    enum WaitCondition: Sendable { case appears, disappears }

    struct WaitRequest: Sendable {
        let locator: ElementLocator
        let condition: WaitCondition
        let timeoutMilliseconds: Int
    }

    static func waitRequest(from arguments: SimulatorWaitArguments) -> Request<WaitRequest> {
        let hasSemantic = !(arguments.label?.isEmpty ?? true)
            || !(arguments.identifier?.isEmpty ?? true)
        guard hasSemantic else {
            return .rejected(.failure(
                "Provide a label and/or identifier to wait for, optionally narrowed by role."
            ))
        }
        let condition: WaitCondition
        switch (arguments.until ?? "appears").lowercased() {
        case "appears": condition = .appears
        case "disappears": condition = .disappears
        default:
            return .rejected(.failure("until must be \"appears\" or \"disappears\"."))
        }
        let timeout = arguments.timeoutMilliseconds ?? 5_000
        guard (100...30_000).contains(timeout) else {
            return .rejected(.failure("timeout_ms must be between 100 and 30000."))
        }
        return .accepted(WaitRequest(
            locator: ElementLocator(
                ref: nil,
                role: arguments.role,
                label: arguments.label,
                identifier: arguments.identifier
            ),
            condition: condition,
            timeoutMilliseconds: timeout
        ))
    }

    static func tapAddressing(from arguments: SimulatorTapArguments) -> TapAddressing {
        let hasCoordinate = arguments.x != nil || arguments.y != nil
        let hasRef = !(arguments.ref?.isEmpty ?? true)
        let hasSemantic = !(arguments.label?.isEmpty ?? true)
            || !(arguments.identifier?.isEmpty ?? true)
        let modes = [hasCoordinate, hasRef, hasSemantic].filter { $0 }.count
        guard modes == 1 else {
            return .rejected(.failure(
                "Provide exactly one target: (x, y), or ref, or a semantic locator "
                    + "(label and/or identifier, optionally with role)."
            ))
        }
        if hasCoordinate {
            guard let x = arguments.x, let y = arguments.y else {
                return .rejected(.failure("A coordinate tap needs both x and y."))
            }
            guard validCoordinate(x), validCoordinate(y) else {
                return .rejected(.failure("Simulator coordinates must be finite values from 0 to 1."))
            }
            return .coordinate(x: x, y: y)
        }
        if let refFailure = invalidRefFailure(arguments.ref) { return .rejected(refFailure) }
        return .locator(ElementLocator(
            ref: arguments.ref,
            role: arguments.role,
            label: arguments.label,
            identifier: arguments.identifier
        ))
    }

    static func typeAddressing(from arguments: SimulatorTypeTextArguments) -> TypeAddressing {
        guard let text = arguments.text, !text.isEmpty else {
            return .rejected(.failure("Missing required argument: text"))
        }
        guard text.count <= 1_024 else {
            return .rejected(.failure("Simulator text is limited to 1,024 characters per call."))
        }
        guard text.allSatisfy(validTextCharacter) else {
            return .rejected(.failure(
                "Direct Simulator typing supports printable US-keyboard text, tab, newline, and backspace."
            ))
        }
        let hasRef = !(arguments.ref?.isEmpty ?? true)
        let hasSemantic = !(arguments.label?.isEmpty ?? true)
            || !(arguments.identifier?.isEmpty ?? true)
        if hasRef, hasSemantic {
            return .rejected(.failure("Provide either ref or a semantic locator to focus, not both."))
        }
        guard hasRef || hasSemantic else { return .focused(text: text) }
        if let refFailure = invalidRefFailure(arguments.ref) { return .rejected(refFailure) }
        return .located(
            ElementLocator(
                ref: arguments.ref,
                role: arguments.role,
                label: arguments.label,
                identifier: arguments.identifier
            ),
            text: text
        )
    }

    /// A ref is `e` followed by a positive integer, as `simulator_snapshot` emits.
    private static func invalidRefFailure(_ ref: String?) -> MCPToolResult? {
        guard let ref, !ref.isEmpty else { return nil }
        let digits = ref.dropFirst()
        guard ref.hasPrefix("e"), !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            return .failure("ref must look like \"e12\", from a recent simulator_snapshot.")
        }
        return nil
    }

    static func requestedDeviceID(
        from arguments: SimulatorPrepareArguments
    ) -> Request<SimulatorDeviceID?> {
        guard let rawValue = arguments.deviceID else { return .accepted(nil) }
        guard let parsed = SimulatorDeviceID(rawValue) else {
            return .rejected(.failure(deviceIDFormatFailure))
        }
        return .accepted(parsed)
    }

    static let deviceIDFormatFailure = "device_id must be an exact device id from simulator_prepare or "
        + "panel_list_tabs: a CoreSimulator UUID, android-avd:<AVD name> or android-usb:<adb serial>."

    /// Whether an automatic choice should come from Android: nil when the agent did not say.
    static func requestedPlatform(from arguments: SimulatorPrepareArguments) -> Request<Bool?> {
        guard let raw = arguments.platform?.lowercased(), !raw.isEmpty else { return .accepted(nil) }
        switch raw {
        case "ios": return .accepted(false)
        case "android": return .accepted(true)
        default: return .rejected(.failure("platform must be \"ios\" or \"android\"."))
        }
    }

    /// The workspace arrangement an agent asked for, by the layout chooser's own names.
    static func requestedLayout(from arguments: SimulatorPrepareArguments) -> Request<SimulatorWorkspaceLayout?> {
        guard let raw = arguments.layout?.lowercased(), !raw.isEmpty else { return .accepted(nil) }
        guard let layout = SimulatorWorkspaceLayout(rawValue: raw) else {
            let names = SimulatorWorkspaceLayout.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return .rejected(.failure("layout must be one of \(names)."))
        }
        return .accepted(layout)
    }

    /// What `simulator_prepare` does once its arguments are read.
    enum PreparationRoute: Equatable {
        /// Prepare this exact device (adding it when it is not a member), or with nil the
        /// workspace's lone member by its automatic choice.
        case prepare(SimulatorDeviceID?)
        /// Add the platform's automatic choice as a new member beside the others.
        case addBeside
    }

    /// The parts of the current workspace the route depends on; nil when there is no tab yet.
    struct WorkspaceShape: Equatable {
        let memberCount: Int
        /// One member that holds no device yet, which simply chooses on the requested platform.
        let isLoneAndEmpty: Bool
        /// The device of the first member on the requested platform.
        let deviceOnPlatform: SimulatorDeviceID?
    }

    struct PreparationRequest: Equatable {
        let deviceID: SimulatorDeviceID?
        let preferAndroid: Bool?
        let layout: SimulatorWorkspaceLayout?
        let beside: Bool
    }

    static func preparationRequest(from arguments: SimulatorPrepareArguments) -> Request<PreparationRequest> {
        let deviceID: SimulatorDeviceID?
        switch requestedDeviceID(from: arguments) {
        case .accepted(let value): deviceID = value
        case .rejected(let result): return .rejected(result)
        }
        let preferAndroid: Bool?
        switch requestedPlatform(from: arguments) {
        case .accepted(let value): preferAndroid = value
        case .rejected(let result): return .rejected(result)
        }
        switch requestedLayout(from: arguments) {
        case .accepted(let layout):
            return .accepted(PreparationRequest(deviceID: deviceID, preferAndroid: preferAndroid,
                                                layout: layout, beside: arguments.beside == true))
        case .rejected(let result): return .rejected(result)
        }
    }

    /// Without a device_id the platform decides: in a workspace of several devices, its member of
    /// that platform, or a new member beside the others when it has none. beside always adds,
    /// except to a lone member that holds nothing yet. A lone member asked for the other platform
    /// without beside switches to it, as it always has.
    static func preparationRoute(
        for request: PreparationRequest, in workspace: WorkspaceShape?
    ) -> Request<PreparationRoute> {
        guard request.deviceID == nil, let workspace else { return .accepted(.prepare(request.deviceID)) }
        if request.beside { return .accepted(workspace.isLoneAndEmpty ? .prepare(nil) : .addBeside) }
        guard workspace.memberCount > 1 else { return .accepted(.prepare(nil)) }
        guard request.preferAndroid != nil else {
            return .rejected(.failure("Provide device_id or platform when the workspace contains multiple devices."))
        }
        return .accepted(workspace.deviceOnPlatform.map { .prepare($0) } ?? .addBeside)
    }

    /// One workspace member as an agent sees it: enough to address it and to know what it is.
    struct WorkspaceMember: Encodable, Equatable {
        let deviceID: String?
        let platform: String?
        let name: String?
        let selected: Bool

        init(deviceID: SimulatorDeviceID?, name: String?, selected: Bool) {
            self.deviceID = deviceID?.rawValue
            self.platform = deviceID.map { $0.platform.isAndroid ? "android" : "ios" }
            self.name = name
            self.selected = selected
        }

        private enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case platform, name, selected
        }
    }

    struct WorkspaceSummary: Encodable, Equatable {
        let layout: String
        let devices: [WorkspaceMember]
    }

    static func launchRequest(
        from arguments: SimulatorInstallLaunchArguments,
        platform: SimulatorDevicePlatform = .iOSSimulator,
        resolve: (String) -> URL?
    ) -> Request<LaunchRequest> {
        guard let path = arguments.applicationPath, !path.isEmpty else {
            return .rejected(.failure("Missing required argument: application_path"))
        }
        guard let bundleIdentifier = arguments.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .rejected(.failure("Missing required argument: bundle_identifier"))
        }
        guard let applicationURL = resolve(path) else {
            return .rejected(.failure("No such application: \(path)"))
        }
        let isAndroid = platform.isAndroid
        guard applicationURL.pathExtension.caseInsensitiveCompare(isAndroid ? "apk" : "app") == .orderedSame else {
            return .rejected(.failure(isAndroid
                ? "application_path must name a built .apk for an Android device."
                : "application_path must name a built .app bundle."))
        }
        return .accepted(LaunchRequest(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            arguments: arguments.arguments ?? []
        ))
    }

    static func preparationResult(
        for lease: SimulatorDeviceLease, adbSerial: String? = nil, workspace: WorkspaceSummary? = nil
    ) -> MCPToolResult {
        let device = lease.device
        let android = device.platform.isAndroid
        return encoded(PreparationPayload(
            deviceID: device.id.rawValue,
            platform: android ? "android" : "ios",
            name: device.name,
            runtime: device.runtimeName,
            family: device.family.rawValue,
            bootOwnership: lease.bootOwnership.rawValue,
            surface: "Threading right panel",
            xcodebuildDestination: android ? nil : "platform=iOS Simulator,id=\(device.id.rawValue)",
            adbSerial: android ? adbSerial : nil,
            buildHint: android
                ? "Build with Gradle in your shell (for example ./gradlew assembleDebug"
                    + (adbSerial.map { " with ANDROID_SERIAL=\($0)" } ?? "")
                    + "), then call simulator_install_launch with the .apk and its applicationId."
                : nil,
            buttons: Button.available(on: device.platform).map(\.rawValue),
            workspace: workspace
        ))
    }

    static func launchResult(for receipt: SimulatorLaunchReceipt) -> MCPToolResult {
        encoded(LaunchPayload(
            deviceID: receipt.deviceID.rawValue,
            bundleIdentifier: receipt.bundleIdentifier,
            processIdentifier: receipt.processIdentifier,
            surface: "Threading right panel"
        ))
    }

    static func screenshotResult(
        data: Data,
        device: SimulatorDevice,
        includeImage: Bool
    ) -> MCPToolResult {
        .screenshot(
            "Captured \(device.name) (\(device.id.rawValue)) "
                + "from Threading's right-panel Simulator.",
            pngData: data,
            includeImage: includeImage
        )
    }

    static func swipeInput(
        from arguments: SimulatorSwipeArguments
    ) -> Request<Input> {
        guard let fromX = arguments.fromX,
              let fromY = arguments.fromY,
              let toX = arguments.toX,
              let toY = arguments.toY else {
            return .rejected(.failure(
                "Missing required arguments: from_x, from_y, to_x, and to_y"
            ))
        }
        guard [fromX, fromY, toX, toY].allSatisfy(validCoordinate) else {
            return .rejected(.failure("Simulator coordinates must be finite values from 0 to 1."))
        }
        let duration = arguments.durationMilliseconds ?? 300
        guard (100...2_000).contains(duration) else {
            return .rejected(.failure("duration_ms must be between 100 and 2000."))
        }
        return .accepted(.swipe(
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            durationMilliseconds: duration
        ))
    }

    static func buttonInput(
        from arguments: SimulatorPressButtonArguments,
        platform: SimulatorDevicePlatform = .iOSSimulator
    ) -> Request<Input> {
        guard let rawValue = arguments.button, !rawValue.isEmpty else {
            return .rejected(.failure("Missing required argument: button"))
        }
        let available = Button.available(on: platform)
        guard let button = Button(rawValue: rawValue), available.contains(button) else {
            let valid = available.map(\.rawValue).joined(separator: ", ")
            return .rejected(.failure("button must be one of: \(valid)."))
        }
        return .accepted(.button(button))
    }

    static func inputResult(action: String, device: SimulatorDevice) -> MCPToolResult {
        encoded(InputPayload(
            deviceID: device.id.rawValue,
            action: action,
            surface: "Threading right panel"
        ))
    }

    private static func validCoordinate(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    /// Mirrors the helper protocol's bounded US-keyboard vocabulary without importing the
    /// transport package across the Application compiler-layer boundary.
    private static func validTextCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 8, 9, 10, 32, 48...57, 65...90, 97...122:
            return true
        default:
            return validTextPunctuation.contains(character)
        }
    }

    private static func encoded<Value: Encodable>(_ value: Value) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not encode the Simulator result.")
        }
        return .success(text)
    }
}

private struct PreparationPayload: Encodable {
    let deviceID: String
    let platform: String
    let name: String
    let runtime: String
    let family: String
    let bootOwnership: String
    let surface: String
    let xcodebuildDestination: String?
    let adbSerial: String?
    let buildHint: String?
    let buttons: [String]
    /// Every member beside this one, so an agent that built a side-by-side view can see it.
    let workspace: SimulatorAgentCommandService.WorkspaceSummary?

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case platform, name, runtime, family
        case bootOwnership = "boot_ownership"
        case surface
        case xcodebuildDestination = "xcodebuild_destination"
        case adbSerial = "adb_serial"
        case buildHint = "build_hint"
        case buttons, workspace
    }
}

private struct LaunchPayload: Encodable {
    let deviceID: String
    let bundleIdentifier: String
    let processIdentifier: Int32?
    let surface: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case bundleIdentifier = "bundle_identifier"
        case processIdentifier = "process_identifier"
        case surface
    }
}

private struct InputPayload: Encodable {
    let deviceID: String
    let action: String
    let surface: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case action, surface
    }
}
