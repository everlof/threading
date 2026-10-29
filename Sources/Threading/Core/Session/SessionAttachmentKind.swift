import Foundation

/// The file kinds understood by the shared attachment detector and both desktop hosts.
enum SessionAttachmentKind: String, Codable, Sendable {
    case image
    case pdf
    case html
    case archive
    case document
    /// Diagram *source* — Graphviz dot, Mermaid. Text, not pixels: the pane previews the
    /// source itself, since rendering would take a diagram engine the app does not carry.
    case diagram
    /// A movie — a screen recording, a simulator capture, a clip an agent produced.
    ///
    /// A kind of its own rather than a `.media` registration, because the host *does* carry
    /// this engine: `VideoDocumentRenderer` plays it with the platform's own audiovisual
    /// stack. `.media` means "no native preview exists for this"; a movie has one, and filing
    /// it under the fallback would hide a playable file behind an extension that may never be
    /// installed.
    case video
    /// A document Threading has no *native* preview for: a format an extension registered, or
    /// an ambiguous one the host's own probe recognized — a bare JSON Lottie is both a `.json`
    /// and an animation, and only the bytes can say which.
    ///
    /// Its native body is a bounded fallback rather than a renderer: UTF-8 source under the
    /// source-preview ceiling, or an explicit "no preview extension is available". Removing
    /// the last contribution never closes the built-in surface or leaves blank chrome.
    case media
    /// A unified diff: a `display_compare_files` text comparison frozen when it was shown, or
    /// a `.diff`/`.patch` file handed over deliberately. Drawn as a diff on both the Mac and
    /// the phone, since a comparison is the one panel surface a paired phone could not see.
    case diff
    /// Two of the session's pictures held against each other. The file is a
    /// `RemoteImageComparisonDTO` naming both rows; the pair is also the row's source key,
    /// so `comparedAttachmentIDs` answers without reading it.
    case comparison
}
