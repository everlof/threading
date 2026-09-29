import AppKit
import CryptoKit
import XCTest
@testable import Threading

/// Settings → Remote Access → Face ID Approvals in each state it can be in, light and dark.
/// `THREADING_RENDER_OUT` writes the pictures; the assertions are what a picture found first.
@MainActor
final class SecretApprovalSettingsRenderTests: XCTestCase {
    private final class Store: SecretApprovalEnrollmentStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SecretApprovalEnrollment?
        let isShellReachable: Bool
        init(_ enrollment: SecretApprovalEnrollment? = nil, shellReachable: Bool = false) {
            stored = enrollment
            isShellReachable = shellReachable
        }
        func load() throws -> SecretApprovalEnrollment? { lock.withLock { stored } }
        func save(_ enrollment: SecretApprovalEnrollment) throws { lock.withLock { stored = enrollment } }
        func remove() throws { lock.withLock { stored = nil } }
    }

    private static let width: CGFloat = 640

    private static var directory: URL? {
        ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    private func states() async throws -> [(name: String, broker: SecretApprovalBroker, expect: String)] {
        let enrolled = SecretApprovalEnrollment(
            deviceID: "d", shareID: "s", signingKey: P256.Signing.PrivateKey().publicKey.x963Representation,
            agreementKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
                .publicKey.x963Representation,
            enrolledAt: Date(timeIntervalSince1970: 1_900_000_000))
        let coding = SecretApprovalBroker(store: Store(), isEnabled: { true })
        let code = try await coding.beginEnrollment()
        // A request really waiting: sealed to the enrolled key, and left waiting until the
        // renders are done (`releaseWaiting` answers it).
        let waiting = SecretApprovalBroker(store: Store(enrolled), isEnabled: { true })
        let envelope = try await waiting.wrap(Data("render".utf8))
        Task { _ = try? await waiting.unwrap(client: "keyvault", title: "keyvault show", lines: ["item: beta"],
                                             requester: "bash < claude", envelope: envelope) }
        while await waiting.status().pendingTitle == nil { await Task.yield() }
        waitingBroker = waiting
        return [
            ("off", SecretApprovalBroker(store: Store(), isEnabled: { false }), "Touch ID"),
            ("no-iphone", SecretApprovalBroker(store: Store(), isEnabled: { true }), "No iPhone enrolled yet"),
            ("enrolling", coding, SecretApprovalSettingsViewController.grouped(code)),
            ("enrolled", SecretApprovalBroker(store: Store(enrolled), isEnabled: { true }), enrolled.fingerprint),
            ("waiting", waiting, "keyvault show"),
            ("enrolled-login-keychain", SecretApprovalBroker(store: Store(enrolled, shellReachable: true), isEnabled: { true }),
             "login Keychain")
        ]
    }

    private var waitingBroker: SecretApprovalBroker?

    private func releaseWaiting() async {
        try? await waitingBroker?.forgetDevice()
        waitingBroker = nil
    }

    func testTheCodeReadsInTwoGroupsAndTimeLeftNeverGoesNegative() {
        XCTAssertEqual(SecretApprovalSettingsViewController.grouped("12345678"), "1234 5678")
        XCTAssertEqual(SecretApprovalSettingsViewController.grouped("123"), "123")
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SecretApprovalSettingsViewController.remaining(until: now.addingTimeInterval(245), now: now), "4:05")
        XCTAssertEqual(SecretApprovalSettingsViewController.remaining(until: now.addingTimeInterval(-5), now: now), "0:00")
    }

    func testTheCardSaysOneThingAtATime() {
        func status(enabled: Bool = true, code: String? = nil, enrolled: Bool = false, pending: String? = nil) -> SecretApprovalBroker.Status {
            .init(enabled: enabled, enrollmentCode: code,
                  enrollment: enrolled ? SecretApprovalEnrollment(deviceID: "d", shareID: "s", signingKey: Data(), agreementKey: Data(),
                                                                  enrolledAt: Date()) : nil,
                  pendingTitle: pending, isShellReachable: false)
        }
        XCTAssertEqual(SecretApprovalSettingsViewController.shape(for: status(enabled: false, enrolled: true)), .off)
        XCTAssertEqual(SecretApprovalSettingsViewController.shape(for: status()), .noPhone)
        XCTAssertEqual(SecretApprovalSettingsViewController.shape(for: status(code: "12345678", enrolled: true)), .code)
        XCTAssertEqual(SecretApprovalSettingsViewController.shape(for: status(enrolled: true)), .enrolled)
        XCTAssertEqual(SecretApprovalSettingsViewController.shape(for: status(enrolled: true, pending: "keyvault show")), .waiting)
    }

    func testAnExpiredCodeIsGoneFromTheStatus() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_000)
            var now: Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
        }
        let clock = Clock()
        let broker = SecretApprovalBroker(store: Store(), now: { clock.now }, isEnabled: { true })
        _ = try await broker.beginEnrollment()
        let coding = await broker.status()
        XCTAssertNotNil(coding.enrollmentCode)
        XCTAssertNotNil(coding.enrollmentExpiresAt)
        clock.advance(RemoteSecretApproval.enrollmentLifetime + 1)
        let later = await broker.status()
        XCTAssertNil(later.enrollmentCode, "the page must never show a code the phone can no longer use")
        XCTAssertNil(later.enrollmentExpiresAt)
    }

    func testRendersEveryStateToImages() async throws {
        let previousTheme = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previousTheme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previousTheme.id))
        }
        if let directory = Self.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Every state under System, light and dark; the enrolled state also under two authored
        // themes, as docs/THEME_BOUNDARY.md asks of a new durable surface.
        var renders: [(state: (name: String, broker: SecretApprovalBroker, expect: String), look: String,
                       theme: AppTheme, appearance: NSAppearance.Name)] = []
        for state in try await states() {
            renders.append((state, "light", .system, .aqua))
            renders.append((state, "dark", .system, .darkAqua))
            if state.name == "enrolled" {
                renders.append((state, "cyberpunk", AppThemeStyles.cyberpunk, .darkAqua))
                renders.append((state, "swiss", AppThemeStyles.swissMinimalist, .aqua))
            }
        }
        for render in renders {
            let appearance = try XCTUnwrap(NSAppearance(named: render.appearance))
            AppThemePalette.set(render.theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: render.theme.id))
            let controller = SecretApprovalSettingsViewController(broker: render.state.broker)
            var fixture: (window: NSWindow, host: NSView)?
            appearance.performAsCurrentDrawingAppearance { fixture = Self.fixture(controller, appearance: appearance) }
            await controller.refreshed()
            let (window, host) = try XCTUnwrap(fixture)
            let text = Self.labels(in: controller.view).joined(separator: "\n")
            XCTAssertTrue(text.contains(render.state.expect), "\(render.state.name): \(text)")
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                // Nothing wider than the card: a clipped label is how a long string breaks it.
                for label in Self.labelViews(in: controller.view) {
                    let frame = label.convert(label.bounds, to: host)
                    XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 0.5, "\(render.state.name): \(label.stringValue)")
                }
                png = Self.png(of: host)
            }
            window.orderOut(nil)
            let data = try XCTUnwrap(png)
            XCTAssertGreaterThan(data.count, 5_000, "\(render.state.name) \(render.look) rendered empty")
            let name = "face-id-approvals-\(render.state.name)-\(render.look)"
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = Self.directory {
                try data.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        await releaseWaiting()
    }

    // MARK: - Fixture

    /// The same ancestry the page's own render test uses: a real window carrying the
    /// appearance, a host on the theme's ground, and the section laid out in it.
    private static func fixture(_ controller: SecretApprovalSettingsViewController,
                                appearance: NSAppearance) -> (NSWindow, NSView) {
        let size = NSSize(width: width, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(host)
        window.appearance = appearance
        host.appearance = appearance
        controller.view.appearance = appearance
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.ground.cgColor
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.large),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Spacing.large),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.large)
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func labelViews(in root: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let label = view as? NSTextField, !label.isHidden, !label.stringValue.isEmpty { result.append(label) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    private static func labels(in root: NSView) -> [String] { labelViews(in: root).map(\.stringValue) }

    private static func png(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
