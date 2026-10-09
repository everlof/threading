#if os(Linux)
import AppKit

/// The Linux table shim already leaves its surface transparent and delegates visible rows to
/// the supplied Design components. Match the shared table factory's themed construction name.
@MainActor
final class ThemedTableView: NSTableView {}
#endif
