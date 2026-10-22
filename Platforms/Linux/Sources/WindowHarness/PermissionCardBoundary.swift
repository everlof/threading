#if os(Linux)
import AppKit
import ThreadingRemoteKit

// The production permission card links unchanged. Its Mac-only paths, which mirror a request to
// a paired device or let an appointed manager answer it, cross this boundary.

/// Linux mirrors no conversation to paired devices, so the card's remote projection is
/// fail-closed: it is never decidable anywhere but on the card itself.
enum RemoteConversationWirePolicy {
    static let localReviewReason = "Remote approval is not available in the Linux preview."

    static func safePermission(_ request: RemotePermissionRequestDTO) -> RemotePermissionRequestDTO {
        RemotePermissionRequestDTO(id: request.id, toolName: request.toolName, summary: request.summary,
            filePath: request.filePath, diff: [], canDecide: false, unavailableReason: localReviewReason)
    }
}

/// The production manager vocabulary. The Linux host has no control plane yet, so no manager
/// resolves a card; `resolveManager` refuses through the fail-closed projection above.
enum ControlPermissionDecision: String, Equatable, Sendable {
    case allow
    case deny
}

extension NSView {
    func applySurface(fill: NSColor, radius: SurfaceRadius, border: NSColor?) {
        setAppliedSurface(fill: fill, radius: radius.current, border: border)
    }

    func applyLayerBorder(_ color: NSColor) { setAppliedSurfaceBorder(color) }
}
#endif
