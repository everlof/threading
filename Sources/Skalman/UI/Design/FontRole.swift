import AppKit
import ObjectiveC

// MARK: - The recipe

extension Design {

    /// A font stated as the *decision* that produced it, so the decision can be taken again.
    ///
    /// `NSFont` freezes exactly the way a `CGColor` on a layer does: a label keeps the object it
    /// was handed, and the theme sweep re-resolves colours, not fonts. So the answer is the one
    /// `RecordedSurface` already gives for fills — record what was asked for, and ask again after
    /// a live switch.
    ///
    /// **Tagging the font was tried first and cannot work.** Three things were measured on macOS
    /// 26 before this shape was chosen, and each rules out an approach that needs no call-site
    /// change:
    ///
    /// - `NSFont` **strips unknown descriptor attributes**. A custom `skalmanFontRole` attribute
    ///   added to a descriptor is gone the moment `NSFont(descriptor:size:)` builds the font, so
    ///   a font cannot carry its own role.
    /// - Under a `.monospaced` theme a prose font and a code font are **byte-identical** —
    ///   `.systemFont(13).withDesign(.monospaced) == .monospacedSystemFont(13)` is `true`, same
    ///   `fontName` — so nothing recoverable from the font tells "the theme is mono" from "this
    ///   is code". (Prose *is* separable from numeric, which carries a monospaced-digit feature
    ///   setting; that one clue is not enough on its own.)
    /// - A user override family removes even the family as a clue: once the chrome is set in
    ///   Helvetica, every prose font is Helvetica and classifying by family classifies nothing.
    ///
    /// It is a recipe rather than a category because re-deriving needs the whole call: a
    /// `detail(weight: .medium)` has to come back medium.
    enum FontRole: Equatable {

        // Prose — follows the theme's typeface.
        case heading
        case placeholderTitle
        case subheading
        case body
        case emphasizedBody
        case strongBody
        case control
        case controlRegular
        case caption
        case detail(weight: NSFont.Weight = .regular)
        case markdownHeading(base: CGFloat)

        // Code — monospaced under every typeface.
        case code(weight: NSFont.Weight = .regular)
        case inlineCode
        case previewCode
        case compactCode
        case compactToolName

        // Numeric — SF's monospaced digits, so columns keep aligning.
        case numericBody
        case numericControl
        case numericDetail(weight: NSFont.Weight = .regular)

        // Marks, not prose.
        case accountEmoji
        case emojiPickerCell

        /// The font this role resolves to under the theme and overrides in force *now*.
        ///
        /// Every branch routes through `Design.Typography`, which stays the app's only font
        /// factory — this enum names calls, it does not make fonts. The surface is passed to the
        /// prose factories only: code, numerics and marks do not vary by surface any more than
        /// they vary by theme.
        func resolved(in surface: Typography.FontSurface = .chrome) -> NSFont {
            switch self {
            case .heading: return Typography.heading(surface: surface)
            case .placeholderTitle: return Typography.placeholderTitle(surface: surface)
            case .subheading: return Typography.subheading(surface: surface)
            case .body: return Typography.body(surface: surface)
            case .emphasizedBody: return Typography.emphasizedBody(surface: surface)
            case .strongBody: return Typography.strongBody(surface: surface)
            case .control: return Typography.control(surface: surface)
            case .controlRegular: return Typography.controlRegular(surface: surface)
            case .caption: return Typography.caption(surface: surface)
            case .detail(let weight): return Typography.detail(weight: weight, surface: surface)
            case .markdownHeading(let base):
                return Typography.markdownHeading(fromPointSize: base, surface: surface)
            case .code(let weight): return Typography.code(weight: weight)
            case .inlineCode: return Typography.inlineCode()
            case .previewCode: return Typography.previewCode()
            case .compactCode: return Typography.compactCode()
            case .compactToolName: return Typography.compactToolName()
            case .numericBody: return Typography.numericBody()
            case .numericControl: return Typography.numericControl()
            case .numericDetail(let weight): return Typography.numericDetail(weight: weight)
            case .accountEmoji: return Typography.accountEmoji()
            case .emojiPickerCell: return Typography.emojiPickerCell()
            }
        }

        /// Whether a live theme switch can change this role's answer.
        ///
        /// Only prose moves today. The sweep re-resolves every recorded role regardless and
        /// compares before assigning, so this is documentation and a cheap skip rather than a
        /// correctness gate — and it stays correct if Tier 3's override later reaches code.
        var followsTheme: Bool {
            switch self {
            case .heading, .placeholderTitle, .subheading, .body, .emphasizedBody, .strongBody,
                 .control, .controlRegular, .caption, .detail, .markdownHeading:
                return true
            case .code, .inlineCode, .previewCode, .compactCode, .compactToolName,
                 .numericBody, .numericControl, .numericDetail, .accountEmoji, .emojiPickerCell:
                return false
            }
        }
    }
}

// MARK: - Applying a role

/// A view that holds one font the design system vended.
///
/// Conformance is what the sweep looks for, so a view type that shows app text joins by
/// declaring how it takes a font — not by remembering to observe a notification. The failure
/// mode of the latter is one label in the corner still set in the previous theme, which is the
/// kind of bug nobody notices until a screenshot.
/// Deliberately not `@MainActor`: the assignment it replaces was not, and `PreferencesFormBuilder`
/// builds its labels from nonisolated methods. Annotating the protocol would push the isolation
/// out to those call sites, which is a concurrency change rather than a typeface one.
protocol FontRoleApplying: NSView {
    /// The font currently in force, so the sweep can skip an assignment that changes nothing.
    var appliedRoleFont: NSFont? { get }
    func applyRoleFont(_ font: NSFont)
}

extension NSTextField: FontRoleApplying {
    var appliedRoleFont: NSFont? { font }
    func applyRoleFont(_ font: NSFont) { self.font = font }
}

extension NSTextView: FontRoleApplying {
    var appliedRoleFont: NSFont? { font }

    /// Assigning `font` sets it across the whole text, which is right for the plain-text views
    /// this app records a role on (the composer, the report pane) and would flatten an
    /// attributed one. A view holding built attributed content is rebuilt on a theme change
    /// instead — see `AppThemeRefresh`.
    func applyRoleFont(_ font: NSFont) { self.font = font }
}

extension MorphingTitleLabel: FontRoleApplying {
    var appliedRoleFont: NSFont? { font }
    func applyRoleFont(_ font: NSFont) { self.font = font }
}

/// A drawn control still needs this when a call site *overrides* its font.
///
/// `ThemedButton` reads `Design.Typography` inside `draw(_:)` and follows a theme switch for free
/// — but only while its `font` is nil. The four call sites that set one (an emoji sized as a
/// mark, a caption-scale action) freeze it exactly like a label does, which is the same bug in
/// the one place the drawn-controls-are-free rule looks like it does not apply.
extension ThemedButton: FontRoleApplying {
    var appliedRoleFont: NSFont? { font }
    func applyRoleFont(_ font: NSFont) { self.font = font }
}

private var recordedFontRoleKey: UInt8 = 0

extension NSView {

    fileprivate var recordedFont: FontRoleBox? {
        get { objc_getAssociatedObject(self, &recordedFontRoleKey) as? FontRoleBox }
        set { objc_setAssociatedObject(self, &recordedFontRoleKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Re-resolves the recorded role and assigns it if the answer moved.
    ///
    /// Called by the app-theme sweep for every view in the tree. A view with no recorded role —
    /// a stock font someone set, the terminal's own font, an image view — is left alone.
    func reapplyRecordedFont() {
        guard let recorded = recordedFont, let target = self as? FontRoleApplying else { return }
        let updated = recorded.role.resolved(in: recorded.surface)
        guard target.appliedRoleFont != updated else { return }
        target.applyRoleFont(updated)
        // A font change moves the text's measured size, and the views that show these are laid
        // out by Auto Layout from `intrinsicContentSize`. Without this a sidebar row keeps the
        // previous typeface's width and truncates the new one.
        invalidateIntrinsicContentSize()
    }

    /// The re-apply on its own, for the test that pins the freeze this exists to fix. The sweep
    /// itself walks a window, which a unit test has no business standing up.
    func reapplyRecordedFontForTesting() {
        reapplyRecordedFont()
    }

    /// The role this view was last given, for tests and for the sweep's own diagnostics.
    var recordedFontRoleForTesting: Design.FontRole? { recordedFont?.role }
    var recordedFontSurfaceForTesting: Design.Typography.FontSurface? { recordedFont?.surface }
}

extension FontRoleApplying {

    /// Sets the font this role resolves to, and records the role so a live theme switch — or a
    /// change to the user's font overrides — can take the decision again.
    ///
    /// This is the assignment the app uses instead of `label.font = Design.Typography.body()`.
    /// The direct form still compiles and still looks right — it simply stops following the
    /// theme, which is invisible until someone switches one.
    ///
    /// `surface` is `.chrome` for everything the app draws about itself. The conversation passes
    /// `.conversation`, so the thread can be set in the reader's own font the way the terminal
    /// beside it already can.
    func applyFont(_ role: Design.FontRole, in surface: Design.Typography.FontSurface = .chrome) {
        recordedFont = FontRoleBox(role, surface)
        let font = role.resolved(in: surface)
        guard appliedRoleFont != font else { return }
        applyRoleFont(font)
        invalidateIntrinsicContentSize()
    }
}

/// Associated objects hold Objective-C references, and `FontRole` is a Swift enum with payloads.
private final class FontRoleBox {
    let role: Design.FontRole
    let surface: Design.Typography.FontSurface

    init(_ role: Design.FontRole, _ surface: Design.Typography.FontSurface) {
        self.role = role
        self.surface = surface
    }
}
