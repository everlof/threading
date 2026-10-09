import Foundation

// MARK: - Project Icon Defaults

enum ProjectIconDefaults {
    /// Matches `StateManager`'s directory, which owns the app's Application Support root.
    static let applicationDirectoryName = "Threading"
    static let iconDirectoryName = "ProjectIcons"
    static let storedExtension = "png"

    /// Stored at 4× the sidebar's 16pt slot, so Retina rendering never upsamples.
    static let storedPixelSize = 64

    /// Anything smaller than this cannot survive being drawn at 16pt.
    static let minimumPixelSize = 16

    // MARK: Display

    /// Matches the sidebar's icon slot.
    static let displayPointSize: CGFloat = 16
    static let displayCornerRadius: CGFloat = 4
    static let plateInset: CGFloat = 2
    static let luminanceSampleSize = 32

    /// How opaque an icon's border must read before the rounded clip is allowed to run over
    /// it — see `ProjectIconStore.fillsItsBounds`. High enough that a mark with any real
    /// clear margin is left alone, low enough that a tile with a soft or antialiased edge is
    /// still rounded.
    static let tileEdgeOpacity: CGFloat = 0.9

    // The plate's thresholds and its two neutrals live in `IconBackplate`, which is the rule
    // both the project tiles and the session rows' agent marks now go through. They were
    // stated here as well — a luminance floor and ceiling per appearance, and a second copy of
    // the two plate colours — which is how the tile and the mark beside it could plate by
    // different rules against the same sidebar.

    /// Ceiling on a candidate image read into memory, local or fetched.
    static let maximumSourceBytes = 5 * 1024 * 1024

    // MARK: Discovery

    /// Icon file names worth probing, in preference order — a touch icon is the highest
    /// resolution mark a web project publishes.
    static let candidateFileNames = [
        "apple-touch-icon.png",
        "apple-touch-icon-precomposed.png",
        "favicon.png",
        "favicon.ico",
        "icon.png",
        "logo.png"
    ]

    /// Directories conventionally owned by the project itself, probed beside its root.
    static let candidateSubdirectories = ["public", "static", "assets", "web", "www", "site", "docs"]

    /// Dependency and build-output directories whose assets belong to someone else's
    /// project — the reason a bare recursive scan would be wrong.
    static let excludedDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", "dist", "build", "out",
        "target", "third_party", "external", "deps", "DerivedData", "venv"
    ]

    /// An Xcode project's own icon lives here; the largest rendition wins.
    static let appIconSetName = "AppIcon.appiconset"

    static let maximumScanDepth = 4
    static let maximumScannedEntries = 4000

    /// Where a repository's GitHub owner publishes an avatar. Square, any size via `size`.
    static func gitHubAvatarURL(owner: String) -> URL? {
        URL(string: "https://github.com/\(owner).png?size=\(avatarPixelSize)")
    }

    /// The API record saying whether an owner is a person or an organisation.
    static func gitHubAccountURL(owner: String) -> URL? {
        URL(string: "https://api.github.com/users/\(owner)")
    }

    static let gitHubAccountTypeKey = "type"
    static let gitHubOrganizationType = "Organization"

    static let avatarPixelSize = 128
    static let gitHubHost = "github.com"

    /// Paths probed after the user explicitly supplies a website.
    static let websiteIconProbes = ["apple-touch-icon.png", "favicon.png", "favicon.ico"]

    static let requestTimeout: TimeInterval = 10
}
