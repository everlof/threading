import Foundation

// MARK: - Disk Space

/// How much room is left on the volume the projects live on, and whether that is now a problem.
///
/// Exists because an agent has no way to notice a full disk until something fails on it. Telling
/// it about a cleanup tool it *might* want is close to useless — the tool is only worth thinking
/// about when the disk is nearly full, which is precisely the fact the agent lacks. So the
/// pressure is measured here and stated in the session's opening instructions, and only then.
enum DiskSpace {

    /// A volume's room, as the system reports it to an app deciding whether to write.
    struct Reading: Equatable {
        /// Bytes an app can actually use — the *important usage* figure, which counts space the
        /// system would free by purging caches, since that is the space really available.
        let available: Int64
        let capacity: Int64

        var usedFraction: Double {
            guard capacity > 0 else { return 0 }
            return Double(capacity - available) / Double(capacity)
        }

        /// Whether the disk is short enough to be worth an agent's attention.
        ///
        /// Below the **floor** is short on any disk: 20 GB is roughly one large Rust build away
        /// from failing, whatever the volume's size.
        ///
        /// The **fraction** exists to catch a large disk before it reaches that floor, since 8%
        /// of 4 TB is still 320 GB and by then the trend matters. But a percentage alone is
        /// wrong, and the test that proved it is in the suite: 120 GB free on a 4 TB disk reads
        /// as 97% used and is *not* short by any useful definition. So the fraction only counts
        /// while the absolute free space is itself unremarkable — a disk with real room left is
        /// never called short for being proportionally full.
        var isUnderPressure: Bool {
            if available < DiskSpaceDefaults.lowWaterMark { return true }

            return usedFraction > DiskSpaceDefaults.pressureFraction
                && available < DiskSpaceDefaults.comfortableFree
        }
    }

    /// The reading for whichever volume a path sits on, or nil when the system will not say.
    static func reading(forPath path: String) -> Reading? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]

        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let capacity = values.volumeTotalCapacity else { return nil }

        return Reading(available: available, capacity: Int64(capacity))
    }

    /// The reading for the user's home volume, which is where the projects and their build
    /// output are in every case this app has seen.
    static func homeReading() -> Reading? {
        reading(forPath: NSHomeDirectory())
    }
}

// MARK: - Disk Space Defaults

enum DiskSpaceDefaults {
    /// Below this, a disk is short whatever its size — roughly one large Rust build's worth of
    /// room, so the warning arrives before the failure rather than with it.
    static let lowWaterMark: Int64 = 20 * 1_000_000_000

    /// Above this share used, a disk is *approaching* short — but only alongside
    /// `comfortableFree`, never on its own.
    static let pressureFraction = 0.92

    /// Free space beyond which no percentage makes a disk short. A machine with this much room
    /// is not about to run out, however full it looks proportionally.
    static let comfortableFree: Int64 = 100 * 1_000_000_000
}
