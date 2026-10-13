import Foundation

/// States an app under development declares for its own debug build, so a person or an agent can
/// put a Simulator or Android device into one of them, and step through a sequence of them, from
/// the Simulator workspace.
///
/// The file is project data, read from the session's checkout: it names app identifiers, launch
/// arguments, intent extras and relative links, and nothing in it runs on this Mac. Every
/// dimension that could turn reading it into unbounded work is capped before or while decoding.
/// See `docs/architecture/simulator-scenarios.md`.
enum SimulatorScenarioDefaults {
    static let relativePath = ".threading/scenarios.json"
    static let supportedVersion = 1
    static let maximumFileBytes = 1_024 * 1_024
    static let maximumScenarios = 512
    static let minimumSteps = 2
    static let maximumSteps = 64
    static let maximumDiagnostics = 16
    static let maximumIDBytes = 128
    static let maximumGroupBytes = 64
    static let maximumTitleBytes = 96
    static let maximumVariantBytes = 64
    static let maximumIdentifierBytes = 255
    static let maximumSchemeBytes = 64
    static let maximumLinkBytes = 2_048
    static let maximumLaunchValues = 64
    static let maximumLaunchValueBytes = 4_096
    static let maximumExtraKeyBytes = 128
    static let maximumSchemaReferenceBytes = 2_048
    static let minimumStepInterval: TimeInterval = 0.5
    static let maximumStepInterval: TimeInterval = 30
    static let defaultStepInterval: TimeInterval = 2
    /// Schemes that would open something other than the app: a browser, a file, a call.
    static let refusedSchemes: Set<String> = [
        "http", "https", "file", "ftp", "data", "javascript", "about", "mailto", "tel", "sms", "facetime"
    ]
}

/// The two app vocabularies a scenario can speak. An emulator and a USB phone are both Android.
enum SimulatorScenarioPlatform: String, CaseIterable, Sendable {
    case iOS = "ios"
    case android

    init(_ platform: SimulatorDevicePlatform) {
        self = platform.isAndroid ? .android : .iOS
    }
}

enum SimulatorScenarioAppearance: String, Equatable, Sendable {
    case light
    case dark
}

struct SimulatorScenarioApps: Equatable, Sendable {
    struct IOS: Equatable, Sendable {
        let bundleIdentifier: String
        let urlScheme: String?
    }

    struct Android: Equatable, Sendable {
        let package: String
        let activity: String?
        let urlScheme: String?
    }

    let iOS: IOS?
    let android: Android?

    static let none = SimulatorScenarioApps(iOS: nil, android: nil)

    func urlScheme(for platform: SimulatorScenarioPlatform) -> String? {
        switch platform {
        case .iOS: return iOS?.urlScheme
        case .android: return android?.urlScheme
        }
    }
}

struct SimulatorScenarioStep: Equatable, Sendable {
    let title: String
    /// Relative to the app's scheme: `showcase/live?step=2` opens `myapp://showcase/live?step=2`.
    /// Only the first step may omit it; going back to a step without one starts the app again.
    let link: String?
}

struct SimulatorScenario: Equatable, Sendable {
    let id: String
    let group: String
    let title: String
    let variant: String?
    let appearance: SimulatorScenarioAppearance?
    let iOSArguments: [String]?
    let androidExtras: [SimulatorLaunchExtra]?
    /// Empty for a scenario that is one state; otherwise two or more, the first being the state
    /// the launch opens.
    let steps: [SimulatorScenarioStep]
    let stepInterval: TimeInterval

    var platforms: Set<SimulatorScenarioPlatform> {
        var result: Set<SimulatorScenarioPlatform> = []
        if iOSArguments != nil { result.insert(.iOS) }
        if androidExtras != nil { result.insert(.android) }
        return result
    }

    func supports(_ platform: SimulatorScenarioPlatform) -> Bool { platforms.contains(platform) }

    var hasSteps: Bool { !steps.isEmpty }

    /// The title with its variant, for a band or a result that names one scenario on its own.
    var displayTitle: String {
        guard let variant else { return title }
        return L10n.format("%1$@ (%2$@)", title, variant)
    }
}

struct SimulatorScenarioDiagnostic: Equatable, Sendable {
    enum Code: String, Sendable {
        case unreadable
        case tooLarge
        case malformedJSON
        case invalidSchema
        case unknownField
        case unsupportedVersion
        case invalidApps
        case invalidScenarios
        case tooManyScenarios
        case invalidScenario
        case duplicateID
    }

    let code: Code
    let message: String
}

struct SimulatorScenarioCatalog: Equatable, Sendable {
    let repositoryRoot: URL
    let fileExists: Bool
    let apps: SimulatorScenarioApps
    let scenarios: [SimulatorScenario]
    let diagnostics: [SimulatorScenarioDiagnostic]

    static func empty(repositoryRoot: URL) -> SimulatorScenarioCatalog {
        SimulatorScenarioCatalog(
            repositoryRoot: repositoryRoot, fileExists: false, apps: .none, scenarios: [], diagnostics: []
        )
    }

    var fileURL: URL { repositoryRoot.appendingPathComponent(SimulatorScenarioDefaults.relativePath) }

    func scenario(id: String) -> SimulatorScenario? { scenarios.first { $0.id == id } }

    /// The scenarios at least one of these platforms can open, in file order.
    func scenarios(for platforms: Set<SimulatorScenarioPlatform>) -> [SimulatorScenario] {
        scenarios.filter { !$0.platforms.isDisjoint(with: platforms) }
    }

    /// How a device of that platform starts the scenario, or nil when it cannot.
    func launch(_ scenario: SimulatorScenario, on platform: SimulatorScenarioPlatform) -> SimulatorAppLaunch? {
        switch platform {
        case .iOS:
            guard let app = apps.iOS, let arguments = scenario.iOSArguments else { return nil }
            return .iOS(bundleIdentifier: app.bundleIdentifier, arguments: arguments)
        case .android:
            guard let app = apps.android, let extras = scenario.androidExtras else { return nil }
            return .android(package: app.package, activity: app.activity, extras: extras)
        }
    }

    /// The link that takes a running app to that step, or nil when the step has none (the first
    /// step may be reached only by starting the app again).
    func link(_ scenario: SimulatorScenario, step: Int, on platform: SimulatorScenarioPlatform) -> SimulatorAppLink? {
        guard scenario.steps.indices.contains(step), let relative = scenario.steps[step].link,
              let scheme = apps.urlScheme(for: platform),
              let url = URL(string: "\(scheme)://\(relative)") else { return nil }
        switch platform {
        case .iOS:
            guard let app = apps.iOS else { return nil }
            return .iOS(bundleIdentifier: app.bundleIdentifier, url: url)
        case .android:
            guard let app = apps.android else { return nil }
            return .android(package: app.package, activity: app.activity, url: url)
        }
    }
}

// MARK: - Loading

enum SimulatorScenarioLoader {
    private static let rootFields: Set<String> = ["$schema", "version", "apps", "scenarios"]
    private static let iOSAppFields: Set<String> = ["bundleIdentifier", "urlScheme"]
    private static let androidAppFields: Set<String> = ["package", "activity", "urlScheme"]
    private static let scenarioFields: Set<String> = [
        "id", "group", "title", "variant", "appearance", "launch", "steps", "stepInterval"
    ]
    private static let launchFields: Set<String> = ["ios", "android"]
    private static let stepFields: Set<String> = ["title", "link"]

    /// The checkout a session works in, raised to its repository root so a session in a
    /// subdirectory reads the same file. Touches the filesystem: call it off the main actor.
    static func repositoryRoot(forWorkingDirectory directory: URL) -> URL {
        let standardized = directory.standardizedFileURL.resolvingSymlinksInPath()
        return GitInfo.worktreeLocation(for: standardized.path)?.root ?? standardized
    }

    /// Reads `.threading/scenarios.json` under the root. A missing file is an empty catalogue; a
    /// broken one is a catalogue of diagnostics, and each valid scenario beside a broken one is
    /// still offered. Off the main actor.
    static func load(repositoryRoot rawRoot: URL) -> SimulatorScenarioCatalog {
        let root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(SimulatorScenarioDefaults.relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty(repositoryRoot: root) }
        do {
            // The folder is the repository's to name, so it must not lead out of the checkout.
            let resolved = file.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root.path + "/") else {
                return failure(root, .unreadable, Strings.regularFile)
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return failure(root, .unreadable, Strings.regularFile)
            }
            guard let size = values.fileSize, size <= SimulatorScenarioDefaults.maximumFileBytes else {
                return failure(root, .tooLarge, Strings.tooLarge)
            }
            let data = try BoundedFileReader.read(file, maximumBytes: SimulatorScenarioDefaults.maximumFileBytes)
            return decode(data, repositoryRoot: root)
        } catch is BoundedFileReadError {
            return failure(root, .tooLarge, Strings.tooLarge)
        } catch {
            return failure(root, .unreadable, Strings.couldNotRead(bounded(error.localizedDescription)))
        }
    }

    static func decode(_ data: Data, repositoryRoot: URL) -> SimulatorScenarioCatalog {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return failure(repositoryRoot, .malformedJSON, Strings.invalidJSON(bounded(error.localizedDescription)))
        }
        guard let root = object as? [String: Any] else {
            return failure(repositoryRoot, .malformedJSON, Strings.objectRequired)
        }
        if let unknown = Set(root.keys).subtracting(rootFields).sorted().first {
            return failure(repositoryRoot, .unknownField, Strings.unknownRootField(unknown))
        }
        if let schema = root["$schema"] {
            guard let text = schema as? String,
                  isBoundedText(text, maximumBytes: SimulatorScenarioDefaults.maximumSchemaReferenceBytes) else {
                return failure(repositoryRoot, .invalidSchema, Strings.invalidSchemaReference)
            }
        }
        guard integer(root["version"]) == SimulatorScenarioDefaults.supportedVersion else {
            return failure(
                repositoryRoot, .unsupportedVersion, Strings.unsupportedVersion(SimulatorScenarioDefaults.supportedVersion)
            )
        }
        guard let apps = decodeApps(root["apps"]) else {
            return failure(repositoryRoot, .invalidApps, Strings.invalidApps)
        }
        guard let rawScenarios = root["scenarios"] as? [Any] else {
            return failure(repositoryRoot, .invalidScenarios, Strings.scenariosArrayRequired)
        }
        guard rawScenarios.count <= SimulatorScenarioDefaults.maximumScenarios else {
            return failure(repositoryRoot, .tooManyScenarios, Strings.tooManyScenarios(
                rawScenarios.count, maximum: SimulatorScenarioDefaults.maximumScenarios
            ))
        }

        var scenarios: [SimulatorScenario] = []
        var diagnostics: [SimulatorScenarioDiagnostic] = []
        var identifiers: Set<String> = []
        for (index, raw) in rawScenarios.enumerated() {
            switch decodeScenario(raw, position: index + 1, apps: apps) {
            case .success(let scenario):
                guard identifiers.insert(scenario.id).inserted else {
                    append(&diagnostics, .duplicateID, Strings.duplicateID(index + 1, id: scenario.id))
                    continue
                }
                scenarios.append(scenario)
            case .failure(let message):
                append(&diagnostics, .invalidScenario, message)
            }
        }
        return SimulatorScenarioCatalog(
            repositoryRoot: repositoryRoot, fileExists: true, apps: apps, scenarios: scenarios, diagnostics: diagnostics
        )
    }

    // MARK: - Apps

    private static func decodeApps(_ value: Any?) -> SimulatorScenarioApps? {
        guard let object = value as? [String: Any], !object.isEmpty,
              Set(object.keys).isSubset(of: launchFields) else { return nil }
        var iOS: SimulatorScenarioApps.IOS?
        if let raw = object["ios"] {
            guard let app = raw as? [String: Any], Set(app.keys).isSubset(of: iOSAppFields),
                  let bundle = app["bundleIdentifier"] as? String, isIdentifier(bundle),
                  app["urlScheme"] == nil || (app["urlScheme"] as? String).map(isCustomScheme) == true else {
                return nil
            }
            iOS = SimulatorScenarioApps.IOS(bundleIdentifier: bundle, urlScheme: app["urlScheme"] as? String)
        }
        var android: SimulatorScenarioApps.Android?
        if let raw = object["android"] {
            guard let app = raw as? [String: Any], Set(app.keys).isSubset(of: androidAppFields),
                  let package = app["package"] as? String,
                  (try? AndroidDeviceControl.validatedPackageName(package)) == package,
                  app["urlScheme"] == nil || (app["urlScheme"] as? String).map(isCustomScheme) == true,
                  app["activity"] == nil || (app["activity"] as? String).flatMap({
                      try? AndroidDeviceControl.component(package: package, activity: $0)
                  }) != nil else {
                return nil
            }
            android = SimulatorScenarioApps.Android(
                package: package, activity: app["activity"] as? String, urlScheme: app["urlScheme"] as? String
            )
        }
        return SimulatorScenarioApps(iOS: iOS, android: android)
    }

    // MARK: - Scenarios

    private enum ScenarioResult {
        case success(SimulatorScenario)
        case failure(String)
    }

    private static func decodeScenario(_ value: Any, position: Int, apps: SimulatorScenarioApps) -> ScenarioResult {
        guard let object = value as? [String: Any] else { return .failure(Strings.scenarioObjectRequired(position)) }
        if let unknown = Set(object.keys).subtracting(scenarioFields).sorted().first {
            return .failure(Strings.unknownScenarioField(position, field: unknown))
        }
        guard let id = object["id"] as? String, isValidID(id) else { return .failure(Strings.invalidID(position)) }
        guard let group = object["group"] as? String,
              isBoundedText(group, maximumBytes: SimulatorScenarioDefaults.maximumGroupBytes),
              let title = object["title"] as? String,
              isBoundedText(title, maximumBytes: SimulatorScenarioDefaults.maximumTitleBytes) else {
            return .failure(Strings.invalidText(position))
        }
        var variant: String?
        if let raw = object["variant"] {
            guard let value = raw as? String,
                  isBoundedText(value, maximumBytes: SimulatorScenarioDefaults.maximumVariantBytes) else {
                return .failure(Strings.invalidText(position))
            }
            variant = value
        }
        var appearance: SimulatorScenarioAppearance?
        if let raw = object["appearance"] {
            guard let value = (raw as? String).flatMap(SimulatorScenarioAppearance.init(rawValue:)) else {
                return .failure(Strings.invalidAppearance(position))
            }
            appearance = value
        }

        guard let launch = object["launch"] as? [String: Any], !launch.isEmpty,
              Set(launch.keys).isSubset(of: launchFields),
              launch["ios"] == nil || apps.iOS != nil,
              launch["android"] == nil || apps.android != nil else {
            return .failure(Strings.invalidLaunch(position))
        }
        var iOSArguments: [String]?
        if let raw = launch["ios"] {
            guard let arguments = raw as? [String], arguments.count <= SimulatorScenarioDefaults.maximumLaunchValues,
                  arguments.allSatisfy(isLaunchValue) else {
                return .failure(Strings.invalidIOSLaunch(position))
            }
            iOSArguments = arguments
        }
        var androidExtras: [SimulatorLaunchExtra]?
        if let raw = launch["android"] {
            guard let extras = decodeExtras(raw) else { return .failure(Strings.invalidAndroidLaunch(position)) }
            androidExtras = extras
        }

        var steps: [SimulatorScenarioStep] = []
        if let raw = object["steps"] {
            guard let decoded = decodeSteps(raw) else { return .failure(Strings.invalidSteps(position)) }
            steps = decoded
            let platforms = [iOSArguments != nil ? SimulatorScenarioPlatform.iOS : nil,
                             androidExtras != nil ? SimulatorScenarioPlatform.android : nil].compactMap { $0 }
            if steps.contains(where: { $0.link != nil }),
               let missing = platforms.first(where: { apps.urlScheme(for: $0) == nil }) {
                return .failure(Strings.missingScheme(position, platform: missing.rawValue))
            }
        }
        var stepInterval = SimulatorScenarioDefaults.defaultStepInterval
        if let raw = object["stepInterval"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (SimulatorScenarioDefaults.minimumStepInterval...SimulatorScenarioDefaults.maximumStepInterval)
                    .contains(number.doubleValue) else {
                return .failure(Strings.invalidStepInterval(position))
            }
            stepInterval = number.doubleValue
        }
        return .success(SimulatorScenario(
            id: id, group: group, title: title, variant: variant, appearance: appearance,
            iOSArguments: iOSArguments, androidExtras: androidExtras, steps: steps, stepInterval: stepInterval
        ))
    }

    /// Sorted by name: a JSON object carries no order, and a stable one keeps the `am start`
    /// command for a scenario the same on every run.
    private static func decodeExtras(_ value: Any) -> [SimulatorLaunchExtra]? {
        guard let object = value as? [String: Any],
              object.count <= SimulatorScenarioDefaults.maximumLaunchValues else { return nil }
        var extras: [SimulatorLaunchExtra] = []
        for key in object.keys.sorted() {
            guard isExtraKey(key) else { return nil }
            switch object[key] {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                extras.append(SimulatorLaunchExtra(key: key, value: .boolean(number.boolValue)))
            case let number as NSNumber:
                guard let whole = integer(number) else { return nil }
                extras.append(SimulatorLaunchExtra(key: key, value: .integer(Int64(whole))))
            case let text as String:
                guard isLaunchValue(text) else { return nil }
                extras.append(SimulatorLaunchExtra(key: key, value: .string(text)))
            default:
                return nil
            }
        }
        return extras
    }

    private static func decodeSteps(_ value: Any) -> [SimulatorScenarioStep]? {
        guard let raw = value as? [Any],
              (SimulatorScenarioDefaults.minimumSteps...SimulatorScenarioDefaults.maximumSteps).contains(raw.count) else {
            return nil
        }
        var steps: [SimulatorScenarioStep] = []
        for (index, item) in raw.enumerated() {
            guard let object = item as? [String: Any], Set(object.keys).isSubset(of: stepFields),
                  let title = object["title"] as? String,
                  isBoundedText(title, maximumBytes: SimulatorScenarioDefaults.maximumTitleBytes) else { return nil }
            var link: String?
            if let rawLink = object["link"] {
                guard let value = rawLink as? String, isRelativeLink(value) else { return nil }
                link = value
            }
            guard index == 0 || link != nil else { return nil }
            steps.append(SimulatorScenarioStep(title: title, link: link))
        }
        return steps
    }

    // MARK: - Validation

    private static func append(
        _ diagnostics: inout [SimulatorScenarioDiagnostic], _ code: SimulatorScenarioDiagnostic.Code, _ message: String
    ) {
        guard diagnostics.count < SimulatorScenarioDefaults.maximumDiagnostics else { return }
        diagnostics.append(SimulatorScenarioDiagnostic(code: code, message: message))
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) <= Double(Int64.max / 2) else { return nil }
        return number.intValue
    }

    private static func isValidID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= SimulatorScenarioDefaults.maximumIDBytes,
              let first = value.unicodeScalars.first, lowercaseAlphanumeric.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
    }

    /// A bundle identifier: reverse-DNS ASCII.
    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= SimulatorScenarioDefaults.maximumIdentifierBytes
            && value.unicodeScalars.allSatisfy { bundleCharacters.contains($0) }
            && !value.hasPrefix(".") && !value.hasSuffix(".")
    }

    /// RFC 3986 scheme syntax, and not one that leaves the app.
    private static func isCustomScheme(_ value: String) -> Bool {
        guard value.utf8.count <= SimulatorScenarioDefaults.maximumSchemeBytes,
              let first = value.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
              first.isASCII,
              value.unicodeScalars.allSatisfy({ schemeCharacters.contains($0) }) else { return false }
        return !SimulatorScenarioDefaults.refusedSchemes.contains(value)
    }

    private static func isRelativeLink(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= SimulatorScenarioDefaults.maximumLinkBytes
            && !value.contains("://")
            && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
            && URL(string: "threading://\(value)") != nil
    }

    private static func isLaunchValue(_ value: String) -> Bool {
        value.utf8.count <= SimulatorScenarioDefaults.maximumLaunchValueBytes && !value.contains("\0")
    }

    private static func isExtraKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= SimulatorScenarioDefaults.maximumExtraKeyBytes
            && value.unicodeScalars.allSatisfy { extraKeyCharacters.contains($0) }
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func failure(
        _ root: URL, _ code: SimulatorScenarioDiagnostic.Code, _ message: String
    ) -> SimulatorScenarioCatalog {
        SimulatorScenarioCatalog(
            repositoryRoot: root, fileExists: true, apps: .none, scenarios: [],
            diagnostics: [SimulatorScenarioDiagnostic(code: code, message: message)]
        )
    }

    private static func bounded(_ value: String) -> String { String(value.prefix(240)) }

    private static let lowercaseAlphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._/-")
    private static let bundleCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )
    private static let schemeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-")
    private static let extraKeyCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    private enum Strings {
        static let regularFile = L10n.string(
            "The scenario file must be a regular file inside the checkout, not a symbolic link."
        )
        static let tooLarge = L10n.string("The scenario file exceeds the 1 MiB limit.")
        static let objectRequired = L10n.string("The scenario file must be a JSON object.")
        static let invalidSchemaReference = L10n.string(
            "The $schema field must be a non-empty string of at most 2048 bytes without control characters."
        )
        static let invalidApps = L10n.string(
            "The apps field must declare an ios app with a bundleIdentifier, an android app with a package, or both. A urlScheme must be the app's own scheme, such as myapp."
        )
        static let scenariosArrayRequired = L10n.string("The scenarios field must be an array.")

        static func couldNotRead(_ detail: String) -> String {
            L10n.format("The scenario file could not be read: %@.", detail)
        }

        static func invalidJSON(_ detail: String) -> String {
            L10n.format("The scenario file is not valid JSON: %@.", detail)
        }

        static func unknownRootField(_ field: String) -> String {
            L10n.format("Unknown scenario file field: %@.", field)
        }

        static func unsupportedVersion(_ version: Int) -> String {
            L10n.format("Scenario file version must be %lld.", Int64(version))
        }

        static func tooManyScenarios(_ count: Int, maximum: Int) -> String {
            L10n.format("The file declares %lld scenarios; at most %lld are allowed.", Int64(count), Int64(maximum))
        }

        static func duplicateID(_ position: Int, id: String) -> String {
            L10n.format("Scenario %lld repeats the ID “%@”.", Int64(position), id)
        }

        static func scenarioObjectRequired(_ position: Int) -> String {
            L10n.format("Scenario %lld must be a JSON object.", Int64(position))
        }

        static func unknownScenarioField(_ position: Int, field: String) -> String {
            L10n.format("Scenario %lld has an unknown field: %@.", Int64(position), field)
        }

        static func invalidID(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld needs an ID of 1–128 bytes using lowercase letters, numbers, dots, slashes, underscores, or hyphens.",
                Int64(position)
            )
        }

        static func invalidText(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld needs a group and a title, and its group, title and variant must be short text without control characters.",
                Int64(position)
            )
        }

        static func invalidAppearance(_ position: Int) -> String {
            L10n.format("Scenario %lld has an appearance other than light or dark.", Int64(position))
        }

        static func invalidLaunch(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld needs a launch for ios, android, or both, each for an app declared in apps.",
                Int64(position)
            )
        }

        static func invalidIOSLaunch(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld: launch.ios must be at most 64 launch arguments of at most 4096 bytes.", Int64(position)
            )
        }

        static func invalidAndroidLaunch(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld: launch.android must be at most 64 extras named with letters, numbers, dots, underscores, or hyphens, each text, true or false, or a whole number.",
                Int64(position)
            )
        }

        static func invalidSteps(_ position: Int) -> String {
            L10n.format(
                "Scenario %lld needs 2–64 steps, each with a title. Every step after the first needs a link relative to the app's scheme, without spaces.",
                Int64(position)
            )
        }

        static func missingScheme(_ position: Int, platform: String) -> String {
            L10n.format(
                "Scenario %lld has step links, so apps.%@ needs a urlScheme.", Int64(position), platform
            )
        }

        static func invalidStepInterval(_ position: Int) -> String {
            L10n.format("Scenario %lld: stepInterval must be between 0.5 and 30 seconds.", Int64(position))
        }
    }
}
