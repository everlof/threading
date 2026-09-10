import Foundation

/// A file type an extension asks the attachments scanner to notice.
///
/// It adds to the scanner's allow-list and **nothing else**. The store still decides recording,
/// copying, ceilings, pruning and every question about custody; a registration is a request to be
/// looked at, not an authority over what is kept.
///
/// A registration may not claim an extension the host already classifies: `json`, `html`, `pdf`,
/// `png` and the rest are reserved, because letting an extension own `.json` would let it claim
/// every configuration file in every session.
public struct ExtensionPreviewableFileType: Codable, Equatable, Sendable {
    public static let maximumCount = 8
    public static let maximumExtensionLength = 12

    /// Lowercased, no dot.
    public let fileExtension: String
    public let displayName: String

    public init(fileExtension: String, displayName: String) {
        self.fileExtension = fileExtension
        self.displayName = displayName
    }

    /// Extensions the host classifies itself, and therefore will not hand to a registration.
    ///
    /// Everything the built-in kind map already answers for, plus the ambiguous ones the host
    /// probes. `lottie` is deliberately absent: it is free, which is the point of the mechanism.
    public static let reservedExtensions: Set<String> = [
        // Images.
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
        // Documents and pages.
        "pdf", "html", "htm", "rtf", "odt", "ods", "odp", "docx", "xlsx", "pptx",
        // Archives.
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar",
        // Diagram sources.
        "dot", "gv", "mmd", "mermaid",
        // Host-probed ambiguities.
        "json", "yaml", "yml"
    ]

    public func validationIssues(path: String) -> [ExtensionValidationIssue] {
        var issues: [ExtensionValidationIssue] = []
        let value = fileExtension
        if value.isEmpty || value.count > Self.maximumExtensionLength {
            issues.append(.init(
                path: "\(path).fileExtension",
                message: "must be 1 to \(Self.maximumExtensionLength) characters"
            ))
        } else if !value.allSatisfy({ $0.isLowercaseASCIILetterOrDigit }) {
            issues.append(.init(
                path: "\(path).fileExtension",
                message: "must contain only lowercase letters and digits, with no dot"
            ))
        } else if Self.reservedExtensions.contains(value) {
            issues.append(.init(
                path: "\(path).fileExtension",
                message: "'\(value)' is classified by Threading and cannot be registered"
            ))
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append(.init(path: "\(path).displayName", message: "must not be empty"))
        } else if displayName.count > 60 {
            issues.append(.init(
                path: "\(path).displayName",
                message: "must contain at most 60 characters"
            ))
        }
        return issues
    }
}

/// `attachments.preview@1` — an extension-owned preview body inside Threading's Attachments pane.
///
/// **An extension offers for an attachment rather than owning a type.** The host asks candidates
/// in the user's chosen extension order and the first valid acceptance wins; a decline, a timeout
/// or an invalid response advances to the next, and exhaustion reaches the native fallback. There
/// is no "two candidates conflict" state, because ordering *is* the conflict policy.
///
/// The contract grants no attachment read authority. An extension previewing a document learns its
/// name, kind, size, origin and the host's content hint, and nothing about its content that the
/// host did not already publish.
public enum ExtensionAttachmentPreviewContract {
    public static let id = "attachments.preview"
    public static let version = 1

    /// At most this many candidates are consulted for one presentation, so a broad set of
    /// installed extensions cannot turn selecting a row into unbounded process work.
    public static let maximumCandidates = 8

    /// What a preview body may say.
    ///
    /// `media` is allowed, which is the point — this is the surface where an extension previews a
    /// document Threading has no native renderer for. Overlay and `.proceed` are not: offer and
    /// decline happen *before* one exclusive body is chosen, so there is no native content behind
    /// this to proceed into.
    public static let constraints = ExtensionComponentNodeConstraints(
        maximumDepth: 8,
        maximumNodes: 64,
        maximumRenderedElements: 600,
        maximumTextLength: 2_000,
        allowedStackAxes: [.horizontal, .vertical],
        allowedTextRoles: ExtensionTextRole.allCases,
        allowedImageRoles: ExtensionImageRole.inline,
        allowedButtonRoles: [.standard, .primary],
        allowedStatusRoles: ExtensionStatusRole.allCases,
        allowsTextInput: true,
        maximumPickerOptions: 50,
        maximumSceneItems: 500,
        allowsDivider: true,
        allowsFixedSpacer: true,
        allowsFlexibleSpacer: true,
        allowsMedia: true
    )
}

/// What a candidate is told about the attachment it is being offered.
///
/// Not the path, and not the bytes. `id` is opaque and valid only for this presentation — used as
/// an `ExtensionMediaSource.sessionAttachment`, it resolves; used anywhere else, it does not.
public struct ExtensionAttachmentContext: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let name: String
    /// The host's own kind vocabulary: `image`, `pdf`, `html`, `archive`, `document`, `diagram`,
    /// `media`. A raw string so an older extension keeps decoding when a kind is added.
    public let kind: String
    public let contentHint: ExtensionFileContentHint?
    public let byteSize: Int
    /// `agent` or `you` — which side of the conversation put the file in front of the other.
    public let origin: String
    /// The routing identifier for the session the attachment belongs to.
    public let sessionID: String

    public init(
        attachmentID: String,
        name: String,
        kind: String,
        contentHint: ExtensionFileContentHint? = nil,
        byteSize: Int,
        origin: String,
        sessionID: String
    ) {
        self.attachmentID = attachmentID
        self.name = name
        self.kind = kind
        self.contentHint = contentHint
        self.byteSize = byteSize
        self.origin = origin
        self.sessionID = sessionID
    }
}

/// The host offering one attachment to one candidate extension.
public struct ExtensionAttachmentPreviewRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let contractVersion: Int
    public let attachment: ExtensionAttachmentContext

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        contractVersion: Int = ExtensionAttachmentPreviewContract.version,
        attachment: ExtensionAttachmentContext
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.contractVersion = contractVersion
        self.attachment = attachment
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if attachment.attachmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "attachment.attachmentID", message: "must not be empty"))
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// A candidate's answer: a preview body, or a decline.
///
/// `content == nil` **is** the decline, and it is a first-class answer rather than a failure: an
/// extension that previews Lottie is expected to decline every PDF it is offered.
public struct ExtensionAttachmentPreviewResponse: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let requestID: String
    public let attachmentID: String
    public let content: ExtensionNode?
    /// Shown beside the body — a format note, a version, a count. Never an error.
    public let message: String?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        requestID: String,
        attachmentID: String,
        content: ExtensionNode? = nil,
        message: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.attachmentID = attachmentID
        self.content = content
        self.message = message
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }
        if requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "requestID", message: "must not be empty"))
        }
        if attachmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "attachmentID", message: "must not be empty"))
        }
        if let message, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(path: "message", message: "must not be empty when present"))
        }
        if let content {
            do {
                try ExtensionAttachmentPreviewContract.constraints.validate(
                    content,
                    path: "content"
                )
            } catch let error as ExtensionValidationError {
                issues.append(contentsOf: error.issues)
            } catch {
                issues.append(.init(path: "content", message: error.localizedDescription))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

private extension Character {
    var isLowercaseASCIILetterOrDigit: Bool {
        ("a"..."z").contains(self) || ("0"..."9").contains(self)
    }
}
