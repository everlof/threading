import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import ThreadingRemoteKit

/// Why a Face ID approval could not use this connection. Messages live with the surface that
/// shows them.
enum MobileSecretApprovalFailure: Error, Equatable {
    case pairFirst, preview, directConnectionRequired, pinnedConnectionRequired, invalidCode
}

// MARK: - Keys

/// This phone's two approval keys, one per paired Mac, in the Secure Enclave. Both need Face ID
/// for every use (`biometryCurrentSet`: re-enrolling Face ID retires them), neither ever leaves
/// the enclave, and the Keychain holds only their enclave-wrapped blobs, on this device only.
/// The key-agreement key opens envelopes sealed on the Mac; the signing key signs the exact
/// request that was shown.
actor MobileSecretApprovalKeys {
    enum Failure: Error, Equatable { case faceIDRequired, notEnrolled, invalidRequest, keychain(OSStatus) }

    struct Blobs: Codable, Equatable {
        let signing: Data
        let agreement: Data
    }

    static let service = "codes.threading.mobile.secret-approval"
    static let maximumBlobBytes = 4096

    // MARK: Public Methods

    /// New keys for `hostID`, replacing any earlier ones. Returns the two public keys to enroll.
    func create(hostID: String) throws -> (signing: Data, agreement: Data) {
        let context = try Self.context()
        defer { context.invalidate() }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil
        ) else { throw Failure.faceIDRequired }
        let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        try save(Blobs(signing: signing.dataRepresentation, agreement: agreement.dataRepresentation), hostID: hostID)
        return (signing.publicKey.x963Representation, agreement.publicKey.x963Representation)
    }

    func isEnrolled(hostID: String) -> Bool { (try? load(hostID: hostID)) != nil }

    /// The same fingerprint the Mac shows: the first 64 bits of SHA-256 over the agreement key.
    func fingerprint(hostID: String) -> String? {
        guard let blobs = try? load(hostID: hostID),
              let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blobs.agreement) else { return nil }
        return Self.fingerprint(key.publicKey.x963Representation)
    }

    func forget(hostID: String) {
        _ = SecItemDelete(Self.query(hostID: hostID) as CFDictionary)
    }

    /// One Face ID for one request: opens its envelope and signs exactly what was shown.
    func approve(_ pending: RemoteSecretApproval.Pending, hostID: String, deviceID: String,
                 reason: String) async throws -> (signature: Data, secret: Data) {
        let now = Int64(Date().timeIntervalSince1970)
        guard pending.isWellFormed, pending.deviceID == deviceID, pending.expiresAt > now,
              pending.expiresAt <= now + RemoteSecretApproval.approvalLifetime + RemoteSecretApproval.allowedClockSkew
        else { throw Failure.invalidRequest }
        guard let blobs = try load(hostID: hostID) else { throw Failure.notEnrolled }
        let context = try Self.context()
        defer { context.invalidate() }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(max(0, pending.expiresAt - now)))
            if !Task.isCancelled { context.invalidate() }
        }
        defer { deadline.cancel() }
        let accepted = try await withTaskCancellationHandler {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } onCancel: {
            context.invalidate()
        }
        guard accepted else { throw Failure.faceIDRequired }
        try Task.checkCancellation()
        let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: blobs.agreement, authenticationContext: context)
        let secret = try RemoteSecretEnvelope.open(pending.envelope, as: agreement.publicKey) {
            try agreement.sharedSecretFromKeyAgreement(with: $0)
        }
        let signing = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: blobs.signing, authenticationContext: context)
        return (try signing.signature(for: pending.signingData()).derRepresentation, secret)
    }

    // MARK: Private Methods

    static func fingerprint(_ agreementKey: Data) -> String {
        let hex = SHA256.hash(data: agreementKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// A fresh context every time: no reuse window, no passcode fallback.
    private static func context() throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard SecureEnclave.isAvailable,
              context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil),
              context.biometryType == .faceID else { throw Failure.faceIDRequired }
        return context
    }

    private static func query(hostID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: hostID,
         kSecAttrSynchronizable as String: false]
    }

    private func save(_ blobs: Blobs, hostID: String) throws {
        forget(hostID: hostID)
        var item = Self.query(hostID: hostID)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = try JSONEncoder().encode(blobs)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private func load(hostID: String) throws -> Blobs? {
        var item = Self.query(hostID: hostID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= Self.maximumBlobBytes else {
            throw Failure.keychain(status)
        }
        return try? JSONDecoder().decode(Blobs.self, from: data)
    }
}

// MARK: - Screen

/// Settings → Face ID Approvals. Enroll this phone with the code the Mac shows, then approve or
/// deny the one request keyvault is waiting on. The request comes from the Mac; what it opens
/// goes back only over the pinned connection, and only after Face ID.
struct MobileSecretApprovals: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var keys = MobileSecretApprovalKeys()
    @State private var code = ""
    @State private var enrolled = false
    @State private var fingerprint: String?
    @State private var pending: RemoteSecretApproval.Pending?
    @State private var working = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var codeIsFocused: Bool

    init(previewPending: RemoteSecretApproval.Pending? = nil, previewEnrolled: Bool = false) {
        _pending = State(initialValue: previewPending)
        _enrolled = State(initialValue: previewEnrolled || previewPending != nil)
        _fingerprint = State(initialValue: previewPending.map { MobileSecretApprovalKeys.fingerprint($0.envelope.recipient) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                Text("Approve keyvault on your Mac with Face ID. Keys stay on your Mac; this iPhone only opens one, once, when you approve.")
                    .foregroundStyle(theme.secondaryLabel)
                Text(model.activeHost?.name ?? MobileL10n.string("No Mac connected"))
                    .font(.headline)
                if enrolled { requestGroup } else { enrollGroup }
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(theme.secondaryLabel)
                        .accessibilityIdentifier("secret-approvals.result")
                }
                if working { ProgressView().tint(theme.accent) }
            }
            .foregroundStyle(theme.label)
            .padding(MobileDesign.Spacing.inset)
        }
        .background(theme.ground)
        .navigationTitle("Face ID Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.activeHostID) { await refreshEnrollment() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { task?.cancel() }
        }
    }

    @ViewBuilder private var enrollGroup: some View {
        ThemedRowGroup {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Text("Enroll this iPhone").font(.headline)
                Text("On your Mac, open Settings → Remote Access → Face ID Approvals, turn it on and choose Enroll iPhone. Enter the eight-digit code here.")
                    .font(.subheadline).foregroundStyle(theme.secondaryLabel)
                SecureField("Enrollment code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeIsFocused)
                    .disabled(working)
                    .accessibilityIdentifier("secret-approvals.code")
                Button("Enroll with Face ID protection") { enroll() }
                    .disabled(working)
                    .accessibilityIdentifier("secret-approvals.enroll")
            }
            .padding(MobileDesign.Spacing.inset)
        }
    }

    @ViewBuilder private var requestGroup: some View {
        ThemedRowGroup {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                if let pending {
                    Text(verbatim: pending.title).font(.headline)
                        .accessibilityIdentifier("secret-approvals.title")
                    ForEach(Array(pending.lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.subheadline.monospaced())
                    }
                    Text(MobileL10n.string("Requested by %@", pending.requester))
                        .font(.footnote.monospaced()).foregroundStyle(theme.secondaryLabel)
                    Text("Face ID is required every time. The request expires after two minutes.")
                        .font(.footnote).foregroundStyle(theme.secondaryLabel)
                    Button("Approve with Face ID") { approve(pending) }
                        .disabled(working || model.isDemo)
                        .accessibilityIdentifier("secret-approvals.approve")
                    Button("Deny", role: .destructive) { deny(pending) }
                        .disabled(working)
                        .accessibilityIdentifier("secret-approvals.deny")
                } else {
                    Text("Nothing is waiting").font(.headline)
                    Text("When keyvault on your Mac asks for this iPhone, check here.")
                        .font(.subheadline).foregroundStyle(theme.secondaryLabel)
                    Button("Check for a request") { check() }
                        .disabled(working)
                        .accessibilityIdentifier("secret-approvals.check")
                }
                if let fingerprint {
                    Text(MobileL10n.string("This iPhone’s key: %@", fingerprint))
                        .font(.footnote.monospaced()).foregroundStyle(theme.secondaryLabel)
                }
            }
            .padding(MobileDesign.Spacing.inset)
        }
        Button("Forget on this iPhone", role: .destructive) { forget() }
            .disabled(working)
            .accessibilityIdentifier("secret-approvals.forget")
    }

    // MARK: Actions

    private func refreshEnrollment() async {
        guard !model.isDemo, let hostID = model.activeHostID else { return }
        enrolled = await keys.isEnrolled(hostID: hostID)
        fingerprint = await keys.fingerprint(hostID: hostID)
    }

    /// One attempt owns the spinner; leaving, backgrounding or switching Mac cancels it.
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        codeIsFocused = false
        working = true
        message = nil
        task = Task { @MainActor in
            defer { working = false }
            do { try await operation() } catch is CancellationError {
            } catch { message = Self.message(for: error) }
        }
    }

    private func client() throws -> (RemoteClient, String) {
        guard !model.isDemo else { throw MobileSecretApprovalFailure.preview }
        guard let client = model.client, let hostID = model.activeHostID else { throw MobileSecretApprovalFailure.pairFirst }
        try client.validateSecretApprovalTransport()
        return (client, hostID)
    }

    private func enroll() {
        let entered = code.filter { !$0.isWhitespace }
        run {
            let (client, hostID) = try client()
            guard entered.utf8.count == RemoteSecretApproval.enrollmentCodeDigits,
                  entered.utf8.allSatisfy({ (48...57).contains($0) }) else { throw MobileSecretApprovalFailure.invalidCode }
            let created = try await keys.create(hostID: hostID)
            do {
                _ = try await client.secretApproval(.init(action: .enroll, enrollmentCode: entered,
                                                          signingKey: created.signing, agreementKey: created.agreement))
            } catch {
                await keys.forget(hostID: hostID)
                throw error
            }
            code = ""
            enrolled = true
            fingerprint = MobileSecretApprovalKeys.fingerprint(created.agreement)
            message = MobileL10n.string("This iPhone is enrolled. Compare its key with the one your Mac shows.")
        }
    }

    private func check() {
        run {
            let (client, _) = try client()
            pending = try await client.secretApproval(.init(action: .pending)).pending
            if pending == nil { message = MobileL10n.string("Nothing is waiting for this iPhone.") }
        }
    }

    private func approve(_ request: RemoteSecretApproval.Pending) {
        run {
            defer { pending = nil }
            let (client, hostID) = try client()
            let answer = try await keys.approve(
                request, hostID: hostID, deviceID: RemoteDeviceIdentity.current,
                reason: MobileL10n.string("Allow %@ on your Mac once.", request.client))
            try Task.checkCancellation()
            guard hostID == model.activeHostID else { throw CancellationError() }
            let result = try await client.secretApproval(.init(action: .approve, requestID: request.id,
                                                               signature: answer.signature, secret: answer.secret))
            guard result.receipt == request.id else { throw MobileSecretApprovalKeys.Failure.invalidRequest }
            message = MobileL10n.string("Approved once. Your Mac has what it asked for; nothing was kept on this iPhone.")
        }
    }

    private func deny(_ request: RemoteSecretApproval.Pending) {
        run {
            defer { pending = nil }
            let (client, _) = try client()
            _ = try await client.secretApproval(.init(action: .deny, requestID: request.id))
            message = MobileL10n.string("Denied. Nothing was opened.")
        }
    }

    private func forget() {
        guard let hostID = model.activeHostID else { return }
        run {
            await keys.forget(hostID: hostID)
            enrolled = false
            fingerprint = nil
            pending = nil
            message = MobileL10n.string("Forgotten on this iPhone. Forget it on your Mac too.")
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case MobileSecretApprovalFailure.preview:
            return MobileL10n.string("This is a preview. Pair with your Mac to use Face ID approvals.")
        case MobileSecretApprovalFailure.pairFirst:
            return MobileL10n.string("Pair this iPhone with your Mac first.")
        case MobileSecretApprovalFailure.directConnectionRequired:
            return MobileL10n.string("Use this Mac’s LAN or Tailscale connection. Face ID approvals cannot use Hosted Direct.")
        case MobileSecretApprovalFailure.pinnedConnectionRequired:
            return MobileL10n.string("This connection has no saved Mac certificate. Pair again using the QR code for the Mac’s LAN or Tailscale connection.")
        case MobileSecretApprovalFailure.invalidCode:
            return MobileL10n.string("Enter all eight digits your Mac shows.")
        case MobileSecretApprovalKeys.Failure.faceIDRequired:
            return MobileL10n.string("Face ID is unavailable. Enable Face ID for this app in iPhone Settings and unlock the phone.")
        case MobileSecretApprovalKeys.Failure.invalidRequest:
            return MobileL10n.string("That request has expired or is not for this iPhone. Ask keyvault again.")
        case is LAError:
            return MobileL10n.string("Face ID did not approve it. Nothing was opened.")
        case let remote as RemoteClientError where remote.statusCode == 404:
            return MobileL10n.string("Face ID approvals are off on your Mac, or this iPhone is not its enrolled phone.")
        case let remote as RemoteClientError where remote.statusCode == 403:
            return MobileL10n.string("Your Mac refused. The code or request may have expired; start again from your Mac.")
        case is URLError:
            return MobileL10n.string("Could not reach your Mac. Check its Remote Access connection.")
        default:
            return MobileL10n.string("That did not complete. Nothing was opened; ask keyvault again.")
        }
    }
}
