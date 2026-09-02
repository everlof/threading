import Foundation

/// Turns a `device_log_prepare` request into the words an agent needs.
///
/// Separate from `AgentToolCoordinator` on purpose, the way `SimulatorAgentCommandService` is: the
/// coordinator routes and reveals, and the knowledge of *what to tell an agent* is application
/// service work that can be tested without a window.
enum DeviceLogAgentCommandService {

    enum Requested {
        case accepted(DeviceLogTap.Platform)
        case rejected(MCPToolResult)
    }

    static func platform(from arguments: DeviceLogPrepareArguments) -> Requested {
        switch (arguments.platform ?? "device").lowercased() {
        case "device", "ios", "iphone": return .accepted(.device)
        case "simulator", "sim": return .accepted(.simulator)
        case "macos", "mac": return .accepted(.macOS)
        case let other:
            return .rejected(.failure(
                "Unknown platform \"\(other)\". Use device, simulator or macos."
            ))
        }
    }

    /// What the agent does with the tap, which differs by platform because only a device cannot
    /// have a library inserted at launch.
    static func guidance(for built: DeviceLogTap.Built) -> String {
        guard built.platform.isLinked else {
            return """
                Set this when you launch the app. No build change is needed:

                  \(built.instruction)
                """
        }
        return """
            Add this to your own xcodebuild invocation, as a command-line build setting:

              \(built.instruction)

            A command-line setting rather than an -xcconfig, deliberately: a target that sets \
            OTHER_LDFLAGS without $(inherited) silently overrides an xcconfig, and many projects \
            do, which gives a clean build and no tap. $(inherited) keeps the project's own flags. \
            The tap links into every target in that build and installs once per process, so an app \
            and the frameworks it embeds do not each capture output.
            """
    }

    /// The pane still works without the tap; only the app's own printed output is missing. Saying
    /// so keeps a refusal from reading as a broken feature, and names the one way back.
    static func refusedResult() -> MCPToolResult {
        .failure("""
            The user did not allow the log tap to be linked into their app.

            The Device logs pane is still open and streaming, so the system's account of the app is             visible; what the app itself prints is not, because printed output never reaches the             unified log on its own. Do not build with the tap. The user can allow it later if they             want that output.
            """)
    }

    /// Build the tap and shape whichever answer comes back. Result shaping is this service's
    /// job, so the coordinator stays a router.
    @MainActor
    static func result(building platform: DeviceLogTap.Platform) -> MCPToolResult {
        do {
            return preparationResult(for: try DeviceLogTap.build(for: platform))
        } catch {
            return .failure("The log tap could not be prepared: \(error).")
        }
    }

    static func preparationResult(for built: DeviceLogTap.Built) -> MCPToolResult {
        .success("""
            The Device logs pane is open in this session's right panel and lists every booted \
            simulator and paired iPhone.

            \(guidance(for: built))

            Without the tap the pane still shows the system's account of the app, but nothing the \
            app itself printed: `print()` never reaches the unified log.
            """)
    }
}
