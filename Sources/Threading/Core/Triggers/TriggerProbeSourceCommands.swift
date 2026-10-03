import Foundation
import ThreadingController

/// The operations on a probe source, shared by the Sources page and the agent's draft tool.
///
/// Authority follows the controller's rule: configuring — by anyone — leaves the source paused
/// with its approval cleared; only `approve`, which the host calls after a person read the exact
/// path, hash and secrets in the approval sheet, lets it run. Agents reach `configure` alone.
/// The store re-checks the last gate (no enabled probe without an approved current hash).
enum TriggerProbeSourceCommands {
    enum Failure: LocalizedError, Equatable {
        case revisionChanged
        case notAProbe
        case notApproved
        case hashChanged
        case unreadable(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .revisionChanged:
                return L10n.string("The probe source changed. Inspect it again before retrying.")
            case .notAProbe:
                return L10n.string("That source is not a probe source.")
            case .notApproved:
                return L10n.string("A person has to approve this probe on the Sources page before it can run.")
            case .hashChanged:
                return L10n.string("The probe's files changed after they were reviewed. Review them again.")
            case .unreadable(let path):
                return L10n.format("Threading cannot read “%@”.", path)
            case .invalid(let reason):
                return L10n.format("The probe source is invalid: %@", reason)
            }
        }
    }

    // MARK: - Validation

    /// The controller's own bounds, plus one rule of this host: a configured script must be the
    /// first argument, so the script whose content the approval hashes is the one that runs.
    static func validate(_ spec: ControllerSourceSpec) throws {
        do {
            try spec.validate()
        } catch let error as ControllerError {
            throw Failure.invalid(error.description)
        }
        if let script = spec.script, spec.arguments.first != script {
            throw Failure.invalid("script_must_be_first_argument")
        }
    }

    /// SHA-256 of the executable and script, read on a worker: file reads never run on the
    /// main actor, and an executable can be large.
    static func contentHash(of spec: ControllerSourceSpec) async throws -> String {
        let paths = spec.hashedPaths
        return try await Task.detached(priority: .utility) {
            do { return try TriggerProbe.contentHash(of: paths) } catch {
                throw Failure.unreadable(paths.first { FileManager.default.contents(atPath: $0) == nil } ?? paths[0])
            }
        }.value
    }

    // MARK: - Operations

    /// Creates or replaces a probe's spec. Always paused, approval always cleared.
    @discardableResult
    static func configure(
        id: TriggerSourceInstallationID?,
        expectedRevision: Int,
        spec: ControllerSourceSpec,
        store: TriggerStore = .shared,
        now: Date = Date()
    ) async throws -> TriggerSourceInstallation {
        try validate(spec)
        let hash = try await contentHash(of: spec)
        let existing = try await id.asyncFlatMap { try await store.source(id: $0) }
        if let existing, existing.probe == nil { throw Failure.notAProbe }
        let source = TriggerSourceInstallation(
            id: id ?? TriggerSourceInstallationID(),
            sourceType: TriggerProbeDefaults.sourceType,
            displayName: spec.name,
            configuration: [:],
            credentialReference: nil,
            enabled: false,
            health: .disconnected,
            lastCheckedAt: existing?.lastCheckedAt,
            lastEventAt: existing?.lastEventAt,
            boundedDiagnostic: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            probe: TriggerProbeSourceSettings(spec: spec, revision: expectedRevision + 1, hash: hash, approvedHash: nil)
        )
        try await store.saveProbeSource(source, expectedRevision: expectedRevision)
        return source
    }

    /// Re-reads the files of a probe a person is about to review. When they no longer match the
    /// configured hash — the daemon reports that as "changed" — the spec is configured again, so
    /// the sheet shows, and the approval names, what is on disk now.
    static func prepareReview(
        _ id: TriggerSourceInstallationID, store: TriggerStore = .shared
    ) async throws -> TriggerSourceInstallation {
        guard let source = try await store.source(id: id) else { throw TriggerStore.StoreError.missing }
        guard let probe = source.probe else { throw Failure.notAProbe }
        let current = try await contentHash(of: probe.spec)
        guard current != probe.hash else { return source }
        return try await configure(id: id, expectedRevision: probe.revision, spec: probe.spec, store: store)
    }

    /// The host sheet's answer. `reviewedHash` is the hash the sheet showed; it must still be the
    /// configured hash and still match the files on disk.
    @discardableResult
    static func approve(
        _ id: TriggerSourceInstallationID,
        expectedRevision: Int,
        reviewedHash: String,
        enable: Bool,
        store: TriggerStore = .shared,
        now: Date = Date()
    ) async throws -> TriggerSourceInstallation {
        guard var source = try await store.source(id: id) else { throw TriggerStore.StoreError.missing }
        guard var probe = source.probe else { throw Failure.notAProbe }
        guard probe.revision == expectedRevision else { throw Failure.revisionChanged }
        let current = try await contentHash(of: probe.spec)
        guard probe.hash == reviewedHash, current == reviewedHash else { throw Failure.hashChanged }
        probe.approvedHash = reviewedHash
        probe.revision += 1
        source.probe = probe
        source.enabled = enable
        source.health = enable ? .checking : .disconnected
        source.boundedDiagnostic = nil
        source.updatedAt = now
        try await store.saveProbeSource(source, expectedRevision: expectedRevision)
        return source
    }

    /// Pause or resume an approved probe. Resuming an unapproved one is refused.
    @discardableResult
    static func setEnabled(
        _ enabled: Bool,
        id: TriggerSourceInstallationID,
        expectedRevision: Int,
        store: TriggerStore = .shared,
        now: Date = Date()
    ) async throws -> TriggerSourceInstallation {
        guard var source = try await store.source(id: id) else { throw TriggerStore.StoreError.missing }
        guard var probe = source.probe else { throw Failure.notAProbe }
        guard probe.revision == expectedRevision else { throw Failure.revisionChanged }
        if enabled, !probe.isApproved { throw Failure.notApproved }
        probe.revision += 1
        source.probe = probe
        source.enabled = enabled
        source.health = enabled ? .checking : .disconnected
        source.boundedDiagnostic = nil
        source.updatedAt = now
        try await store.saveProbeSource(source, expectedRevision: expectedRevision)
        return source
    }

    /// One manual poll of an approved probe, paused or not.
    static func runNow(
        _ id: TriggerSourceInstallationID,
        store: TriggerStore = .shared,
        request: @escaping @Sendable (TriggerSourceInstallationID) throws -> Void = { try TriggerDaemonConfigurationStore.requestPoll($0) }
    ) async throws {
        guard let source = try await store.source(id: id) else { throw TriggerStore.StoreError.missing }
        guard let probe = source.probe else { throw Failure.notAProbe }
        guard probe.isApproved else { throw Failure.notApproved }
        try await Task.detached(priority: .utility) { try request(id) }.value
    }
}

private extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async throws -> U?) async rethrows -> U? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
