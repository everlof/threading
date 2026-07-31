import AppKit

struct BrowserViewportPreset: Equatable {
    let identifier: String
    let title: String
    let width: Int
    let height: Int

    var size: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    static let catalog = [
        BrowserViewportPreset(identifier: "4k", title: L10n.string("4K"), width: 2560, height: 1440),
        BrowserViewportPreset(
            identifier: "laptop-large",
            title: L10n.string("Laptop L"),
            width: 1440,
            height: 900
        ),
        BrowserViewportPreset(
            identifier: "laptop",
            title: L10n.string("Laptop"),
            width: 1024,
            height: 768
        ),
        BrowserViewportPreset(
            identifier: "surface-pro-7",
            title: L10n.string("Surface Pro 7"),
            width: 912,
            height: 1368
        ),
        BrowserViewportPreset(
            identifier: "ipad-air",
            title: L10n.string("iPad Air"),
            width: 820,
            height: 1180
        ),
        BrowserViewportPreset(
            identifier: "ipad-mini",
            title: L10n.string("iPad Mini"),
            width: 768,
            height: 1024
        ),
        BrowserViewportPreset(
            identifier: "surface-duo",
            title: L10n.string("Surface Duo"),
            width: 540,
            height: 720
        ),
        BrowserViewportPreset(
            identifier: "iphone-15-pro-max",
            title: L10n.string("iPhone 15 Pro Max"),
            width: 430,
            height: 932
        ),
        BrowserViewportPreset(
            identifier: "pixel-8",
            title: L10n.string("Pixel 8"),
            width: 412,
            height: 915
        ),
        BrowserViewportPreset(
            identifier: "iphone-15-pro",
            title: L10n.string("iPhone 15 Pro"),
            width: 393,
            height: 852
        ),
        BrowserViewportPreset(
            identifier: "galaxy-s24-ultra",
            title: L10n.string("Samsung Galaxy S24 Ultra"),
            width: 384,
            height: 824
        ),
        BrowserViewportPreset(
            identifier: "iphone-se",
            title: L10n.string("iPhone SE"),
            width: 375,
            height: 667
        )
    ]
}

/// The responsive browser strip: one shared state surface for preset and agent-driven viewports.
///
/// The controls stay app-owned and theme-aware while the exact size is applied to the live
/// WKWebView by `BrowserViewController`. Choosing or typing dimensions does not claim mobile,
/// touch, DPR, or device emulation; these are CSS viewport presets only.
final class BrowserDeviceToolbar: NSView, ThemedComponent, NSTextFieldDelegate {

    private enum Layout {
        static let fieldWidth: CGFloat = 68
        static let labelFoldThreshold: CGFloat = 680
        static let presetFoldThreshold: CGFloat = 500
        static let height = Design.Size.chipHeight + Design.Spacing.small * 2
    }

    let presetPopUp = ThemedPopUp()
    let widthField = ThemedTextField()
    let heightField = ThemedTextField()
    let rotateButton = ThemedButton(
        symbol: "rotate.right",
        accessibility: L10n.string("Rotate Viewport"),
        target: nil,
        action: nil
    )
    let closeButton = ThemedButton(
        symbol: "xmark",
        accessibility: L10n.string("Hide Device Toolbar"),
        target: nil,
        action: nil
    )

    var onChoosePreset: ((BrowserViewportPreset?) -> Void)?
    var onApplyCustomSize: ((Int, Int) -> Bool)?
    var onRotate: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let dimensionsLabel = NSTextField(labelWithString: L10n.string("Dimensions:"))
    private let multiplicationLabel = NSTextField(labelWithString: "×")
    private let stack: NSStackView
    private var themeRedraw: ThemeRedraw?
    private var currentSize = CGSize(width: 390, height: 844)
    private(set) var isPresetFolded = false

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [
            dimensionsLabel,
            presetPopUp,
            widthField,
            multiplicationLabel,
            heightField,
            rotateButton,
            closeButton
        ])
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Layout.height)
    }

    private func setup() {
        dimensionsLabel.applyFont(.control)
        dimensionsLabel.textColor = Design.Text.label
        multiplicationLabel.applyFont(.control)
        multiplicationLabel.textColor = Design.Text.secondary

        for field in [widthField, heightField] {
            field.alignment = .center
            field.applyFont(.numericControl())
            field.delegate = self
            field.target = self
            field.action = #selector(applyDimensions)
            field.setAccessibilityHelp(
                L10n.string("CSS pixels; press Return to apply")
            )
            field.widthAnchor.constraint(equalToConstant: Layout.fieldWidth).isActive = true
        }
        widthField.setAccessibilityLabel(L10n.string("Viewport Width"))
        heightField.setAccessibilityLabel(L10n.string("Viewport Height"))

        presetPopUp.setAccessibilityHelp(
            L10n.string("CSS viewport presets; no touch or device emulation")
        )
        presetPopUp.addItem(ThemedMenuItem(
            title: L10n.string("Responsive"),
            onChoose: { [weak self] in self?.onChoosePreset?(nil) }
        ))
        for preset in BrowserViewportPreset.catalog {
            presetPopUp.addItem(ThemedMenuItem(
                title: preset.title,
                subtitle: "\(preset.width)×\(preset.height)",
                onChoose: { [weak self] in self?.onChoosePreset?(preset) }
            ))
        }

        rotateButton.target = self
        rotateButton.action = #selector(rotateViewport)
        closeButton.target = self
        closeButton.action = #selector(dismiss)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.small,
            right: Design.Spacing.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
        setViewport(currentSize, preset: nil)
        setAccessibilityElement(false)
    }

    override func layout() {
        super.layout()
        dimensionsLabel.isHidden = bounds.width < Layout.labelFoldThreshold
        isPresetFolded = bounds.width < Layout.presetFoldThreshold
        presetPopUp.isHidden = isPresetFolded
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.background.setFill()
        bounds.fill()
    }

    func setViewport(_ size: CGSize, preset: BrowserViewportPreset?) {
        currentSize = size
        widthField.stringValue = "\(Int(size.width))"
        heightField.stringValue = "\(Int(size.height))"
        if let preset,
           let index = BrowserViewportPreset.catalog.firstIndex(of: preset) {
            presetPopUp.selectItem(at: index + 1)
        } else {
            presetPopUp.selectItem(at: 0)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        applyDimensions()
    }

    @objc private func applyDimensions() {
        guard let width = Int(widthField.stringValue),
              let height = Int(heightField.stringValue),
              onApplyCustomSize?(width, height) == true else {
            NSSound.beep()
            setViewport(currentSize, preset: nil)
            return
        }
    }

    @objc private func rotateViewport() {
        onRotate?()
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}
