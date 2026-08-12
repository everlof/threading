import AppKit
import UniformTypeIdentifiers

/// One file-system mark whose rendering belongs to the active app theme.
///
/// System keeps LaunchServices artwork: the platform theme is the one context where Finder's
/// coloured folders and document icons are the native visual language. An authored theme uses
/// semantic symbols instead. Finder artwork is not template artwork, so tinting it would stain
/// a finished bitmap rather than restyle it; choosing another renderer is the honest boundary.
///
/// This remains one view per materialized outline row. Symbol classification is path-only and
/// native artwork is loaded only when System is actually active, so an authored theme does no
/// LaunchServices icon work at all.
final class ThemedFileIconView: NSView, ThemedComponent {

    enum Kind: String, CaseIterable, Equatable {
        case directory
        case source
        case text
        case data
        case image
        case audio
        case video
        case archive
        case package
        case executable
        case generic

        fileprivate var symbolName: String {
            switch self {
            case .directory: "folder"
            case .source: "chevron.left.forwardslash.chevron.right"
            case .text: "doc.text"
            case .data: "curlybraces"
            case .image: "photo"
            case .audio: "waveform"
            case .video: "film"
            case .archive: "archivebox"
            case .package: "shippingbox"
            case .executable: "terminal"
            case .generic: "doc"
            }
        }
    }

    enum RenderingMode: Equatable {
        case native
        case themed
    }

    private enum Layout {
        static let size: CGFloat = 14
        static let pointSize: CGFloat = 11
    }

    private let url: URL
    let kind: Kind
    private let symbol: NSImage?
    private let folderFill: NSImage?
    private var nativeImage: NSImage?
    private let appEvents = AppEventObservations()

    var renderingMode: RenderingMode {
        AppThemePalette.current.isSystem ? .native : .themed
    }

    var hasLoadedNativeArtwork: Bool { nativeImage != nil }

    init(url: URL, isDirectory: Bool) {
        let resolvedKind = Self.kind(for: url, isDirectory: isDirectory)
        self.url = url
        kind = resolvedKind
        symbol = Design.Symbol.image(
            resolvedKind.symbolName,
            slot: Layout.size,
            pointSize: Layout.pointSize
        ) ?? Design.Symbol.image("doc", slot: Layout.size, pointSize: Layout.pointSize)
        folderFill = isDirectory
            ? Design.Symbol.image(
                "folder.fill",
                slot: Layout.size,
                pointSize: Layout.pointSize
            )
            : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        if renderingMode == .native { loadNativeImageIfNeeded() }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.appearanceDidChange()
        }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.size, height: Layout.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch renderingMode {
        case .native:
            loadNativeImageIfNeeded()
            guard let nativeImage else { return }
            nativeImage.draw(in: alignedRect(for: nativeImage))

        case .themed:
            if let folderFill {
                TemplateImageDrawing.draw(
                    folderFill,
                    in: alignedRect(for: folderFill),
                    tint: Design.Surface.controlResting
                )
            }
            guard let symbol else { return }
            TemplateImageDrawing.draw(
                symbol,
                in: alignedRect(for: symbol),
                tint: Design.Text.secondary
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    static func kind(for url: URL, isDirectory: Bool) -> Kind {
        if isDirectory { return .directory }

        let name = url.lastPathComponent.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        if sourceExtensions.contains(pathExtension) { return .source }
        if textExtensions.contains(pathExtension) || textNames.contains(name) { return .text }
        if dataExtensions.contains(pathExtension) { return .data }
        if imageExtensions.contains(pathExtension) { return .image }
        if audioExtensions.contains(pathExtension) { return .audio }
        if videoExtensions.contains(pathExtension) { return .video }
        if archiveExtensions.contains(pathExtension) { return .archive }
        if packageExtensions.contains(pathExtension) { return .package }
        if executableExtensions.contains(pathExtension) || executableNames.contains(name) {
            return .executable
        }
        return .generic
    }

    private func appearanceDidChange() {
        if renderingMode == .native { loadNativeImageIfNeeded() }
        needsDisplay = true
    }

    private func loadNativeImageIfNeeded() {
        guard nativeImage == nil else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            nativeImage = NSWorkspace.shared.icon(forFile: url.path)
            return
        }

        // Gallery stories, restored transcript paths and newly-created diff rows can describe
        // a path before it exists locally. Asking Finder for that nonexistent path returns the
        // same generic document for every kind, making a type-aware file list visually blind.
        // LaunchServices can still supply its native artwork from the semantic content type.
        let type: UTType = if kind == .directory {
            .folder
        } else if let inferred = UTType(filenameExtension: url.pathExtension),
                  inferred != .data {
            inferred
        } else {
            fallbackContentType
        }
        nativeImage = NSWorkspace.shared.icon(for: type)
    }

    private var fallbackContentType: UTType {
        switch kind {
        case .directory: .folder
        case .source: .sourceCode
        case .text: .plainText
        case .data: .json
        case .image: .image
        case .audio: .audio
        case .video: .movie
        case .archive: .archive
        case .package: .package
        case .executable: .executable
        case .generic: .data
        }
    }

    private func alignedRect(for image: NSImage) -> NSRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(1, bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let centered = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return backingAlignedRect(centered, options: .alignAllEdgesInward)
    }

    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "jsx",
        "kt", "kts", "m", "mm", "php", "py", "rb", "rs", "scala", "sql", "swift",
        "ts", "tsx"
    ]
    private static let textExtensions: Set<String> = [
        "log", "markdown", "md", "rtf", "text", "txt"
    ]
    private static let textNames: Set<String> = [
        "authors", "changelog", "contributing", "copying", "license", "readme"
    ]
    private static let dataExtensions: Set<String> = [
        "csv", "graphql", "ini", "json", "plist", "toml", "xml", "yaml", "yml"
    ]
    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "ico", "jpeg", "jpg", "pdf", "png", "svg", "tiff", "webp"
    ]
    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "flac", "m4a", "mp3", "ogg", "wav"
    ]
    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "webm"
    ]
    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "gz", "rar", "tar", "tgz", "xz", "zip"
    ]
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "package", "pkg", "playground", "xcframework",
        "xcodeproj", "xcworkspace"
    ]
    private static let executableExtensions: Set<String> = [
        "bash", "command", "fish", "sh", "zsh"
    ]
    private static let executableNames: Set<String> = [
        "dockerfile", "gemfile", "makefile", "podfile"
    ]
}
