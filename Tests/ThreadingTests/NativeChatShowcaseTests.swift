import AppKit
import XCTest
@testable import Threading

/// A bounded review script in the shipping virtualized conversation controller. Every state
/// has its own ID because a blocked turn cannot also demonstrate a later successful answer.
@MainActor
final class NativeChatShowcaseTests: XCTestCase {
    enum Scene: String, CaseIterable {
        case answer, working, permission, usage, interrupted, streaming, question, questionSelected, expandedWork, longMessage
        case threadingTool = "threading-tool"
    }

    static let reply = """
    ## A calmer chat
    The transcript keeps **your request** and the **answer** easy to find. Work stays available
    in the disclosure above, including commands, results and the exact edit.

    | Component | Behavior |
    | --- | --- |
    | Messages | Select and copy text |
    | Code | Syntax highlighting and copy |
    | Work | Expand to inspect each step |

    ```swift
    func greeting(for name: String) -> String {
        "Hello, \\(name)!"
    }
    ```

    See the [interaction notes](https://www.assistant-ui.com/docs) for the source research.
    """

    static func fixture(_ scene: Scene, width: CGFloat = 900, height: CGFloat = 780)
        -> (ConversationViewController, NSView) {
        let session = AgentSession(kind: .codex, title: "Chat review", usesNativeUI: true)
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(name: "Chat review", folderURL: URL(fileURLWithPath: NSTemporaryDirectory())),
            customizationLookup: { _ in .empty }
        )
        controller.isVisible = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        host.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        controller.isReplaying = true
        func emit(_ event: StreamEvent) {
            for change in controller.timeline.apply(event) { controller.apply(change) }
        }
        emit(.userMessage(scene == .longMessage
            ? "Please investigate this log:\n" + (1...20).map { "Line \($0): greeting rendered without its expected name" }.joined(separator: "\n")
            : "Polish the greeting and show me how the chat feels."))
        emit(.assistantMessage(blocks: [
            .thinking("I’ll check the existing greeting, make a small edit, then run the focused tests."),
            .toolUse(id: "read-greeting", tool: .read, input: ["file_path": "Sources/Greeting.swift"]),
            .toolUse(id: "edit-greeting", tool: .edit, input: [
                "file_path": "Sources/Greeting.swift", "old_string": "\"Hi\"", "new_string": "\"Hello!\""
            ])
        ]))
        emit(.toolResults([
            ToolResult(toolUseID: "read-greeting", text: "func greeting() -> String { \"Hi\" }", isError: false),
            ToolResult(toolUseID: "edit-greeting", text: "Updated Sources/Greeting.swift", isError: false)
        ]))
        if scene == .threadingTool {
            emit(.assistantMessage(blocks: [.text("The edit is ready. I’ll inspect the Simulator.")]))
            emit(.assistantMessage(blocks: [
                .toolUse(
                    id: "simulator-capture",
                    tool: .mcp("mcp__threading__simulator_screenshot"),
                    input: ["include_image": .bool(true)]
                )
            ]))
            emit(.toolResults([
                ToolResult(toolUseID: "simulator-capture", text: "Captured current Simulator frame.", isError: false)
            ]))
        }
        if scene == .answer {
            emit(.assistantMessage(blocks: [.text(reply)]))
            emit(.turnFinished(text: nil, outcome: .completed, metrics: TurnMetrics(duration: 42)))
        } else if scene == .interrupted {
            emit(.turnFinished(text: nil, outcome: .stopped, metrics: TurnMetrics(duration: 12)))
        }
        controller.isReplaying = false
        controller.finishReplayRendering()
        if [.working, .permission, .streaming, .question, .questionSelected, .expandedWork, .longMessage, .threadingTool].contains(scene) {
            controller.apply(.status(.working(word: "Working…")))
        }
        if scene == .working {
            controller.apply(.runProgress(RunProgress(steps: [
                .init(id: nil, title: "Inspect the greeting", status: .completed),
                .init(id: nil, title: "Refine the copy", status: .completed),
                .init(id: nil, title: "Run the focused tests", status: .inProgress)
            ])))
        }
        if scene == .expandedWork {
            _ = controller.scrollToTimelineRow(3, animated: false)
            controller.view.layoutSubtreeIfNeeded()
            func expand(in view: NSView) {
                if let tool = view as? ToolCallView { tool.setExpanded(true) }
                for child in view.subviews { expand(in: child) }
            }
            expand(in: controller.view)
        }
        if scene == .permission {
            controller.isTurnInFlight = true
            controller.presentPermission(PermissionRequest(
                sessionID: session.id, toolName: "Bash",
                input: ["command": "touch .build/chat-review-marker"]
            )) { _ in }
        } else if scene == .usage {
            controller.handleExit(1)
            controller.applyLimitEscapeOffer(.init(
                offersWaitForReset: true, resetHint: "12:40am (Europe/Stockholm)"
            ))
        } else if scene == .streaming {
            controller.apply(.streaming(Self.reply))
        } else if scene == .question || scene == .questionSelected {
            if let request = ConversationQuestionRequest.codex(ConversationQuestionTests.parameters) {
                controller.presentQuestion(request) { _ in }
                if scene == .questionSelected, let card = controller.questionCards[request.id] {
                    func select(in view: NSView) {
                        if let button = view as? ConversationChoiceRow,
                           button.accessibilityIdentifier() == "conversation.question.option.density.0" {
                            _ = button.accessibilityPerformPress()
                        }
                        for child in view.subviews { select(in: child) }
                    }
                    select(in: card)
                }
            }
        }
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        controller.scrollToBottom()
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    func testRendersNativeChatShowcase() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "/ThreadingRenders"
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = AppThemePalette.current
        let originalAppearance = NSApp.appearance
        let motion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            NSApp.appearance = originalAppearance
            AppThemePalette.set(original)
            Design.Motion.reduceMotionOverrideForTesting = motion
        }
        Design.Motion.reduceMotionOverrideForTesting = true
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk, AppThemeStyles.swissMinimalist] {
            AppThemePalette.set(theme)
            let appearances: [NSAppearance.Name] = theme.isAdaptive ? [.aqua, .darkAqua]
                : [theme.mode == .dark ? .darkAqua : .aqua]
            for name in appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                NSApp.appearance = appearance
                for scene in Scene.allCases {
                    let widths: [CGFloat] = [.question, .permission].contains(scene) ? [900, 480] : [900]
                    for width in widths {
                        var data: Data?
                        appearance.performAsCurrentDrawingAppearance {
                            let (controller, host) = Self.fixture(scene, width: width)
                            host.appearance = appearance
                            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                data = bitmap.representation(using: .png, properties: [:])
                            }
                            controller.terminate()
                        }
                        let suffix = name == .aqua ? "light" : "dark"
                        try XCTUnwrap(data).write(to: directory.appendingPathComponent(
                            "native-chat-\(scene.rawValue)\(width == 900 ? "" : "-compact")-\(theme.id.rawValue)-\(suffix).png"
                        ))
                    }
                }
            }
        }
    }
}
