import Foundation

// MARK: - Recovery Mode

/// Whether this process is running in recovery, for the handful of places too far from the
/// composition root to be handed the answer.
///
/// **The plan is the primary carrier, not this.** `LaunchPlan` is what
/// `applicationDidFinishLaunching` reads at each step, and the surfaces that a test needs to
/// exercise take the fact through their initializer with this as the default. `ProjectStore` is
/// the composition-root exception: the plan needs the loaded store to decide onboarding, so the
/// app keeps its environment lazy and constructs the store from this resolution after `enter`.
/// What is left is the last line before a process starts — three `launch()`-shaped entry points
/// that no composition root reaches — plus the menu validator, and those ask here.
///
/// Set exactly once, from the launch sequence. A second `enter` is refused and logged rather
/// than obeyed: the mode a launch came up in is a fact about the launch, and a process that
/// changed its mind halfway is one whose ledger record has stopped being true.
@MainActor
enum RecoveryMode {

    // MARK: - Properties

    private(set) static var resolution: LaunchModeResolution = .normalLaunch

    private static var hasEntered = false

    static var isActive: Bool { resolution.isRecovery }

    // MARK: - Public Methods

    static func enter(_ resolution: LaunchModeResolution) {
        guard !hasEntered else {
            ThreadingLogger.app.error(
                """
                Refusing a second launch-mode entry: this launch is already \
                \(Self.resolution.token, privacy: .public) and was asked for \
                \(resolution.token, privacy: .public).
                """
            )
            return
        }
        hasEntered = true
        Self.resolution = resolution
    }

    /// Runs `body` with the mode forced, and puts back whatever was there.
    ///
    /// The seam a test uses instead of reaching for `NSApp` state or leaving a static behind for
    /// the next test in the process to trip over. Restores on the way out of a throw too.
    static func withResolution<T>(
        _ resolution: LaunchModeResolution,
        _ body: () throws -> T
    ) rethrows -> T {
        let previousResolution = Self.resolution
        let previousEntry = hasEntered
        Self.resolution = resolution
        hasEntered = true
        defer {
            Self.resolution = previousResolution
            hasEntered = previousEntry
        }
        return try body()
    }

    /// Refuses one thing recovery does not do, and says so where a live diagnosis can see it.
    ///
    /// Named rather than inlined at each guard, because the interesting failure is a *missing*
    /// refusal: a path that starts a process in recovery leaves no trace at all, while one that
    /// refuses leaves a line naming itself.
    static func refuse(_ what: String) {
        ThreadingLogger.app.info(
            "Recovery mode refused: \(what, privacy: .public)"
        )
    }
}
