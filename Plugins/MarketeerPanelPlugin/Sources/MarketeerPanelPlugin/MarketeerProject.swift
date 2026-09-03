import CryptoKit
import Foundation

// MARK: - Where a project lives

/// Finds the source package the Marketeer companion keeps for one Threading project.
///
/// The companion is App Sandboxed, so "Application Support" for it means *its container*, not the
/// user's. That is the whole reason this type exists rather than a path literal: the obvious
/// `~/Library/Application Support/ThreadingMarketeer` is empty and always will be, and looking
/// there produces "no project attached" for a project that plainly has one.
///
/// The directory name is the SHA-256 of the Threading project id, truncated, which is the
/// companion's own scheme — it never persists or discloses a checkout path.
public enum MarketeerProjectLocator {

    /// The companion's bundle identifier, and so its container.
    public static let companionBundleIdentifier = "codes.threading.marketeer.companion.render"

    /// The companion truncates the hex digest to this many characters.
    public static let directoryNameLength = 32

    public static func projectsRoot(
        containers: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
    ) -> URL {
        containers
            .appendingPathComponent(companionBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent("ThreadingMarketeer/Projects", isDirectory: true)
    }

    /// The folder name the companion would use for a project id.
    public static func directoryName(forProjectID projectID: String) -> String {
        let digest = SHA256.hash(data: Data(projectID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(directoryNameLength))
    }

    public static func packageDirectory(forProjectID projectID: String, root: URL? = nil) -> URL {
        (root ?? projectsRoot())
            .appendingPathComponent(directoryName(forProjectID: projectID), isDirectory: true)
    }
}

// MARK: - The document

public struct MarketeerColor: Decodable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double
}

public struct MarketeerGradient: Decodable, Equatable, Sendable {
    public let startColor: MarketeerColor
    public let endColor: MarketeerColor
    public let angle: Double
}

public struct MarketeerBackground: Decodable, Equatable, Sendable {
    public let type: String
    /// Only the gradient shape is understood. Anything else keeps its `type` and draws as a plain
    /// swatch rather than being refused: a background we cannot draw is still a slide worth
    /// listing, and a decoder that throws here would empty the whole pane over one new style.
    public let gradient: MarketeerGradient?

    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        gradient = try? container.decode(MarketeerGradient.self, forKey: .data)
    }
}

public struct MarketeerElement: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: String
    /// Placement, in fractions of the canvas. `y` is measured from the top, the way a designer
    /// reads a slide; AppKit's origin is the other corner, so a view flips it once.
    public let x: Double
    public let y: Double
    public let scale: Double
    /// Set for `text` elements. The real string, so a thumbnail can show the words rather than
    /// a grey bar standing in for them.
    public let text: String?
    public let color: MarketeerColor?
    /// Set for `device` elements.
    public let deviceModel: String?

    private enum CodingKeys: String, CodingKey { case id, payload, x, y, scale }
    private enum PayloadKeys: String, CodingKey { case type, data }
    private enum DataKeys: String, CodingKey { case text, color, deviceModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        x = (try? container.decode(Double.self, forKey: .x)) ?? 0.5
        y = (try? container.decode(Double.self, forKey: .y)) ?? 0.5
        scale = (try? container.decode(Double.self, forKey: .scale)) ?? 1

        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        kind = try payload.decode(String.self, forKey: .type)
        let data = try? payload.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        text = try? data?.decode(String.self, forKey: .text)
        color = try? data?.decode(MarketeerColor.self, forKey: .color)
        deviceModel = try? data?.decode(String.self, forKey: .deviceModel)
    }
}

public struct MarketeerSlide: Decodable, Equatable, Sendable {
    public let id: String
    public let slotPosition: Int
    public let canvasSizeID: String
    public let background: MarketeerBackground?
    public let elements: [MarketeerElement]
    public let uploadedCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, slotPosition, canvasSizeID, backgroundStyle, elements, uploadedStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        slotPosition = (try? container.decode(Int.self, forKey: .slotPosition)) ?? 0
        canvasSizeID = (try? container.decode(String.self, forKey: .canvasSizeID)) ?? ""
        background = try? container.decode(MarketeerBackground.self, forKey: .backgroundStyle)
        elements = (try? container.decode([MarketeerElement].self, forKey: .elements)) ?? []
        uploadedCount = ((try? container.decode([String: Bool].self, forKey: .uploadedStates)) ?? [:])
            .filter { $0.value }.count
    }

    /// Elements a thumbnail will draw, capped before drawing. A slide is authored, so its element
    /// count is the user's; twenty is far above any real slide and keeps one pathological document
    /// from making a row expensive.
    public static let drawnElementCap = 20

    public var drawnElements: [MarketeerElement] { Array(elements.prefix(Self.drawnElementCap)) }

    /// The slide's words, top first.
    ///
    /// Text elements are placed by `y` from the top, so reading order is sort order. The first is
    /// the title and the second the subtitle, which is the convention every slide in a real
    /// project follows and the only one the document expresses.
    public var captions: [String] {
        elements
            .filter { $0.kind == "text" }
            .sorted { $0.y < $1.y }
            .compactMap { $0.text }
            .filter { !$0.isEmpty }
    }

    public var title: String? { captions.first }
    public var subtitle: String? { captions.dropFirst().first }

    /// "device, 2 text" — what is on the slide, in the order a reader scans.
    public var elementSummary: String {
        guard !elements.isEmpty else { return "empty" }
        var counts: [(kind: String, count: Int)] = []
        for element in elements {
            if let index = counts.firstIndex(where: { $0.kind == element.kind }) {
                counts[index].count += 1
            } else {
                counts.append((element.kind, 1))
            }
        }
        return counts
            .map { $0.count == 1 ? $0.kind : "\($0.count) \($0.kind)" }
            .joined(separator: ", ")
    }
}

public struct MarketeerAppLink: Decodable, Equatable, Sendable {
    public let appID: String?
    public let bundleID: String?
    public let appName: String?
}

public struct MarketeerLocalization: Decodable, Equatable, Sendable {
    public let localeCode: String
    public let displayName: String?
}

// MARK: - The whole project

public struct MarketeerProject: Equatable, Sendable {
    public let name: String
    public let projectID: String
    public let revision: Int?
    public let changeReason: String?
    public let appLink: MarketeerAppLink?
    public let localizations: [MarketeerLocalization]
    public let slides: [MarketeerSlide]

    /// Exported pictures by slide `slotPosition`, empty until something has been rendered. A row
    /// with an entry here shows the artwork; a row without shows the miniature drawn from the
    /// document, which is every row of a project nobody has rendered yet.
    public let exports: [Int: URL]

    public init(
        name: String,
        projectID: String,
        revision: Int? = nil,
        changeReason: String? = nil,
        appLink: MarketeerAppLink? = nil,
        localizations: [MarketeerLocalization] = [],
        slides: [MarketeerSlide] = [],
        exports: [Int: URL] = [:]
    ) {
        self.name = name
        self.projectID = projectID
        self.revision = revision
        self.changeReason = changeReason
        self.appLink = appLink
        self.localizations = localizations
        self.slides = slides
        self.exports = exports
    }

    /// Slides ordered the way the App Store shows them, and capped before any view is built.
    ///
    /// A document is the user's, so its length is not ours to assume. The App Store's own cap is
    /// ten screenshots per size per locale, so a real project is far below this; the bound exists
    /// so a corrupt or generated document cannot ask the pane for ten thousand rows.
    public static let renderedSlideCap = 60

    public var orderedSlides: [MarketeerSlide] {
        slides.sorted { ($0.slotPosition, $0.id) < ($1.slotPosition, $1.id) }
            .prefix(Self.renderedSlideCap)
            .map { $0 }
    }

    public var hiddenSlideCount: Int { max(0, slides.count - Self.renderedSlideCap) }
}

// MARK: - Reading it

public enum MarketeerReadFailure: Error, Equatable, CustomStringConvertible {
    case noProject
    case noPackage(directoryName: String)
    case unreadable(String)
    case tooLarge(bytes: Int)

    public var description: String {
        switch self {
        case .noProject:
            return "This pane is not in a project."
        case .noPackage(let name):
            return "No Marketeer source is attached to this project yet (\(name))."
        case .unreadable(let reason):
            return "The Marketeer source could not be read: \(reason)"
        case .tooLarge(let bytes):
            return "The Marketeer document is larger than this pane will read (\(bytes) bytes)."
        }
    }
}

public enum MarketeerProjectReader {

    /// The document is authored text, so it is bounded before it is read rather than after. The
    /// companion's own inspection limit is 48 KiB; this is generously above it so a legitimate
    /// document is never refused, and still small enough that reading it on the main thread is
    /// frame-cheap.
    public static let maximumDocumentBytes = 4 * 1024 * 1024

    public static func read(projectID: String?, root: URL? = nil) -> Result<MarketeerProject, MarketeerReadFailure> {
        guard let projectID, !projectID.isEmpty else { return .failure(.noProject) }
        let directory = MarketeerProjectLocator.packageDirectory(forProjectID: projectID, root: root)
        let name = MarketeerProjectLocator.directoryName(forProjectID: projectID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return .failure(.noPackage(directoryName: String(name.prefix(12))))
        }

        let documentURL = directory
            .appendingPathComponent("Project.marketeer", isDirectory: true)
            .appendingPathComponent("document.json")
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: documentURL.path)[.size] as? Int) ?? 0
            guard size <= maximumDocumentBytes else { return .failure(.tooLarge(bytes: size)) }

            let document = try JSONDecoder().decode(
                Document.self,
                from: try Data(contentsOf: documentURL)
            )
            let identity = try? JSONDecoder().decode(
                Identity.self,
                from: try Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
            let state = try? JSONDecoder().decode(
                State.self,
                from: try Data(contentsOf: directory.appendingPathComponent("state.json"))
            )
            return .success(MarketeerProject(
                name: identity?.projectName ?? "Marketeer",
                projectID: identity?.projectID ?? projectID,
                revision: state?.revision,
                changeReason: state?.reason,
                appLink: document.appStoreLink,
                localizations: document.localizations ?? [],
                slides: document.slides ?? [],
                exports: MarketeerExports.index(forProjectID: projectID, root: root)
            ))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    private struct Document: Decodable {
        let appStoreLink: MarketeerAppLink?
        let localizations: [MarketeerLocalization]?
        let slides: [MarketeerSlide]?
    }

    private struct Identity: Decodable {
        let projectName: String?
        let projectID: String?
    }

    private struct State: Decodable {
        let revision: Int?
        let reason: String?
    }
}
