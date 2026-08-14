import AppKit

/// The play/pause, scrubber and elapsed reading a host-owned media player wears.
///
/// Composed from `ThemedIconButton`, `ThemedScrubber` and the numeric font role rather than
/// assembled per player, because a transport is a vocabulary item: every document format the
/// renderer registry carries gets the same control in the same place with the same keyboard and
/// VoiceOver behaviour, and a second player cannot invent a slightly different one.
///
/// **The times are monospaced digits on purpose.** A proportional readout re-lays out on almost
/// every tick — `0:09` to `0:10` changes width — which moves the scrubber under the pointer that
/// is dragging it. `numericDetail` keeps the columns still.
///
/// The view owns no clock. It states what it was told and raises what the user did; the player
/// behind it decides what that means. That split is what lets a bitmap session and an
/// engine-native layer wear the same transport.
final class MediaTransportView: NSView, ThemedComponent {

    // MARK: - Geometry

    enum Layout {
        /// Wide enough for `-:--` through `9:59:59` without the row re-flowing when a document
        /// crosses an hour: the readout is one field, so it takes the widest reading it can hold.
        static let readoutWidth: CGFloat = 96
        static let height: CGFloat = 28
    }

    // MARK: - State

    /// What the glyph says. Assigning does not raise `onPlayPause`: the player states its phase
    /// here, and a control that echoed its own assignment would toggle itself.
    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            applyPlaybackGlyph()
        }
    }

    /// `0…1`. Ignored while the user is scrubbing, so a state report arriving mid-drag cannot
    /// pull the knob out from under the pointer — the single most common defect in a transport
    /// driven by a player that also reports position.
    var progress: Double = 0 {
        didSet {
            guard !scrubber.isScrubbing else { return }
            scrubber.value = min(max(progress, 0), 1)
            updateReadout()
        }
    }

    /// The document's length in seconds. Zero or non-finite means unknown, which the readout says
    /// with a dash rather than with `0:00` — a document whose duration has not been parsed yet is
    /// not a zero-length one.
    ///
    /// Named for the document rather than called `duration` on purpose: a bare `duration` is the
    /// name the design system reserves for an *animation's* duration, and the boundary lint reads
    /// every `.duration` assignment as one that should have come from `Design.Motion`. Content
    /// length is not motion the app chose.
    var documentDuration: Double = 0 {
        didSet { updateReadout() }
    }

    var isEnabled: Bool = true {
        didSet {
            playButton.isEnabled = isEnabled
            scrubber.isEnabled = isEnabled
        }
    }

    var onPlayPause: (() -> Void)?
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: ((Double) -> Void)?

    // MARK: - Controls

    private let playButton = ThemedIconButton(
        symbolName: "play.fill",
        accessibility: L10n.string("Play"),
        target: .inline,
        inkSource: .chrome
    )
    private let scrubber = ThemedScrubber(frame: .zero)
    private let readout = NSTextField(labelWithString: "")
    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("media.transport")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Playback"))
        themeRedraw = ThemeRedraw(self)

        // `onPress` rather than target/action: a `ThemedIconButton` draws itself and routes its
        // press through this closure, so a control wired the AppKit way is a button nothing
        // happens on.
        playButton.onPress = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.onPlayPause?()
        }

        scrubber.setAccessibilityLabel(L10n.string("Playback position"))
        scrubber.onChange = { [weak self] value in
            self?.updateReadout(overridingProgress: value)
            self?.onScrub?(value)
        }
        scrubber.onScrubEnd = { [weak self] value in
            self?.onScrubEnd?(value)
        }

        readout.applyFont(.numericDetail())
        readout.textColor = Design.Text.secondary
        readout.alignment = .right
        readout.lineBreakMode = .byClipping
        readout.setAccessibilityIdentifier("media.transport.readout")

        let stack = NSStackView(views: [playButton, scrubber, readout])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.height),
            readout.widthAnchor.constraint(equalToConstant: Layout.readoutWidth)
        ])
        // The scrubber is the part that grows; the button and readout state their own widths.
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrubber.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readout.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        applyPlaybackGlyph()
        updateReadout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Testing seams

    var scrubberForTesting: ThemedScrubber { scrubber }
    var playButtonForTesting: ThemedIconButton { playButton }
    var readoutTextForTesting: String { readout.stringValue }

    // MARK: - Presentation

    private func applyPlaybackGlyph() {
        playButton.setSymbol(
            isPlaying ? "pause.fill" : "play.fill",
            accessibility: isPlaying ? L10n.string("Pause") : L10n.string("Play")
        )
    }

    /// The readout follows the *knob*, not the last state report, so a drag reads out the
    /// position it is about to commit rather than the one it left.
    private func updateReadout(overridingProgress override: Double? = nil) {
        let fraction = override ?? (scrubber.isScrubbing ? scrubber.value : progress)
        let total = documentDuration.isFinite && documentDuration > 0 ? documentDuration : nil
        let elapsed = total.map { $0 * min(max(fraction, 0), 1) }
        let text = "\(Self.timestamp(elapsed)) / \(Self.timestamp(total))"
        readout.stringValue = text
        scrubber.spokenValue = text
        setAccessibilityValue(text)
    }

    /// `m:ss`, growing to `h:mm:ss` only when there is an hour to show. Nil reads as a dash,
    /// because an unknown duration is not zero.
    static func timestamp(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainder = whole % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
