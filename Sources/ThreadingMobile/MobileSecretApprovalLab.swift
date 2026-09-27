#if DEBUG
import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import ThreadingRemoteKit

enum MobileSecretApprovalFailure: Error, Equatable {
    case pairFirst, preview, directConnectionRequired, pinnedConnectionRequired, invalidCode

    var message: String {
        switch self {
        case .pairFirst:
            return MobileL10n.string("Pair this iPhone with Threading FaceID first. Use Pair a Mac and scan the QR code in Mac Settings → Remote Access.")
        case .preview:
            return MobileL10n.string("This is a preview. Pair with your Mac to register this iPhone.")
        case .directConnectionRequired:
            return MobileL10n.string("Use this Mac’s LAN or Tailscale connection. The experiment cannot use Hosted Direct.")
        case .pinnedConnectionRequired:
            return MobileL10n.string("This connection has no saved Mac certificate. Pair again using the QR code for the Mac’s LAN or Tailscale connection.")
        case .invalidCode:
            return MobileL10n.string("Enter all eight digits from the Mac’s current experiment code.")
        }
    }

    static func message(for error: Error, enrolling: Bool) -> String {
        if let failure = error as? Self { return failure.message }
        if let failure = error as? MobileSecretApprovalSigner.Failure, case .faceIDRequired = failure {
            return MobileL10n.string("Face ID is unavailable. Enable Face ID for this app in iPhone Settings and unlock the phone before trying again.")
        }
        if error is LAError {
            return MobileL10n.string("Face ID did not authorize this operation. Check Face ID in iPhone Settings, then try a new request.")
        }
        if let remote = error as? RemoteClientError {
            if remote.statusCode == 502 {
                return MobileL10n.string("The GitHub request failed. Check the trial token on your Mac and its internet connection, then request a new approval.")
            }
            if enrolling, remote.statusCode == 403 {
                return MobileL10n.string("The Mac refused registration. Stop and start the experiment on the Mac, then enter its new code within five minutes.")
            }
            if remote.statusCode == 404 {
                return MobileL10n.string("This Mac does not offer the experiment. Pair with Threading FaceID, then start the experiment in its Remote Access settings.")
            }
            if case .unauthorized = remote {
                return MobileL10n.string("Pair with this Mac again. Its owner connection is no longer authorized.")
            }
        }
        if error is URLError {
            return MobileL10n.string("Could not reach the Mac. Check its Remote Access connection, then try again.")
        }
        return MobileL10n.string("Approval did not complete. Check Face ID, the connection, and the Mac experiment. An expired or used request cannot be retried; request a new operation.")
    }
}

enum MobileSecretApprovalEnrollment {
    /// Validate before generating a key or sending a request. Whitespace from pasting a code
    /// may be removed; other characters must not silently become a different code.
    static func validate(code: String, client: RemoteClient?, hostID: String?, isDemo: Bool) throws -> String {
        guard !isDemo else { throw MobileSecretApprovalFailure.preview }
        guard let client, hostID != nil else { throw MobileSecretApprovalFailure.pairFirst }
        try client.validateSecretApprovalTransport()
        let digits = code.filter { !$0.isWhitespace }
        guard digits.utf8.count == RemoteSecretApprovalLab.enrollmentCodeDigits,
              digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw MobileSecretApprovalFailure.invalidCode
        }
        return digits
    }
}

/// Keeps only an enclave-wrapped key blob in memory for this screen's lifetime. No sync, export
/// of raw key material, persistence, passcode fallback, or Simulator software-key fallback.
actor MobileSecretApprovalSigner {
    enum Failure: Error { case faceIDRequired, notEnrolled, invalidChallenge }
    private var wrappedKey: Data?

    func forget() { wrappedKey = nil }

    private func context() throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard SecureEnclave.isAvailable,
              context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil),
              context.biometryType == .faceID else { throw Failure.faceIDRequired }
        return context
    }

    func enroll() throws -> Data {
        let context = try context()
        defer { context.invalidate() }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], nil
        ) else { throw Failure.faceIDRequired }
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: access, authenticationContext: context
        )
        wrappedKey = key.dataRepresentation
        return key.publicKey.x963Representation
    }

    func sign(_ challenge: RemoteSecretApprovalLab.Challenge, deviceID: String) async throws -> Data {
        guard challenge.isSupported,
              challenge.deviceID == deviceID,
              challenge.expiresAt > Int64(Date().timeIntervalSince1970),
              challenge.expiresAt <= Int64(Date().timeIntervalSince1970) + RemoteSecretApprovalLab.approvalLifetime + RemoteSecretApprovalLab.allowedClockSkew else {
            throw Failure.invalidChallenge
        }
        guard let wrappedKey else { throw Failure.notEnrolled }
        let context = try context()
        defer { context.invalidate() }
        // A new context for every signing operation: no cached enrollment/unlock approval.
        let remaining = max(0, challenge.expiresAt - Int64(Date().timeIntervalSince1970))
        let deadline = Task {
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { context.invalidate() }
        }
        defer { deadline.cancel() }
        let accepted = try await withTaskCancellationHandler {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: challenge.isGitHubProfile
                    ? MobileL10n.string("Allow your Mac to send its trial token to GitHub once to read your username.")
                    : MobileL10n.string("Approve one use of the disposable test credential on your Mac.")
            )
        } onCancel: {
            context.invalidate()
        }
        guard accepted else { throw Failure.faceIDRequired }
        try Task.checkCancellation()
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: wrappedKey, authenticationContext: context
        )
        return try key.signature(for: challenge.signingData()).derRepresentation
    }
}

struct MobileSecretApprovalLab: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var signer = MobileSecretApprovalSigner()
    @State private var enrolledClient: RemoteClient?
    @State private var enrolledHostID: String?
    @State private var challenge: RemoteSecretApprovalLab.Challenge?
    private enum Operation: Equatable { case enrolling, requesting, approving, cancelling }
    private enum Phase: Equatable {
        case idle, working(UUID, Operation), succeeded, failed, cancelled
    }
    @State private var phase = Phase.idle
    private var busy: Bool {
        if case .working = phase { return true }
        return false
    }
    @State private var message: String?
    @State private var feedbackOperation = Operation.enrolling
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var codeIsFocused: Bool

    init(previewChallenge: RemoteSecretApprovalLab.Challenge? = nil, previewGitHubLogin: String? = nil) {
        _challenge = State(initialValue: previewChallenge)
        if let login = previewGitHubLogin, RemoteSecretApprovalLab.isValidGitHubLogin(login) {
            _message = State(initialValue: Self.githubSuccess(login))
            _feedbackOperation = State(initialValue: .approving)
        }
    }

    private static func githubSuccess(_ login: String) -> String {
        MobileL10n.string("GitHub verified: %@. Approved once; your token stayed between this Mac and GitHub.", login)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                Text("Approve one operation on your Mac. Its credential is never sent to this iPhone or a chat.")
                    .foregroundStyle(theme.secondaryLabel)
                Text(model.activeHost?.name ?? MobileL10n.string("No Mac connected"))
                    .font(.headline)
                    .foregroundStyle(theme.label)
                ThemedRowGroup {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        Text("1. Enroll this iPhone").font(.headline)
                        Text("Pair with this Mac using its Remote Access QR code first. Then start the experiment under Developer and enter its eight-digit code here.")
                            .font(.subheadline).foregroundStyle(theme.secondaryLabel)
                        SecureField("Enrollment code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($codeIsFocused)
                            .disabled(busy || enrolledClient != nil)
                            .accessibilityIdentifier("secret-approval.code")
                        Button("Enroll with Face ID protection") { enroll() }
                            .disabled(busy || enrolledClient != nil)
                            .accessibilityIdentifier("secret-approval.enroll")
                        if feedbackOperation == .enrolling { feedback }
                    }
                    .padding(MobileDesign.Spacing.inset)
                }
                ThemedRowGroup {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                        Text("2. Approve one use").font(.headline)
                        Text("For the GitHub trial, the Mac sends its token only to GitHub. Only your username and a receipt come back.")
                            .font(.subheadline).foregroundStyle(theme.secondaryLabel)
                        if let challenge {
                            Text(challenge.isGitHubProfile
                                 ? MobileL10n.string("Allow GitHub to return your username?")
                                 : MobileL10n.string("Allow one use of the disposable test credential?")).font(.headline)
                            if challenge.isGitHubProfile {
                                // localization-ignore: Exact HTTP method and destination are signed protocol values.
                                Text(verbatim: "\(RemoteSecretApprovalLab.githubMethod) \(RemoteSecretApprovalLab.githubURL)")
                                    .font(.caption.monospaced())
                                Text("Uses the GitHub trial token entered on your Mac. No repository access or changes.")
                                    .font(.footnote).foregroundStyle(theme.secondaryLabel)
                            }
                            Text("Approval expires after 60 seconds. Face ID is required every time.")
                                .font(.footnote).foregroundStyle(theme.secondaryLabel)
                            Button("Approve with Face ID") { approve(challenge) }
                                .disabled(busy || model.isDemo)
                                .accessibilityIdentifier("secret-approval.approve")
                            Button("Cancel", role: .cancel) { cancel(challenge) }
                                .disabled(busy)
                        } else {
                            Button("Request operation") { requestChallenge() }
                                .disabled(busy || enrolledClient == nil)
                        }
                        if feedbackOperation != .enrolling { feedback }
                    }
                    .padding(MobileDesign.Spacing.inset)
                }
                Text("Debug proof of concept. A physical Face ID iPhone and a pinned HTTPS connection are required. Closing this screen forgets the phone’s approval key; stop and restart the Mac experiment to enroll again.")
                    .font(.footnote).foregroundStyle(theme.secondaryLabel)
            }
            .foregroundStyle(theme.label)
            .padding(MobileDesign.Spacing.inset)
        }
        .background(theme.ground)
        .navigationTitle("Face ID approval")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { forgetEnrollment() }
        .onChange(of: model.activeHostID) { _, _ in forgetEnrollment() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { forgetEnrollment() }
        }
    }

    @ViewBuilder private var feedback: some View {
        if busy {
            ProgressView().tint(theme.accent)
                .accessibilityLabel(feedbackOperation == .enrolling
                    ? MobileL10n.string("Registering this iPhone…") : MobileL10n.string("Working…"))
        }
        if let message {
            Text(message).font(.subheadline).foregroundStyle(theme.secondaryLabel)
                .accessibilityIdentifier("secret-approval.result")
        }
    }

    private func forgetEnrollment() {
        operationTask?.cancel()
        phase = .cancelled
        enrolledClient = nil
        enrolledHostID = nil
        challenge = nil
        code = ""
        message = nil
        let previous = signer
        signer = MobileSecretApprovalSigner()
        Task { await previous.forget() }
    }

    /// Exactly one named attempt owns the spinner. HTTP requests time out after ten seconds;
    /// Face ID is invalidated at the challenge deadline (at most sixty seconds). Departure,
    /// backgrounding or a Mac switch cancels and invalidates the attempt; no state is restored.
    /// Success/refusal/cancellation replace progress rather than silently starting another try.
    private func run(_ kind: Operation, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let id = UUID()
        codeIsFocused = false
        feedbackOperation = kind
        phase = .working(id, kind)
        message = nil
        operationTask = Task { @MainActor in
            do {
                try await operation()
                if phase == .working(id, kind) { phase = .succeeded }
            } catch is CancellationError {
                if phase == .working(id, kind) { phase = .cancelled }
            } catch {
                guard phase == .working(id, kind) else { return }
                phase = .failed
                message = MobileSecretApprovalFailure.message(for: error, enrolling: kind == .enrolling)
            }
        }
    }

    private func enroll() {
        let client = model.client
        let hostID = model.activeHostID
        let enteredCode = code
        run(.enrolling) {
            let checkedCode = try MobileSecretApprovalEnrollment.validate(
                code: enteredCode, client: client, hostID: hostID, isDemo: model.isDemo
            )
            guard let client, let hostID else { throw MobileSecretApprovalFailure.pairFirst }
            let publicKey = try await signer.enroll()
            try Task.checkCancellation()
            _ = try await client.secretApprovalLab(.init(action: .enroll, enrollmentCode: checkedCode, publicKey: publicKey))
            try Task.checkCancellation()
            guard hostID == model.activeHostID else { throw CancellationError() }
            enrolledClient = client
            enrolledHostID = hostID
            code = ""
            message = MobileL10n.string("This iPhone is registered. Request a test operation below; Face ID appears when you approve it.")
        }
    }

    private func requestChallenge() {
        guard let client = enrolledClient, enrolledHostID == model.activeHostID else { return }
        run(.requesting) {
            let response = try await client.secretApprovalLab(.init(action: .challenge))
            try Task.checkCancellation()
            guard let offered = response.challenge, offered.isSupported else { throw MobileSecretApprovalSigner.Failure.invalidChallenge }
            challenge = offered
        }
    }

    private func approve(_ offered: RemoteSecretApprovalLab.Challenge) {
        guard let client = enrolledClient, enrolledHostID == model.activeHostID else { return }
        run(.approving) {
            defer { challenge = nil }
            let signature = try await signer.sign(offered, deviceID: RemoteDeviceIdentity.current)
            try Task.checkCancellation()
            guard enrolledHostID == model.activeHostID else { throw CancellationError() }
            let result = try await client.secretApprovalLab(.init(
                action: .approve, challengeID: offered.id, signature: signature
            ))
            guard result.receipt == offered.id else { throw MobileSecretApprovalSigner.Failure.invalidChallenge }
            if offered.isGitHubProfile {
                guard let login = result.githubLogin, RemoteSecretApprovalLab.isValidGitHubLogin(login) else {
                    throw MobileSecretApprovalSigner.Failure.invalidChallenge
                }
                message = Self.githubSuccess(login)
            } else {
                message = MobileL10n.string("Approved once. The Mac used its test credential; no secret left the Mac.")
            }
        }
    }

    private func cancel(_ offered: RemoteSecretApprovalLab.Challenge) {
        guard let client = enrolledClient else { return }
        run(.cancelling) {
            defer { challenge = nil }
            _ = try await client.secretApprovalLab(.init(action: .cancel, challengeID: offered.id))
            message = MobileL10n.string("Request cancelled.")
        }
    }
}
#endif
