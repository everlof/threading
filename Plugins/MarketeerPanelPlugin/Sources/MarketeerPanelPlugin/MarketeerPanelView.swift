import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// Marketeer's project, drawn natively.
///
/// The semantic-node panel this replaces could show three lines of `compactDetail` and one media
/// document, because a panel holds no disclosure and an image node is an icon slot. So the slides
/// were a contact sheet at a fifth of the pane each, and everything true about them — which slot,
/// which canvas, what is on them, whether they are uploaded — was compressed into a sentence.
///
/// Here a slide is a row: its real gradient, its slot, its contents, its upload state. The
/// information was always in `document.json`; what was missing was somewhere to put it.
@MainActor
final class MarketeerPanelView: NSView {

    private enum Metrics {
        /// A phone, small. Big enough that the slide's own composition reads — where the device
        /// sits, where the words are — and small enough that the row stays a row.
        static let swatchWidth: CGFloat = 62
        static let swatchHeight: CGFloat = 110
        static let messageWidth: CGFloat = 320
    }

    private let scroll = ThemedScrollView()
    private let column = NSStackView()
    /// Held because ThemedButton speaks target/action, and the target has to outlive the button.
    private let onRefresh: () -> Void

    /// Decoded artwork by slide `slotPosition`.
    ///
    /// Handed in rather than loaded here, so the view is state in and pixels out: it renders the
    /// same way every time, which is what makes the appearance testable at all. The decode is the
    /// entry point's job because it is file reading, and that belongs off this actor.
    private let thumbnails: [Int: CGImage]

    init(
        state: Result<MarketeerProject, MarketeerReadFailure>,
        thumbnails: [Int: CGImage] = [:],
        onRefresh: @escaping () -> Void
    ) {
        self.thumbnails = thumbnails
        self.onRefresh = onRefresh
        super.init(frame: .zero)
        wantsLayer = true

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.medium,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.medium,
            right: Design.Spacing.medium
        )

        switch state {
        case .success(let project): fill(with: project)
        case .failure(let failure): fill(with: failure, onRefresh: onRefresh)
        }

        // Flipped, because an unflipped document view puts its origin at the bottom left and the
        // scroll view then opens showing the *end* of the content. The pane was rendering with its
        // heading and first slide above the visible rect, which reads as missing content rather
        // than as a scroll position.
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(column)
        scroll.documentView = clip
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            // The document tracks the scroll view's width, so a row wraps rather than scrolling
            // sideways. Without this the stack takes its fitting width and every long line runs
            // off the edge with a horizontal scroller nobody wants.
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Content

    private func fill(with project: MarketeerProject) {
        column.addArrangedSubview(label(project.name, font: Design.Typography.heading(), color: Design.Text.label))

        if let app = project.appLink, let name = app.appName, !name.isEmpty {
            let identifier = [app.bundleID, app.appID].compactMap { $0 }.filter { !$0.isEmpty }
            column.addArrangedSubview(label(
                ([name] + identifier).joined(separator: " · "),
                font: Design.Typography.subheading(),
                color: Design.Text.secondary
            ))
        } else {
            column.addArrangedSubview(label(
                "No App Store app linked",
                font: Design.Typography.subheading(),
                color: Design.Text.tertiary
            ))
        }

        var facts: [String] = []
        let locales = project.localizations.map(\.localeCode).filter { !$0.isEmpty }
        if !locales.isEmpty { facts.append(locales.joined(separator: ", ")) }
        if let revision = project.revision { facts.append("revision \(revision)") }
        if let reason = project.changeReason, !reason.isEmpty { facts.append(reason) }
        if !facts.isEmpty {
            column.addArrangedSubview(label(
                facts.joined(separator: " · "),
                font: Design.Typography.caption(),
                color: Design.Text.tertiary
            ))
        }

        let slides = project.orderedSlides
        guard !slides.isEmpty else {
            column.addArrangedSubview(spacer())
            column.addArrangedSubview(label(
                "This project has no slides yet.",
                font: Design.Typography.body(),
                color: Design.Text.secondary
            ))
            return
        }

        column.addArrangedSubview(spacer())
        for slide in slides {
            column.addArrangedSubview(row(
                for: slide,
                hasExport: project.exports[slide.slotPosition] != nil,
                artwork: thumbnails[slide.slotPosition]
            ))
        }

        if project.hiddenSlideCount > 0 {
            column.addArrangedSubview(label(
                "\(project.hiddenSlideCount) further slides not shown",
                font: Design.Typography.caption(),
                color: Design.Text.tertiary
            ))
        }
    }

    @objc private func refreshTapped() { onRefresh() }

    private func fill(with failure: MarketeerReadFailure, onRefresh: @escaping () -> Void) {
        let message = NSTextField(wrappingLabelWithString: failure.description)
        message.font = Design.Typography.body()
        message.textColor = Design.Text.secondary
        message.translatesAutoresizingMaskIntoConstraints = false
        message.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.messageWidth).isActive = true
        column.addArrangedSubview(message)

        // The companion writes changes to disk and nothing pushes them here, so re-reading is the
        // whole update mechanism. That is a gap in the extension SDK rather than in this pane, and
        // it is recorded as one; until it closes, the button is honest about it.
        column.addArrangedSubview(ThemedButton(
            title: "Refresh",
            target: self,
            action: #selector(refreshTapped)
        ))
    }

    private func row(for slide: MarketeerSlide, hasExport: Bool, artwork: CGImage?) -> NSView {
        let swatch = SlideThumbnailView(slide: slide, artwork: artwork)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: Metrics.swatchWidth),
            swatch.heightAnchor.constraint(equalToConstant: Metrics.swatchHeight),
        ])

        var lines: [NSView] = []
        let slot = "Slot \(slide.slotPosition + 1)"
        let canvas = slide.canvasSizeID.isEmpty ? slot : "\(slot) · \(slide.canvasSizeID)\""
        lines.append(label(canvas, font: Design.Typography.caption(), color: Design.Text.tertiary))

        // The slide's own words, where there is room for them. They were drawn inside the
        // thumbnail first and truncated to "The real ter…" at 62 points wide, which is worse than
        // not showing them: the row has the whole pane's width and the thumbnail has none of it.
        if let title = slide.title {
            lines.append(label(title, font: Design.Typography.emphasizedBody(), color: Design.Text.label))
        } else {
            lines.append(label("Untitled slide", font: Design.Typography.emphasizedBody(), color: Design.Text.tertiary))
        }
        if let subtitle = slide.subtitle {
            lines.append(label(subtitle, font: Design.Typography.controlRegular(), color: Design.Text.secondary))
        }

        let state = slide.uploadedCount > 0 ? "uploaded ×\(slide.uploadedCount)" : "not uploaded"
        // Whether the thumbnail is the artwork or a drawing of it. Worth one word, because the two
        // look similar at row size and the difference decides whether what you are seeing has been
        // through the renderer.
        let source = hasExport ? "rendered" : "not rendered"
        lines.append(label(
            "\(slide.elementSummary) · \(state) · \(source)",
            font: Design.Typography.caption(),
            color: Design.Text.tertiary
        ))

        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight

        let row = NSStackView(views: [swatch, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.small
        return row
    }

    // MARK: - Theme

    func applyTheme() {
        layer?.backgroundColor = Design.Surface.ground.cgColor
        scroll.backgroundColor = Design.Surface.ground
        scroll.drawsBackground = true
    }

    // MARK: - Small helpers

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: Design.Spacing.tight).isActive = true
        return view
    }
}

// MARK: - The swatch

/// A slide, in miniature.
///
/// Drawn from the document rather than from an export: the gradient's stops and angle, the
/// device's placement, and the real title and subtitle in their real colours are all in
/// `document.json`. So this needs no render, no companion round trip and no repackage — which is
/// the difference the native pane buys. The semantic panel could only show pictures baked into the
/// extension bundle at build time, which is why re-framing without repackaging kept showing the
/// previous set.
///
/// It is a thumbnail and says so by being one: the gradient and the device's placement, and
/// nothing else. Someone deciding *which* slide to open is served by the composition here and the
/// wording in the row beside it; someone judging typography opens the editor.
private final class SlideThumbnailView: NSView {

    private enum Metrics {
        /// Fractions of the thumbnail, so the miniature scales with the row rather than carrying
        /// its own pixel sizes.
        static let deviceCornerFraction: CGFloat = 0.10
        static let deviceWidthFraction: CGFloat = 0.62
    }

    private let slide: MarketeerSlide
    /// The exported artwork, already decoded, or `nil` for a slide nobody has rendered.
    private let artwork: CGImage?

    init(slide: MarketeerSlide, artwork: CGImage?) {
        self.slide = slide
        self.artwork = artwork
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = Design.Radius.control
        let clip = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        clip.addClip()

        // The artwork, once it is here. It replaces the drawing rather than sitting on top of it:
        // an export *is* the slide, and compositing our approximation underneath would show
        // through wherever the render is transparent.
        if let artwork {
            context.draw(artwork, in: aspectFilled(artwork))
            return
        }

        drawBackground(in: context)
        for element in slide.drawnElements {
            switch element.kind {
            case "device": draw(device: element)
            // Text is deliberately not drawn here. See the row: at this width a real title
            // truncates to three words and an ellipsis, which looks like a defect rather than a
            // miniature. The thumbnail carries the composition; the row carries the words.
            default: break
            }
        }
    }

    private func drawBackground(in context: CGContext) {
        guard let gradient = slide.background?.gradient else {
            // A style this build does not draw is still a slide. A flat field says "there is a
            // background and it is not one of ours" rather than pretending the slide is empty.
            Design.Surface.field.setFill()
            bounds.fill()
            return
        }
        let colors = [color(gradient.startColor).cgColor, color(gradient.endColor).cgColor]
        guard let ramp = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return }

        // The document's angle is degrees clockwise from straight up, which is how a designer
        // names it. Core Graphics wants two points, and the view's origin is bottom left.
        let radians = (gradient.angle - 90) * .pi / 180
        let dx = cos(radians) * bounds.width / 2
        let dy = -sin(radians) * bounds.height / 2
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        context.drawLinearGradient(
            ramp,
            start: CGPoint(x: middle.x - dx, y: middle.y - dy),
            end: CGPoint(x: middle.x + dx, y: middle.y + dy),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private func draw(device element: MarketeerElement) {
        let width = bounds.width * Metrics.deviceWidthFraction * CGFloat(element.scale)
        let height = width * 2.16      // a phone, roughly
        let rect = NSRect(
            x: bounds.width * CGFloat(element.x) - width / 2,
            y: flipped(element.y) - height / 2,
            width: width,
            height: height
        )
        let radius = width * Metrics.deviceCornerFraction
        let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(white: 0, alpha: 0.34).setFill()
        body.fill()
        NSColor(white: 1, alpha: 0.28).setStroke()
        body.lineWidth = 1
        body.stroke()
    }

    /// A screenshot is taller than the row, so it fills the width and is centred vertically —
    /// cropping the middle of a slide rather than letterboxing it, which is what a contact sheet
    /// of phone screenshots wants.
    private func aspectFilled(_ image: CGImage) -> CGRect {
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let boundsAspect = bounds.width / bounds.height
        if imageAspect > boundsAspect {
            let width = bounds.height * imageAspect
            return CGRect(x: bounds.midX - width / 2, y: 0, width: width, height: bounds.height)
        }
        let height = bounds.width / imageAspect
        return CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    /// The document measures `y` from the top; this view's origin is the bottom left.
    private func flipped(_ y: Double) -> CGFloat {
        bounds.height * (1 - CGFloat(y))
    }

    private func color(_ value: MarketeerColor) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.opacity)
    }
}

/// A document view whose origin is the top left, which is what a vertical list wants.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
