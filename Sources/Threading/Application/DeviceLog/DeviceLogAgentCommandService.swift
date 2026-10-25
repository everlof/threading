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

    /// Consent concerns the user's product. The pane's actual capture status is a separate fact.
    static func refusedResult() -> MCPToolResult {
        .failure("""
            The user did not allow the log tap to be linked into their app.

            Device Logs is revealed. Use plugin__devicelogs__state to inspect its selected source \
            and capture status. System-log capture can read available unified logs, subject to \
            privacy redaction, but it does not capture ordinary stdout/stderr automatically. A \
            separate app-console route may provide merged console output and may relaunch the app. \
            Do not link the tap. The user can allow it later.
            """)
    }

    /// Build the tap and shape whichever answer comes back. Result shaping is this service's
    /// job, so the coordinator stays a router.
    static func result(building platform: DeviceLogTap.Platform) async -> MCPToolResult {
        await Task.detached(priority: .userInitiated) {
            do {
                return preparationResult(for: try DeviceLogTap.build(for: platform))
            } catch {
                return .failure("The log tap could not be prepared: \(error).")
            }
        }.value
    }

    static func preparationResult(for built: DeviceLogTap.Built) -> MCPToolResult {
        .success("""
            Device Logs is revealed for this session. Follow any installation or setup status \
            in the pane; revealing it does not prove a reader is connected or that output arrived.

            Use plugin__devicelogs__state to inspect the actual device/source, process choices, \
            current filter and capture availability. Change that same visible panel with \
            plugin__devicelogs__configure, then use plugin__devicelogs__read or \
            plugin__devicelogs__wait without repeating filters. Pass returned stable row IDs to \
            plugin__devicelogs__reveal to highlight the exact evidence for the user.

            System logs include available os_log/Logger entries and may redact private values; \
            ordinary print()/stdout/stderr do not automatically reach the unified log. An app's \
            console route can provide merged console output and may relaunch it. A saved app-log \
            route contains only what the app wrote to that file. State reports the selected \
            route's availability instead of assuming all three channels are present.

            \(guidance(for: built))

            Preparing the tap only builds its library. Apply the setting and rebuild/reinstall \
            the device app, or inject it when launching the simulator/macOS app, to capture future \
            output. Existing linked or running apps do not upgrade automatically. The current tap \
            labels stdout and stderr separately; older taps may report merged console output. \
            Confirm received entries and capture status with read/state before claiming coverage.
            """)
    }
}
