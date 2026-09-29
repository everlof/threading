import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import ThreadingRemoteKit
import UserNotifications

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

/// Settings → Security → Face ID Approvals. Enroll this phone with the code the Mac shows, then
/// approve or deny what keyvault asks.
///
/// Nothing here should need guessing: every state says what it is and what to do next, the one
/// action that matters is the filled button, and a request finds the screen rather than the other
/// way round. While the screen is open and the app in front it looks for one every two seconds,
/// and a notification opens it straight onto one. The request comes from the Mac; what it opens
/// goes back only over the pinned connection, and only after Face ID.
struct MobileSecretApprovals: View {
    /// A fixed state for UI evidence; nil in the app.
    enum Preview: Equatable {
        case enroll, ready, request(RemoteSecretApproval.Pending), approved
    }

    /// What the last action came to, said in one line under the card.
    enum Outcome: Equatable {
        case enrolled, approved, denied, forgotten, failed(String)
    }

    static let pollInterval: Duration = .seconds(2)

    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var keys = MobileSecretApprovalKeys()
    @State private var code = ""
    @State private var enrolled = false
    @State private var fingerprint: String?
    @State private var pending: RemoteSecretApproval.Pending?
    @State private var working = false
    @State private var outcome: Outcome?
    @State private var listenFailure: String?
    @State private var confirmsForget = false
    @State private var task: Task<Void, Never>?
    @FocusState private var codeIsFocused: Bool
    private let preview: Preview?

    init(preview: Preview? = nil) {
        self.preview = preview
        switch preview {
        case .request(let request):
            _pending = State(initialValue: request)
            _enrolled = State(initialValue: true)
            _fingerprint = State(initialValue: MobileSecretApprovalKeys.fingerprint(request.envelope.recipient))
        case .ready, .approved:
            _enrolled = State(initialValue: true)
            _fingerprint = State(initialValue: "3F2A 9C41 07BE D6E8")
            _outcome = State(initialValue: preview == .approved ? .approved : nil)
        case .enroll, nil:
            break
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                intro
                if let pending {
                    requestCard(pending)
                } else if enrolled {
                    readyCard
                } else {
                    enrollCard
                }
                if let outcome { outcomeRow(outcome) }
                if enrolled { keyCard }
            }
            .foregroundStyle(theme.label)
            .padding(MobileDesign.Spacing.inset)
        }
        .background(theme.ground)
        .navigationTitle("Face ID Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.activeHostID) { await refreshEnrollment() }
        .task(id: listening) { await listen() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { task?.cancel() }
        }
        .themedAlert(
            "Forget this iPhone?",
            message: "keyvault can no longer ask this iPhone until you enroll it again. Forget it on your Mac too.",
            isPresented: $confirmsForget,
            actions: [
                ThemedDialogAction("Forget", role: .destructive) { forget() },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
    }

    // MARK: Parts

    private var macName: String {
        model.activeHost?.name ?? MobileL10n.string("your Mac")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Label {
                Text("Face ID for keyvault").font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "faceid").foregroundStyle(theme.accent)
            }
            Text(MobileL10n.string(
                "keyvault on %@ can ask this iPhone to open one of its keys. You see what is asked and who asks, and Face ID approves it once.",
                macName))
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enrollCard: some View {
        ThemedRowGroup {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Text("Enroll this iPhone").font(.headline)
                step(1, MobileL10n.string("On your Mac, open Settings › Remote Access › Face ID Approvals, turn it on and choose Enroll iPhone."))
                step(2, MobileL10n.string("Type the eight-digit code your Mac shows:"))
                // localization-ignore: example digits in the code field's prompt, not copy
                TextField(text: $code, prompt: Text(verbatim: "1234 5678").foregroundStyle(theme.tertiaryLabel)) {
                    Text("Enrollment code")
                }
                .font(.title2.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeIsFocused)
                .mobileUIEvidenceKeyboardFocus($codeIsFocused)
                .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.dialogActionHeight)
                .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.controlRadius)
                        .stroke(codeIsFocused ? theme.accent : theme.border, lineWidth: theme.borderWidth)
                }
                .onChange(of: code) { _, value in
                    let formatted = Self.formatted(value)
                    if formatted != value { code = formatted }
                }
                .disabled(working)
                .accessibilityIdentifier("secret-approvals.code")
                Button { enroll() } label: { actionLabel(MobileL10n.string("Enroll with Face ID"), systemImage: "faceid") }
                    .buttonStyle(MobileThemedActionButtonStyle(kind: .primary, theme: theme))
                    .disabled(working || Self.digits(code).count != RemoteSecretApproval.enrollmentCodeDigits)
                    .accessibilityIdentifier("secret-approvals.enroll")
                Text("Face ID protects the two keys this creates. They never leave this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MobileDesign.Spacing.inset)
        }
    }

    private var readyCard: some View {
        ThemedRowGroup {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Circle()
                        .fill(listenFailure == nil ? theme.positive : theme.warning)
                        .frame(width: 10, height: 10)
                    Text(verbatim: listenFailure == nil ? MobileL10n.string("Ready") : MobileL10n.string("Can’t reach your Mac"))
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("secret-approvals.state")
                Text(listenFailure ?? MobileL10n.string(
                    "Waiting for keyvault on %@. A request appears here by itself, and as a notification when this app is closed.",
                    macName))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await poll() } } label: { Text("Check now") }
                    .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme, width: .intrinsic))
                    .disabled(working)
                    .accessibilityIdentifier("secret-approvals.check")
            }
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requestCard(_ request: RemoteSecretApproval.Pending) -> some View {
        ThemedRowGroup {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
                Label("keyvault asks to open a key", systemImage: "key.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                Text(verbatim: request.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("secret-approvals.title")
                if !request.lines.isEmpty {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                        ForEach(Array(request.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.subheadline.monospaced())
                        }
                    }
                    .padding(MobileDesign.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius))
                }
                Text(MobileL10n.string("Asked by %@", request.requester))
                    .font(.footnote.monospaced())
                    .foregroundStyle(theme.secondaryLabel)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MobileL10n.string("Face ID is required. Expires in %@.",
                                           Self.remaining(until: request.expiresAt, now: context.date)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.secondaryLabel)
                }
                Button { approve(request) } label: { actionLabel(MobileL10n.string("Approve with Face ID"), systemImage: "faceid") }
                    .buttonStyle(MobileThemedActionButtonStyle(kind: .primary, theme: theme))
                    .disabled(working)
                    .accessibilityIdentifier("secret-approvals.approve")
                Button(role: .destructive) { deny(request) } label: { Text("Deny") }
                    .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme))
                    .disabled(working)
                    .accessibilityIdentifier("secret-approvals.deny")
            }
            .padding(MobileDesign.Spacing.inset)
        }
    }

    private func outcomeRow(_ outcome: Outcome) -> some View {
        let (symbol, color, text) = describe(outcome)
        return HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("secret-approvals.result")
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            if let fingerprint {
                Text("This iPhone’s key").font(.footnote.weight(.semibold)).foregroundStyle(theme.secondaryLabel)
                Text(verbatim: fingerprint).font(.body.monospaced())
                    .accessibilityIdentifier("secret-approvals.fingerprint")
                Text("Your Mac shows the same key under Settings › Remote Access › Face ID Approvals.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(role: .destructive) { confirmsForget = true } label: { Text("Forget this iPhone") }
                .buttonStyle(MobileThemedActionButtonStyle(kind: .secondary, theme: theme, width: .intrinsic))
                .disabled(working)
                .padding(.top, MobileDesign.Spacing.small)
                .accessibilityIdentifier("secret-approvals.forget")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(theme.accentMuted, in: Circle())
            Text(verbatim: text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one spinner on this screen: inside whichever button started the work.
    private func actionLabel(_ localizedTitle: String, systemImage: String) -> some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            if working {
                ProgressView().tint(theme.accentForeground)
            } else {
                Image(systemName: systemImage)
            }
            Text(verbatim: localizedTitle)
        }
    }

    private func describe(_ outcome: Outcome) -> (String, Color, String) {
        switch outcome {
        case .enrolled:
            return ("checkmark.circle.fill", theme.positive,
                    MobileL10n.string("This iPhone is enrolled. Check that your Mac shows the same key, then run keyvault device add iphone on the Mac."))
        case .approved:
            return ("checkmark.circle.fill", theme.positive,
                    MobileL10n.string("Approved. Your Mac has what it asked for; nothing was kept on this iPhone."))
        case .denied:
            return ("xmark.circle", theme.secondaryLabel, MobileL10n.string("Denied. Nothing was opened."))
        case .forgotten:
            return ("minus.circle", theme.secondaryLabel,
                    MobileL10n.string("Forgotten on this iPhone. Forget it on your Mac too."))
        case .failed(let message):
            return ("exclamationmark.triangle.fill", theme.negative, message)
        }
    }

    // MARK: Formatting

    static func digits(_ text: String) -> String {
        String(text.unicodeScalars.filter { (48...57).contains($0.value) }.map(Character.init))
    }

    /// "12345678" and "1234 5678" alike become "1234 5678", at most eight digits.
    static func formatted(_ text: String) -> String {
        let digits = String(digits(text).prefix(RemoteSecretApproval.enrollmentCodeDigits))
        guard digits.count > 4 else { return digits }
        return digits.prefix(4) + " " + digits.dropFirst(4)
    }

    static func remaining(until expiresAt: Int64, now: Date) -> String {
        let seconds = max(0, Int(expiresAt) - Int(now.timeIntervalSince1970))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Listening

    /// On while the screen is open, the app in front and the phone enrolled with nothing shown.
    private var listening: Bool {
        preview == nil && !model.isDemo && enrolled && pending == nil && scenePhase == .active
    }

    private func listen() async {
        while listening, !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func poll() async {
        guard !working, let connection = try? client() else { return }
        do {
            let found = try await connection.0.secretApproval(.init(action: .pending)).pending
            listenFailure = nil
            if let found, found.expiresAt > Int64(Date().timeIntervalSince1970) {
                pending = found
                outcome = nil
            }
        } catch is CancellationError {
        } catch {
            listenFailure = Self.message(for: error)
        }
    }

    // MARK: Actions

    private func refreshEnrollment() async {
        guard preview == nil, !model.isDemo, let hostID = model.activeHostID else { return }
        enrolled = await keys.isEnrolled(hostID: hostID)
        fingerprint = await keys.fingerprint(hostID: hostID)
    }

    /// One attempt owns the spinner; leaving, backgrounding or switching Mac cancels it.
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        codeIsFocused = false
        working = true
        outcome = nil
        task = Task { @MainActor in
            defer { working = false }
            do { try await operation() } catch is CancellationError {
            } catch { outcome = .failed(Self.message(for: error)) }
        }
    }

    private func client() throws -> (RemoteClient, String) {
        guard preview == nil, !model.isDemo else { throw MobileSecretApprovalFailure.preview }
        guard let client = model.client, let hostID = model.activeHostID else { throw MobileSecretApprovalFailure.pairFirst }
        try client.validateSecretApprovalTransport()
        return (client, hostID)
    }

    private func enroll() {
        let entered = Self.digits(code)
        run {
            let (client, hostID) = try client()
            guard entered.utf8.count == RemoteSecretApproval.enrollmentCodeDigits else {
                throw MobileSecretApprovalFailure.invalidCode
            }
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
            outcome = .enrolled
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
            outcome = .approved
            Self.clearDeliveredAlerts()
        }
    }

    private func deny(_ request: RemoteSecretApproval.Pending) {
        run {
            defer { pending = nil }
            let (client, _) = try client()
            _ = try await client.secretApproval(.init(action: .deny, requestID: request.id))
            outcome = .denied
            Self.clearDeliveredAlerts()
        }
    }

    private func forget() {
        guard let hostID = model.activeHostID else { return }
        run {
            await keys.forget(hostID: hostID)
            enrolled = false
            fingerprint = nil
            pending = nil
            outcome = .forgotten
        }
    }

    /// An answered request's alert has nothing left to say; take it off the lock screen.
    static func clearDeliveredAlerts() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let answered = delivered.filter {
                $0.request.content.threadIdentifier == RemoteNotificationKind.secretApprovalThread
            }.map(\.request.identifier)
            if !answered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: answered) }
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

extension MobileSecretApprovals.Preview {
    /// The UI-evidence fixtures: `secret-approvals-enroll|ready|request|approved`.
    static func demo(_ id: String?) -> Self {
        switch id {
        case "secret-approvals-ready": return .ready
        case "secret-approvals-approved": return .approved
        case "secret-approvals-request":
            return .request(RemoteSecretApproval.Pending(
                id: UUID(), deviceID: "preview-only",
                expiresAt: Int64(Date().timeIntervalSince1970) + 95,
                client: "keyvault", title: "keyvault show",
                lines: ["item: AuthKey_ABCDE12345.p8", "reason: sign the release"],
                requester: "bash < claude < threading-ptyd",
                envelope: .init(version: 1, recipient: Data(repeating: 4, count: 65),
                                ephemeral: Data(repeating: 4, count: 65), sealed: Data(repeating: 0, count: 48))))
        default: return .enroll
        }
    }
}
