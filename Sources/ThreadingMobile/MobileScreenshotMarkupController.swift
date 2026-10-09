import PencilKit
import UIKit

/// A single image, capped at 2,048 pixels on its long edge before mounting. The logical canvas
/// never changes size on rotation, so ink stays attached to the same pixels. Export is bounded
/// background work; Cancel leaves the composer's original attachment untouched.
@MainActor
final class MobileScreenshotMarkupController: UIViewController {
    private let source: UIImage
    private let theme: RemoteThemePalette
    private let apply: (Data) -> Void
    private let paper = UIView()
    private let canvas = PKCanvasView()
    private let picker = PKToolPicker()
    private var image: UIImage?
    private var preparation: Task<Void, Never>?
    private let status = UILabel()

    init(image: UIImage, theme: RemoteThemePalette, apply: @escaping (Data) -> Void) {
        source = image
        self.theme = theme
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = MobileL10n.string("Mark up image")
        view.backgroundColor = theme.uiGround
        view.tintColor = theme.uiAccent
        overrideUserInterfaceStyle = theme.colorScheme == .light ? .light : .dark
        navigationController?.navigationBar.tintColor = theme.uiAccent
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = theme.uiSurface
        appearance.titleTextAttributes = [.foregroundColor: theme.uiLabel]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: MobileL10n.string("Cancel"), primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: MobileL10n.string("Apply"), primaryAction: UIAction { [weak self] _ in self?.export() }
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
        status.text = MobileL10n.string("Preparing image…")
        status.textColor = theme.uiSecondaryLabel
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        preparation = Task { [weak self, source] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.boundedImage(source)
            }.value
            guard !Task.isCancelled, let self else { return }
            mount(image)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        preparation?.cancel()
        picker.setVisible(false, forFirstResponder: canvas)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if image != nil {
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let image else { return }
        // Leave room for PencilKit's native toolbar. Only the presentation transform changes.
        let available = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 12, dy: 60)
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        paper.transform = CGAffineTransform(scaleX: max(0.01, scale), y: max(0.01, scale))
        paper.center = CGPoint(x: available.midX, y: available.midY)
    }

    private func mount(_ image: UIImage) {
        self.image = image
        status.isHidden = true
        paper.bounds = CGRect(origin: .zero, size: image.size)
        paper.clipsToBounds = true
        let imageView = UIImageView(image: image)
        imageView.frame = paper.bounds
        paper.addSubview(imageView)
        canvas.frame = paper.bounds
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 7)
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?.contains("chat-markup") == true {
            canvas.drawing = Self.evidenceDrawing(size: image.size)
        }
#endif
        canvas.accessibilityLabel = MobileL10n.string("Draw on the image")
        paper.addSubview(canvas)
        view.addSubview(paper)
        view.setNeedsLayout()
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        navigationItem.rightBarButtonItem?.isEnabled = true
    }

    private func export() {
        guard let image else { return }
        let drawing = canvas.drawing.dataRepresentation()
        guard drawing.count <= 8 * 1_024 * 1_024 else {
            status.text = MobileL10n.string("This drawing is too large. Remove some marks and try again.")
            status.isHidden = false
            view.bringSubviewToFront(status)
            return
        }
        navigationItem.rightBarButtonItem?.isEnabled = false
        canvas.isUserInteractionEnabled = false
        preparation = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                Self.flatten(image: image, drawing: drawing)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let data else {
                navigationItem.rightBarButtonItem?.isEnabled = true
                canvas.isUserInteractionEnabled = true
                return
            }
            apply(data)
            dismiss(animated: true)
        }
    }

    nonisolated static func boundedImage(_ source: UIImage) -> UIImage {
        let pixels = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
        let ratio = min(1, 2_048 / max(pixels.width, pixels.height))
        let size = CGSize(width: max(1, pixels.width * ratio), height: max(1, pixels.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated static func flatten(image: UIImage, drawing: Data) -> Data? {
        guard let ink = try? PKDrawing(data: drawing) else { return nil }
        let rect = CGRect(origin: .zero, size: image.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: rect)
            ink.image(from: rect, scale: 1).draw(in: rect)
        }.pngData()
    }

#if DEBUG
    nonisolated static func evidenceDrawing(size: CGSize) -> PKDrawing {
        let positions = [CGPoint(x: 0.1, y: 0.36), CGPoint(x: 0.88, y: 0.36),
                         CGPoint(x: 0.88, y: 0.53), CGPoint(x: 0.1, y: 0.53), CGPoint(x: 0.1, y: 0.36)]
        let points = positions.enumerated().map { index, point in
            PKStrokePoint(location: CGPoint(x: point.x * size.width, y: point.y * size.height),
                          timeOffset: Double(index) * 0.1, size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemRed),
                                            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }
#endif
}
