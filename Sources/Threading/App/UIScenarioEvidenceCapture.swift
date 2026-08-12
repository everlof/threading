#if DEBUG
import AppKit
import Foundation

/// Captures UI-scenario evidence from inside Threading's own window.
///
/// XCUITest's screen-recording path is a system-wide capture and therefore crosses macOS's
/// Screen Recording privacy boundary. This helper instead asks AppKit to render Threading's own
/// window into a bitmap. It exists only in Debug builds, only installs for the fail-closed UI
/// scenario bootstrap, and writes only below that scenario's disposable Cocoa home.
@MainActor
final class UIScenarioEvidenceCapture {
    enum InstallationResult {
        case installed
        case refused(String)
    }

    struct Configuration: Equatable {
        let outputDirectory: URL
        let token: String

        static func resolve(
            environment: [String: String],
            scenarioRoot: URL,
            fileManager: FileManager = .default
        ) -> Result<Configuration, ConfigurationError> {
            guard let outputPath = environment["THREADING_UI_SCENARIO_EVIDENCE_DIR"],
                  let token = environment["THREADING_UI_SCENARIO_EVIDENCE_TOKEN"] else {
                return .failure(.missingContract)
            }
            guard UUID(uuidString: token) != nil else {
                return .failure(.invalidToken)
            }

            let expectedDirectory = scenarioRoot
                .appendingPathComponent("evidence", isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard outputDirectory == expectedDirectory,
                  fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(.unsafeOutputDirectory)
            }
            return .success(Configuration(outputDirectory: outputDirectory, token: token))
        }
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case missingContract
        case invalidToken
        case unsafeOutputDirectory

        var errorDescription: String? {
            switch self {
            case .missingContract:
                return "scenario evidence contract is missing"
            case .invalidToken:
                return "scenario evidence token is invalid"
            case .unsafeOutputDirectory:
                return "scenario evidence directory is missing or outside scenario home"
            }
        }
    }

    private static var active: UIScenarioEvidenceCapture?

    private let configuration: Configuration
    private var timer: Timer?
    private var handledRequestID: UUID?

    static func installIfRequested(
        environment: [String: String],
        scenarioRoot: URL,
        fileManager: FileManager = .default
    ) -> InstallationResult {
        switch Configuration.resolve(
            environment: environment,
            scenarioRoot: scenarioRoot,
            fileManager: fileManager
        ) {
        case .failure(let error):
            return .refused(error.localizedDescription)
        case .success(let configuration):
            active?.invalidate()
            active = UIScenarioEvidenceCapture(configuration: configuration)
            return .installed
        }
    }

    private init(configuration: Configuration) {
        self.configuration = configuration
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(checkForRequest),
            userInfo: nil,
            repeats: true
        )
        timer?.tolerance = 0.02
    }

    private func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func checkForRequest() {
        let requestURL = configuration.outputDirectory
            .appendingPathComponent("capture-request.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(CaptureRequest.self, from: data),
              request.token == configuration.token,
              request.id != handledRequestID,
              Self.isSafeEvidenceName(request.name) else {
            return
        }
        handledRequestID = request.id

        let imageURL = configuration.outputDirectory
            .appendingPathComponent(request.name)
            .appendingPathExtension("png")
        let errorURL = configuration.outputDirectory
            .appendingPathComponent(request.name)
            .appendingPathExtension("error.txt")
        do {
            let data = try captureVisibleWindow()
            try data.write(to: imageURL, options: .atomic)
        } catch {
            let message = "\(error.localizedDescription)\n"
            try? Data(message.utf8).write(to: errorURL, options: .atomic)
        }
    }

    private struct CaptureRequest: Decodable {
        let id: UUID
        let token: String
        let name: String
    }

    private func captureVisibleWindow() throws -> Data {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible),
              let contentView = window.contentView else {
            throw CaptureError.windowUnavailable
        }

        // The content view's superview is AppKit's window frame. Rendering that view keeps the
        // title bar in the evidence without reading any pixels belonging to another process.
        let captureView = contentView.superview ?? contentView
        captureView.layoutSubtreeIfNeeded()
        captureView.displayIfNeeded()
        let activityBeams = Self.descendants(of: captureView, as: AgentActivityBeamView.self)
        return try withCachedDisplayFallbacks(activityBeams, at: 0) {
            try renderPNG(of: captureView)
        }
    }

    private func renderPNG(of captureView: NSView) throws -> Data {
        let bounds = captureView.bounds.integral
        guard !bounds.isEmpty,
              let representation = captureView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CaptureError.bitmapUnavailable
        }
        captureView.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        return data
    }

    private func withCachedDisplayFallbacks<Result>(
        _ views: [AgentActivityBeamView],
        at index: Int,
        _ body: () throws -> Result
    ) rethrows -> Result {
        guard index < views.count else { return try body() }
        return try views[index].withCachedDisplayFallback {
            try withCachedDisplayFallbacks(views, at: index + 1, body)
        }
    }

    private static func descendants<View: NSView>(of root: NSView, as type: View.Type) -> [View] {
        var matches: [View] = []
        var pending = root.subviews
        while let view = pending.popLast() {
            if let match = view as? View { matches.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return matches
    }

    static func isSafeEvidenceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 96,
              name.first?.isNumber == false,
              name.first?.isLetter == true else {
            return false
        }
        return name.allSatisfy { character in
            character.isLowercase || character.isNumber || character == "-"
        }
    }

    private enum CaptureError: LocalizedError {
        case windowUnavailable
        case bitmapUnavailable
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .windowUnavailable:
                return "Threading has no visible window to capture"
            case .bitmapUnavailable:
                return "Threading's window could not allocate a bitmap representation"
            case .pngEncodingFailed:
                return "Threading's window could not encode PNG evidence"
            }
        }
    }
}
#endif
