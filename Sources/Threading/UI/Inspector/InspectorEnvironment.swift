import AppKit

// MARK: - Inspector Environment

/// What the app was wearing when a capture was made: version, both themes, whether the window
/// draws its own frame, the window's metrics, and the type settings that decide how much room
/// every label needs.
///
/// The report beside this one says *where* a view drew and *what* drew it. Neither it nor the
/// screenshot says *under what*, and that is most of the answer to a layout complaint: the same
/// row is clipped under one theme and correct under three, two controls overlap only at the
/// largest text size, and a chrome-takeover theme replaces the entire window frame the
/// measurements were taken against. A reader who cannot ask — a maintainer months later, an
/// agent handed a pasted report — has no way to recover any of it.
///
/// The scale earns its line for a different reason: the report speaks points, and the PNG beside
/// it is pixels. On a retina window every number in the report is half the number an agent
/// measuring the image will count, and nothing in either artefact said so.
///
/// **Nothing here is text the user typed.** A capture may leave this window in a copied report or
/// through the private developer inbox, so every value is a choice from a fixed catalogue: a
/// stock theme's name, a named text size, a font family installed on the machine. A theme the user
/// made and named is reported as `custom` rather than by its name. This type opens with the shared
/// private-report environment line so the uploaded and copied reports agree about their origin.
struct InspectorEnvironment {

    // MARK: - Properties

    /// Version, build and macOS, in the words every report from this app already closes
    /// with.
    let build: String

    let theme: Theme

    /// The terminal in view: what it draws with, and what it is set in. Absent when no session
    /// is showing.
    let terminal: Terminal?

    let window: Window

    let textSize: AppTextSize

    /// The families the user chose, when they chose any. Absent means the theme's own — which is
    /// the common case, and a line saying "the default" is a line nobody reads.
    let chromeFontFamily: String?
    let conversationFontFamily: String?

    /// The display accommodations that are switched on. Empty prints nothing.
    let accommodations: [String]

    /// The language the interface is drawing in, when it is not the one the source strings are
    /// written in. A label that fits in English and not in German is a translation bug, and the
    /// screenshot is the only place that would otherwise have said so.
    let language: String?

    // MARK: - Nested Types

    struct Theme {
        /// A stock or extension-contributed theme's name; `custom` for one the user made.
        let name: String

        /// What the theme states: `adaptive`, `light` or `dark`.
        let mode: String

        /// What it resolves to on this window right now. Equal to `mode` for a fixed theme.
        let appearance: String

        /// Whether the window is wearing the theme's own frame instead of AppKit's. Read from the
        /// window rather than from the theme: an exchange parked by fullscreen means the theme
        /// asks for a frame the window is not yet wearing, and the report describes the window
        /// the screenshot shows.
        let drawsWindowChrome: Bool
    }

    struct Terminal {
        /// The resolved palette: a built-in one by name, `custom` for one the user made.
        let paletteName: String

        /// Which scope chose it, since "the session's own" and "inherited from the default" send
        /// a reader to different settings.
        let scope: ThemeScope

        /// Family and point size, which no other line covers: the terminal keeps its own font
        /// through `TerminalProfile` rather than following the chrome's, so the text in the
        /// pane the report is usually about is sized by a setting nothing else here states.
        let font: String
    }

    struct Window {
        let size: NSSize
        let backingScale: CGFloat
        let isFullScreen: Bool
    }

    // MARK: - Capture

    @MainActor
    static func capture(
        window: NSWindow?,
        sessionID: SessionID?,
        info: [String: Any]? = Bundle.main.infoDictionary
    ) -> InspectorEnvironment {
        let appearance = window?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance

        return InspectorEnvironment(
            build: DeveloperIssueReportComposer.environment(info: info),
            theme: currentTheme(in: window, appearance: appearance),
            terminal: terminalInView(for: sessionID),
            window: Window(
                size: window?.frame.size ?? .zero,
                backingScale: window?.backingScaleFactor ?? 1,
                isFullScreen: window?.styleMask.contains(.fullScreen) ?? false
            ),
            textSize: AppSettings.appTextSize,
            chromeFontFamily: AppSettings.chromeFontFamily,
            conversationFontFamily: AppSettings.conversationFontFamily,
            accommodations: accommodations(),
            language: interfaceLanguage()
        )
    }

    // MARK: - Rendering

    /// One bullet per fact, in the order a reader triages them: which build, then what it looked
    /// like, then how big everything was asked to be.
    var lines: [String] {
        var lines = ["- \(build)"]
        lines.append("- App theme: \(themeDescription)")
        lines.append(
            "- Window chrome: "
                + (theme.drawsWindowChrome ? "drawn by the theme" : "the native frame")
        )
        lines.append("- Window: \(windowDescription)")

        if let terminal {
            lines.append(
                "- Terminal theme: \(terminal.paletteName), \(scopeDescription(terminal.scope))"
            )
            lines.append("- Terminal font: \(terminal.font)")
        }

        lines.append("- Text size: \(textSizeDescription)")

        if let chromeFontFamily {
            lines.append("- Chrome font: \(chromeFontFamily)")
        }
        if let conversationFontFamily {
            lines.append("- Conversation font: \(conversationFontFamily)")
        }
        if !accommodations.isEmpty {
            lines.append("- Display settings: " + accommodations.joined(separator: ", "))
        }
        if let language {
            lines.append("- Interface language: \(language)")
        }

        return lines
    }

    var markdown: String { lines.joined(separator: "\n") }

    // MARK: - Private Methods

    /// An adaptive theme is two answers — what it states and what that came out as — and a fixed
    /// theme is one. Saying "dark, drawing dark" twice is how a line stops being read.
    private var themeDescription: String {
        theme.mode == theme.appearance
            ? "\(theme.name), \(theme.mode)"
            : "\(theme.name), \(theme.mode), drawing \(theme.appearance)"
    }

    private var windowDescription: String {
        var description = InspectorGeometry.describe(window.size)
            + " at \(InspectorEnvironment.describe(scale: window.backingScale))"
        if window.isFullScreen { description += ", full screen" }
        return description
    }

    private var textSizeDescription: String {
        guard textSize.scale != 1 else { return textSize.rawValue }
        return "\(textSize.rawValue), \(InspectorEnvironment.describe(scale: textSize.scale))"
    }

    private func scopeDescription(_ scope: ThemeScope) -> String {
        switch scope {
        case .session: return "set on this session"
        case .project: return "set on the project"
        case .global: return "the default"
        }
    }

    /// `2×` rather than `2.0×`, because a whole number written as a decimal reads as a
    /// measurement that happened to land there.
    private static func describe(scale: CGFloat) -> String {
        "\(describe(size: scale))×"
    }

    private static func describe(size: CGFloat) -> String {
        let rounded = (size * 100).rounded() / 100
        guard rounded != rounded.rounded() else { return "\(Int(rounded))" }
        return "\(rounded)"
    }

    // MARK: - Capture Helpers

    @MainActor
    private static func currentTheme(in window: NSWindow?, appearance: NSAppearance) -> Theme {
        let theme = AppThemePalette.current

        return Theme(
            name: AppThemeLibrary.isCustom(theme) ? customName : theme.name,
            mode: theme.mode.appearanceName,
            appearance: AppTheme.VariantKind.current(in: appearance).rawValue,
            // The absence of `.titled` is what takeover *is*, and it is also how
            // `WindowChromeCoordinator` recognises its own state on a window it did not create.
            drawsWindowChrome: window.map { !$0.styleMask.contains(.titled) }
                ?? theme.takesOverWindowChrome
        )
    }

    @MainActor
    private static func terminalInView(for sessionID: SessionID?) -> Terminal? {
        guard let sessionID,
              let assignment = ThemeAssignments.resolution(for: sessionID) else { return nil }

        let profile = ProfileStorage.shared.defaultProfile
        let font = "\(profile.fontName) \(describe(size: profile.fontSize))"

        // The dynamic entry resolves to whatever the app theme carries, so naming the palette
        // would name the app theme twice — and, for a custom one, name it at all.
        if assignment.themeID == .followsAppTheme {
            return Terminal(
                paletteName: "follows the app theme",
                scope: assignment.scope,
                font: font
            )
        }

        guard let palette = ThemeManager.shared.theme(withID: assignment.themeID) else {
            return nil
        }

        return Terminal(
            paletteName: ThemeManager.shared.isBuiltIn(palette) ? palette.name : customName,
            scope: assignment.scope,
            font: font
        )
    }

    /// Named once: what every user-authored palette is called in a report, whichever kind it is.
    private static let customName = "custom"

    private static func accommodations() -> [String] {
        let workspace = NSWorkspace.shared
        var settings: [String] = []
        if workspace.accessibilityDisplayShouldReduceMotion { settings.append("reduced motion") }
        if workspace.accessibilityDisplayShouldIncreaseContrast {
            settings.append("increased contrast")
        }
        if workspace.accessibilityDisplayShouldReduceTransparency {
            settings.append("reduced transparency")
        }
        if workspace.accessibilityDisplayShouldDifferentiateWithoutColor {
            settings.append("differentiate without colour")
        }
        return settings
    }

    private static func interfaceLanguage(bundle: Bundle = .main) -> String? {
        guard let language = bundle.preferredLocalizations.first,
              language != bundle.developmentLocalization else { return nil }
        return language
    }
}
