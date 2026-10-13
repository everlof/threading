import Foundation

/// Starting an app that is already installed on an adopted device, in the state its developer
/// named. Each platform has its own vocabulary: an iOS app reads launch arguments, an Android
/// activity reads intent extras. One case per platform, so a request cannot mix the two.
enum SimulatorAppLaunch: Equatable, Sendable {
    case iOS(bundleIdentifier: String, arguments: [String])
    /// `activity` is relative to the package (`.ShowcaseActivity`) or fully qualified; nil starts
    /// the package's launcher activity.
    case android(package: String, activity: String?, extras: [SimulatorLaunchExtra])
}

/// One Android intent extra, typed the way `am start` delivers it.
struct SimulatorLaunchExtra: Equatable, Sendable {
    enum Value: Equatable, Sendable {
        case string(String)
        case boolean(Bool)
        case integer(Int64)
    }

    let key: String
    let value: Value
}

/// A link handed to an app that is already running, so it can change state in place instead of
/// starting again. iOS has no prompt-free way to open a custom scheme from outside the device, so
/// the iOS case travels through Threading's link drop (`SimulatorAppLinkDrop`).
enum SimulatorAppLink: Equatable, Sendable {
    case iOS(bundleIdentifier: String, url: URL)
    case android(package: String, activity: String?, url: URL)

    var url: URL {
        switch self {
        case .iOS(_, let url), .android(_, _, let url): return url
        }
    }
}

/// How an iOS app running in a Simulator receives a link from Threading.
///
/// `simctl openurl` is the obvious route and the wrong one: for a custom scheme iOS asks
/// “Open in “App”?” on every call (measured on iOS 26 with Xcode 26.5), so a person stepping
/// through states would answer a system alert per step and never see the transition. Instead
/// Threading writes the URL into the app's own temporary directory and rings a Darwin
/// notification inside the device; the app reads the file and handles the URL as it would any
/// link. The app opts in with a few lines in its debug build (`docs/architecture/simulator-scenarios.md`).
enum SimulatorAppLinkDrop {
    /// The Darwin notification posted inside the Simulator after the file is written.
    static let notificationName = "codes.threading.scenario.link"
    /// The file, in the app's `NSTemporaryDirectory()`.
    static let fileName = "codes.threading.scenario-link"
    /// The part of an app data container's path that names it as one: Threading only writes into
    /// a directory CoreSimulator reported for that exact device.
    static func containerMarker(for deviceID: SimulatorDeviceID) -> String {
        "/Devices/\(deviceID.rawValue)/data/Containers/Data/Application/"
    }

    /// Replaces the file atomically, so the app never reads half a link. The app owns its `tmp`
    /// and could have made it a symbolic link out of the container, so Threading writes only into
    /// a real directory inside a container CoreSimulator named for this device.
    static func write(_ url: URL, into container: URL, deviceID: SimulatorDeviceID) throws {
        guard container.path.contains(containerMarker(for: deviceID)) else {
            throw SimulatorControlError.invalidAppLink(
                "CoreSimulator named an app container outside this device: \(container.path)"
            )
        }
        let directory = container.appendingPathComponent("tmp", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SimulatorControlError.invalidAppLink(
                "The app's temporary directory is not a directory Threading can write a link into."
            )
        }
        try Data(url.absoluteString.utf8).write(
            to: directory.appendingPathComponent(fileName, isDirectory: false),
            options: .atomic
        )
    }
}
