import Foundation
import ThreadingRemoteKit

/// The most recent resolved app theme this phone received from each paired Mac.
///
/// The Mac remains authoritative. This cache exists only to bridge cold launch and reconnect,
/// when the paired-host record is already available but `/api/me` has not arrived yet. It is
/// intentionally separate from session continuity: unreadable optional appearance data must
/// never endanger an unsent draft or a saved reading position.
@MainActor
final class MobileThemeCacheStore {
    private struct Record: Codable, Equatable {
        let identity: String
        let theme: RemoteThemeDTO
    }

    private struct Archive: Codable, Equatable {
        var version: Int?
        var records: [Record]
    }

    static let archiveKey = "threading.mobile.theme-cache.v1"
    static let unreadableKeyPrefix = "threading.mobile.theme-cache.unreadable."
    static let archiveVersion = 1
    static let maximumArchiveBytes = 256 * 1_024
    static let maximumRecordCount = 64
    static let maximumColorCount = 128
    static let maximumIdentifierBytes = 1_024
    static let maximumStringBytes = 4 * 1_024
    static let maximumAggregateStringBytes = 192 * 1_024
    static let maximumGeometryMagnitude = 10_000.0

    private let defaults: UserDefaults
    private var archive: Archive
    private var writesAllowed = true
    private(set) var recoveryMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let empty = Archive(version: Self.archiveVersion, records: [])
        guard let data = defaults.data(forKey: Self.archiveKey) else {
            archive = empty
            return
        }

        do {
            guard data.count <= Self.maximumArchiveBytes else {
                throw ValidationError.invalidArchive
            }
            var decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Self.archiveVersion else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved themes were created by a newer version."
                MobileDiagnostics.logDegraded(.themeSelection, code: .newerFormat)
                return
            }
            decoded.version = Self.archiveVersion
            try Self.validate(decoded)
            archive = decoded
        } catch {
            MobileDiagnostics.logFailure(.themeSelection, error: error)
            let recoveryKey = Self.unreadableKeyPrefix + UUID().uuidString.lowercased()
            defaults.set(data, forKey: recoveryKey)
            guard defaults.data(forKey: recoveryKey) == data else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved themes could not be preserved. Changes are paused."
                return
            }
            defaults.removeObject(forKey: Self.archiveKey)
            guard defaults.data(forKey: Self.archiveKey) == nil else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved themes could not be cleared safely. Changes are paused."
                return
            }
            archive = empty
            recoveryMessage = "Unreadable saved themes were preserved for recovery."
        }
    }

    func theme(for identity: String) -> RemoteThemeDTO? {
        archive.records.first { $0.identity == identity }?.theme
    }

    /// Publishes a new in-memory answer only after the encoded replacement reads back exactly.
    @discardableResult
    func remember(_ theme: RemoteThemeDTO, for identity: String) -> Bool {
        guard writesAllowed else { return false }
        if archive.records.first(where: { $0.identity == identity })?.theme == theme {
            return true
        }
        var records = archive.records.filter { $0.identity != identity }
        records.insert(Record(identity: identity, theme: theme), at: 0)
        if records.count > Self.maximumRecordCount {
            records.removeLast(records.count - Self.maximumRecordCount)
        }
        return commit(Archive(version: Self.archiveVersion, records: records))
    }

    private func commit(_ candidate: Archive) -> Bool {
        do {
            try Self.validate(candidate)
        } catch {
            MobileDiagnostics.logFailure(.themeSelection, code: .validation)
            recoveryMessage = "Saved themes exceeded their safe storage limits and were not changed."
            return false
        }
        guard let data = try? JSONEncoder().encode(candidate),
              data.count <= Self.maximumArchiveBytes else {
            MobileDiagnostics.logFailure(.themeSelection, code: .encode)
            recoveryMessage = "Saved themes exceeded their safe storage limit and were not changed."
            return false
        }
        defaults.set(data, forKey: Self.archiveKey)
        guard defaults.data(forKey: Self.archiveKey) == data else {
            MobileDiagnostics.logFailure(.themeSelection, code: .writeVerification)
            writesAllowed = false
            recoveryMessage = "Saved themes could not be saved. Changes are paused."
            return false
        }
        archive = candidate
        recoveryMessage = nil
        return true
    }

    private enum ValidationError: Error {
        case invalidArchive
    }

    private static func validate(_ archive: Archive) throws {
        guard archive.records.count <= maximumRecordCount,
              Set(archive.records.map(\.identity)).count == archive.records.count else {
            throw ValidationError.invalidArchive
        }

        var aggregateBytes = 0
        func count(
            _ value: String?,
            required: Bool = false,
            limit: Int = maximumStringBytes
        ) throws {
            guard let value else {
                if required { throw ValidationError.invalidArchive }
                return
            }
            let bytes = value.utf8.count
            guard (!required || !value.isEmpty), bytes <= limit else {
                throw ValidationError.invalidArchive
            }
            let (total, overflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumAggregateStringBytes else {
                throw ValidationError.invalidArchive
            }
            aggregateBytes = total
        }

        func validateGeometry(_ value: Double, minimum: Double = 0) throws {
            guard value.isFinite, value >= minimum, value <= maximumGeometryMagnitude else {
                throw ValidationError.invalidArchive
            }
        }

        for record in archive.records {
            try count(record.identity, required: true, limit: maximumIdentifierBytes)
            try count(record.theme.id, required: true, limit: maximumIdentifierBytes)
            try count(record.theme.name, required: true)
            try count(record.theme.mode.rawValue, required: true, limit: maximumIdentifierBytes)
            guard record.theme.colors.count <= maximumColorCount else {
                throw ValidationError.invalidArchive
            }
            for (role, value) in record.theme.colors {
                try count(role, required: true, limit: maximumIdentifierBytes)
                try count(value, required: true)
            }

            let material = record.theme.material
            try validateGeometry(material.panelRadius)
            try validateGeometry(material.controlRadius)
            try validateGeometry(material.borderWidth)
            if let textScale = material.textScale {
                try validateGeometry(textScale, minimum: Double.leastNonzeroMagnitude)
            }
            if let typeface = material.typeface {
                try count(typeface.rawValue, required: true, limit: maximumIdentifierBytes)
            }
            try count(material.fontFamily)
            if let glow = material.glow {
                try count(glow.color, required: true)
                try validateGeometry(glow.radius)
                guard glow.opacity.isFinite, (0 ... 1).contains(glow.opacity) else {
                    throw ValidationError.invalidArchive
                }
                if let offsetX = glow.offsetX {
                    guard offsetX.isFinite, abs(offsetX) <= maximumGeometryMagnitude else {
                        throw ValidationError.invalidArchive
                    }
                }
                if let offsetY = glow.offsetY {
                    guard offsetY.isFinite, abs(offsetY) <= maximumGeometryMagnitude else {
                        throw ValidationError.invalidArchive
                    }
                }
            }
        }
    }
}

/// Live host state always wins; the device-local value is only the reconnect placeholder.
enum MobileThemeResolution {
    static func current(
        live: RemoteThemeDTO?,
        cached: RemoteThemeDTO?
    ) -> RemoteThemeDTO? {
        live ?? cached
    }
}
