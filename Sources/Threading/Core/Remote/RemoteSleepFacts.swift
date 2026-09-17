import Foundation

/// When this Mac goes to sleep on its own, which is when every way in stops answering.
///
/// A sleeping Mac answers nothing: not the LAN listener, not the tailnet address, not Threading
/// Direct. Only a phone on the same network can wake it, and only through a sleep proxy
/// (`RemoteWakeOnDemandFacts`). So "works away from home" is true only while the Mac is awake, and
/// a person setting it up needs to know when it will not be. On 2026-09-17 a MacBook set never to
/// sleep on its adapter but after five idle minutes on battery was reachable from away exactly when
/// it was plugged in or an agent was keeping it awake, and nothing on this page said why.
///
/// Each value is minutes of idle before sleep, `0` for never, and nil when it could not be read.
struct RemoteSleepFacts: Equatable, Sendable {
    /// On the power adapter. Every Mac has this one.
    let adapterIdleMinutes: Int?
    /// On battery. Nil on a Mac with no battery, and on one whose settings were not read.
    let batteryIdleMinutes: Int?
    /// Whether this Mac has a battery at all, which decides whether a lid and a charger are part
    /// of the answer. Nil until read.
    let hasBattery: Bool?
    /// When `pmset` was asked, so "not asked yet" and "asked, and it would not say" render as the
    /// two different things they are.
    let readAt: Date?

    static let unknown = RemoteSleepFacts(
        adapterIdleMinutes: nil,
        batteryIdleMinutes: nil,
        hasBattery: nil,
        readAt: nil
    )

    /// Every fact the line needs, so a battery whose setting could not be read is never mistaken
    /// for one that never sleeps.
    var isRead: Bool {
        guard adapterIdleMinutes != nil, let hasBattery else { return false }
        return !hasBattery || batteryIdleMinutes != nil
    }

    /// Reads `pmset -g custom`, which prints one block per power source.
    ///
    /// The idle time is not `sleep` alone. `powerd` holds "Prevent sleep while display is on" for
    /// as long as the display is lit, so the system sleeps no sooner than the display does: a
    /// battery block reading `sleep 1` with `displaysleep 5` sleeps after five minutes, and a
    /// display that never sleeps keeps the system awake too. Hence the larger of the two, and
    /// never when either is zero.
    static func parse(pmsetCustomOutput output: String?, readAt: Date) -> RemoteSleepFacts {
        let unreadable = RemoteSleepFacts(
            adapterIdleMinutes: nil,
            batteryIdleMinutes: nil,
            hasBattery: nil,
            readAt: readAt
        )
        guard let output else { return unreadable }
        var blocks: [String: [String: Int]] = [:]
        var current: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                current = String(line.dropLast())
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let current, fields.count >= 2,
                  let value = Int(fields[fields.count - 1]) else { continue }
            let key = fields.dropLast().joined(separator: " ")
            blocks[current, default: [:]][key] = value
        }
        guard let adapter = blocks[RemoteSleepDefaults.adapterBlock] else { return unreadable }
        let battery = blocks[RemoteSleepDefaults.batteryBlock]
        return RemoteSleepFacts(
            adapterIdleMinutes: idleMinutes(adapter),
            batteryIdleMinutes: battery.flatMap(idleMinutes),
            hasBattery: battery != nil,
            readAt: readAt
        )
    }

    private static func idleMinutes(_ settings: [String: Int]) -> Int? {
        guard let sleep = settings[RemoteSleepDefaults.systemSleepKey] else { return nil }
        guard sleep > 0 else { return 0 }
        guard let display = settings[RemoteSleepDefaults.displaySleepKey] else { return sleep }
        return display > 0 ? max(sleep, display) : 0
    }
}

enum RemoteSleepDefaults {
    static let executablePath = "/usr/bin/pmset"
    static let customSettingsArguments = ["-g", "custom"]
    static let adapterBlock = "AC Power"
    static let batteryBlock = "Battery Power"
    static let systemSleepKey = "sleep"
    static let displaySleepKey = "displaysleep"
}

/// Reads the facts off the main actor: it spawns `pmset`, bounded like the wake probe.
enum RemoteSleepProbe {
    static func read() async -> RemoteSleepFacts {
        await Task.detached(priority: .utility) {
            RemoteSleepFacts.parse(
                pmsetCustomOutput: RemoteWakeOnDemandProbe.runSynchronously(
                    RemoteSleepDefaults.executablePath,
                    RemoteSleepDefaults.customSettingsArguments
                ),
                readAt: Date()
            )
        }.value
    }
}

extension RemoteDoorStatus {

    /// The Connection card's sleep line: when this Mac stops answering, given macOS's energy
    /// settings and what Threading was asked to do about them (`RemoteAccessKeepAwake`).
    ///
    /// Stated for both power sources on a laptop, because the difference between them is usually
    /// the whole answer, and every remedy names the control directly above the line rather than a
    /// System Settings pane: a person who wants their Mac reachable from away can have that for as
    /// long as Remote Access is on without changing how the Mac sleeps the rest of the time.
    /// `ready` only when nothing but the person — or a lid — can put it to sleep; `attention`
    /// when it sleeps even plugged in and nothing keeps it awake; neutral when only the battery
    /// does, because that is a trade the person can choose either way.
    static func sleep(
        _ facts: RemoteSleepFacts,
        keepAwake: RemoteAccessKeepAwake = .off
    ) -> RemoteDoorStatus {
        guard facts.isRead, let adapter = facts.adapterIdleMinutes,
              let hasBattery = facts.hasBattery else {
            if keepAwake == .always {
                return keptAwake(hint: nil)
            }
            guard facts.readAt != nil else {
                return RemoteDoorStatus(
                    text: L10n.string("Checking when this Mac goes to sleep…"),
                    tone: .working,
                    isBusy: true
                )
            }
            // Unread is not "never": a Mac whose settings could not be read is not promised to
            // stay awake, so the line says what is always true instead.
            return RemoteDoorStatus(
                text: L10n.string(
                    "A phone away from home cannot reach this Mac while it sleeps."
                ),
                hint: L10n.string(
                    "Threading could not read when it goes to sleep. See System Settings ▸ Energy."
                ),
                tone: .off
            )
        }

        guard hasBattery, let battery = facts.batteryIdleMinutes else {
            return desktop(adapterIdleMinutes: adapter, keepAwake: keepAwake)
        }
        switch keepAwake {
        case .always:
            return RemoteDoorStatus(
                text: L10n.string(
                    "Threading keeps this Mac awake while Remote Access is on, plugged in or on "
                        + "battery."
                ),
                hint: L10n.string(
                    "On battery this uses charge while the Mac sits idle. Closing the lid still "
                        + "puts it to sleep unless an external display is connected."
                ),
                tone: .ready
            )
        case .whilePluggedIn where battery > 0:
            return RemoteDoorStatus(
                text: L10n.format(
                    "Plugged in, Threading keeps this Mac awake while Remote Access is on. On "
                        + "battery it goes to sleep after %@ idle, and a phone away from home "
                        + "cannot reach it then.",
                    duration(minutes: battery)
                ),
                hint: L10n.string("Choose “Always” above to keep it awake on battery too."),
                tone: .off
            )
        case .whilePluggedIn:
            return RemoteDoorStatus(
                text: L10n.string("This Mac does not go to sleep on its own."),
                hint: lidHint,
                tone: .ready
            )
        case .off where adapter > 0:
            return RemoteDoorStatus(
                text: L10n.format(
                    "This Mac goes to sleep after %@ idle, even plugged in, and a phone away "
                        + "from home cannot reach it while it sleeps.",
                    duration(minutes: adapter)
                ),
                hint: choosePluggedInHint,
                tone: .attention
            )
        case .off where battery > 0:
            return RemoteDoorStatus(
                text: L10n.format(
                    "On battery this Mac goes to sleep after %@ idle, and a phone away from "
                        + "home cannot reach it while it sleeps.",
                    duration(minutes: battery)
                ),
                hint: L10n.string(
                    "Plugged in, it stays awake. Choose “Always” above to keep it awake on "
                        + "battery too."
                ),
                tone: .off
            )
        case .off:
            return RemoteDoorStatus(
                text: L10n.string("This Mac does not go to sleep on its own."),
                hint: lidHint,
                tone: .ready
            )
        }
    }

    /// A Mac with no battery: the adapter is the only source, so both keep-awake choices are the
    /// same promise and neither mentions a lid or a charger.
    private static func desktop(
        adapterIdleMinutes adapter: Int,
        keepAwake: RemoteAccessKeepAwake
    ) -> RemoteDoorStatus {
        switch keepAwake {
        case .always, .whilePluggedIn:
            return keptAwake(hint: nil)
        case .off where adapter > 0:
            return RemoteDoorStatus(
                text: L10n.format(
                    "This Mac goes to sleep after %@ idle, and a phone away from home cannot "
                        + "reach it while it sleeps.",
                    duration(minutes: adapter)
                ),
                hint: choosePluggedInHint,
                tone: .attention
            )
        case .off:
            return RemoteDoorStatus(
                text: L10n.string("This Mac does not go to sleep on its own."),
                tone: .ready
            )
        }
    }

    private static func keptAwake(hint: String?) -> RemoteDoorStatus {
        RemoteDoorStatus(
            text: L10n.string("Threading keeps this Mac awake while Remote Access is on."),
            hint: hint,
            tone: .ready
        )
    }

    private static var lidHint: String {
        L10n.string(
            "Closing the lid still puts it to sleep unless an external display is connected."
        )
    }

    private static var choosePluggedInHint: String {
        L10n.string("Choose “Plugged in” above to keep it awake while Remote Access is on.")
    }

    private static func duration(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(minutes * 60)) ?? String(minutes)
    }
}
