import Foundation

// MARK: - Workspace state

/// The host-owned entity represented by one native navigator item.
@objc(ThreadingPluginWorkspaceItemKind)
public enum PluginWorkspaceItemKind: Int, Sendable {
    case project
    case session
    case terminal
}

/// A complete workspace identity.
///
/// Project, session, and terminal identifiers belong to separate host domains, so every place
/// that names an item carries its kind too. Plugins should treat `identifier` as opaque.
@objc(ThreadingPluginWorkspaceItemIdentity)
@objcMembers
public final class PluginWorkspaceItemIdentity: NSObject, @unchecked Sendable {
    public let kind: PluginWorkspaceItemKind
    public let identifier: String

    public init(kind: PluginWorkspaceItemKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PluginWorkspaceItemIdentity else { return false }
        return kind == other.kind && identifier == other.identifier
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind.rawValue)
        hasher.combine(identifier)
        return hasher.finalize()
    }
}

/// The bounded activity vocabulary Threading publishes to native navigators.
///
/// Kept separate from any application's internal enum so adding implementation state inside the
/// host never changes a plugin's contract. `none` is used for projects and terminals.
@objc(ThreadingPluginWorkspaceActivity)
public enum PluginWorkspaceActivity: Int, Sendable {
    case none
    case dormant
    case idle
    case working
    case readyWithBackgroundWork
    case awaitingUser
    case needsAttention
    case limitReached
}

/// One immutable row candidate in a native workspace navigator.
///
/// A native navigator owns presentation, not truth. These values are snapshots; every action is
/// checked again by the host when invoked. Strings are already display values and are bounded
/// before the context crosses into plugin code.
@objc(ThreadingPluginWorkspaceItem)
@objcMembers
public final class PluginWorkspaceItem: NSObject, @unchecked Sendable {
    public let identity: PluginWorkspaceItemIdentity
    public let parentIdentity: PluginWorkspaceItemIdentity?
    public let title: String
    public let detail: String?
    public let branch: String?
    public let activity: PluginWorkspaceActivity
    public let isPinned: Bool
    public let isArchived: Bool
    public let lastActiveAt: Date?

    public init(
        identity: PluginWorkspaceItemIdentity,
        parentIdentity: PluginWorkspaceItemIdentity? = nil,
        title: String,
        detail: String? = nil,
        branch: String? = nil,
        activity: PluginWorkspaceActivity = .none,
        isPinned: Bool = false,
        isArchived: Bool = false,
        lastActiveAt: Date? = nil
    ) {
        self.identity = identity
        self.parentIdentity = parentIdentity
        self.title = title
        self.detail = detail
        self.branch = branch
        self.activity = activity
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.lastActiveAt = lastActiveAt
        super.init()
    }
}

/// A complete, bounded generation of workspace state visible to a native navigator.
@objc(ThreadingPluginWorkspaceSnapshot)
@objcMembers
public final class PluginWorkspaceSnapshot: NSObject, @unchecked Sendable {
    public let revision: UInt64
    public let items: [PluginWorkspaceItem]
    public let selectedItemIdentity: PluginWorkspaceItemIdentity?

    public init(
        revision: UInt64,
        items: [PluginWorkspaceItem],
        selectedItemIdentity: PluginWorkspaceItemIdentity?
    ) {
        self.revision = revision
        self.items = items
        self.selectedItemIdentity = selectedItemIdentity
        super.init()
    }
}

/// An atomic change after the initial workspace snapshot.
///
/// Structural changes use `isReplacement` and carry the complete bounded item collection. A
/// content edge carries only changed and removed identities, preventing one busy session from
/// rebuilding a workspace whose size comes from user data. Selection is explicit because `nil`
/// can be a real new selection rather than "not included in this update".
@objc(ThreadingPluginWorkspaceUpdate)
@objcMembers
public final class PluginWorkspaceUpdate: NSObject, @unchecked Sendable {
    public let revision: UInt64
    public let isReplacement: Bool
    public let items: [PluginWorkspaceItem]
    public let removedItems: [PluginWorkspaceItemIdentity]
    public let selectionChanged: Bool
    public let selectedItemIdentity: PluginWorkspaceItemIdentity?

    public init(
        revision: UInt64,
        isReplacement: Bool = false,
        items: [PluginWorkspaceItem],
        removedItems: [PluginWorkspaceItemIdentity] = [],
        selectionChanged: Bool = false,
        selectedItemIdentity: PluginWorkspaceItemIdentity? = nil
    ) {
        self.revision = revision
        self.isReplacement = isReplacement
        self.items = items
        self.removedItems = removedItems
        self.selectionChanged = selectionChanged
        self.selectedItemIdentity = selectedItemIdentity
        super.init()
    }
}

/// Mutations a native navigator may ask the host to perform on a session.
@objc(ThreadingPluginWorkspaceAction)
public enum PluginWorkspaceAction: Int, Sendable {
    case pin
    case unpin
    case archive
}

private struct PluginWorkspaceItemKey: Hashable {
    let kind: Int
    let identifier: String

    init(_ identity: PluginWorkspaceItemIdentity) {
        kind = identity.kind.rawValue
        identifier = identity.identifier
    }
}

/// The live bridge owned by the host and retained by one native navigator presentation.
///
/// The bridge intentionally offers neither a store nor a window. A plugin receives bounded
/// values, subscribes to atomic updates, and sends user intent back across methods whose host
/// implementations re-read current state. Native code runs in-process and is therefore trusted;
/// this narrow shape is about compatibility and one source of truth, not a sandbox claim.
@MainActor
@objc(ThreadingPluginWorkspaceNavigatorContext)
@objcMembers
public final class PluginWorkspaceNavigatorContext: NSObject {
    public let navigatorIdentifier: String

    private var revision: UInt64
    private var orderedKeys: [PluginWorkspaceItemKey]
    private var orderedKeySet: Set<PluginWorkspaceItemKey>
    private var itemsByKey: [PluginWorkspaceItemKey: PluginWorkspaceItem]
    private var selectedIdentity: PluginWorkspaceItemIdentity?
    private var tombstoneCount = 0

    private let activationHandler: (PluginWorkspaceItemIdentity) -> Bool
    private let actionHandler: (PluginWorkspaceAction, PluginWorkspaceItemIdentity) -> Bool
    private var updateHandler: ((PluginWorkspaceUpdate) -> Void)?

    public init(
        navigatorIdentifier: String,
        initialSnapshot: PluginWorkspaceSnapshot,
        activate: @escaping (PluginWorkspaceItemIdentity) -> Bool,
        perform: @escaping (PluginWorkspaceAction, PluginWorkspaceItemIdentity) -> Bool
    ) {
        self.navigatorIdentifier = navigatorIdentifier
        revision = initialSnapshot.revision
        selectedIdentity = initialSnapshot.selectedItemIdentity
        activationHandler = activate
        actionHandler = perform

        var order: [PluginWorkspaceItemKey] = []
        var items: [PluginWorkspaceItemKey: PluginWorkspaceItem] = [:]
        order.reserveCapacity(initialSnapshot.items.count)
        items.reserveCapacity(initialSnapshot.items.count)
        for item in initialSnapshot.items {
            let key = PluginWorkspaceItemKey(item.identity)
            if items.updateValue(item, forKey: key) == nil { order.append(key) }
        }
        orderedKeys = order
        orderedKeySet = Set(order)
        itemsByKey = items
        super.init()
    }

    /// The latest coherent state, materialized only when a presentation asks for it.
    ///
    /// Incremental updates themselves remain proportional to the delta. Most plugins read this
    /// once when constructing their view and merge subsequent `PluginWorkspaceUpdate`s directly.
    public var snapshot: PluginWorkspaceSnapshot {
        PluginWorkspaceSnapshot(
            revision: revision,
            items: orderedKeys.compactMap { itemsByKey[$0] },
            selectedItemIdentity: selectedIdentity
        )
    }

    /// Installs the presentation's single update sink.
    ///
    /// The current state remains available through `snapshot`; updates start strictly after it.
    /// Replacing the sink is supported so a plugin can rebuild its root view without asking the
    /// host to load another bundle instance.
    public func observeUpdates(_ handler: @escaping (PluginWorkspaceUpdate) -> Void) {
        updateHandler = handler
    }

    public func stopObservingUpdates() {
        updateHandler = nil
    }

    /// Requests navigation to an item. `false` means it no longer exists or cannot be opened.
    @discardableResult
    public func activate(identity: PluginWorkspaceItemIdentity) -> Bool {
        activationHandler(identity)
    }

    /// Requests a durable session mutation. `false` means the host refused current state.
    @discardableResult
    public func perform(
        action: PluginWorkspaceAction,
        identity: PluginWorkspaceItemIdentity
    ) -> Bool {
        actionHandler(action, identity)
    }

    /// Publishes one host-authored update and advances the context's coherent state.
    ///
    /// Public because the host and kit are separate modules; plugin authors should treat this as
    /// a host-only method. Calling it grants no authority because actions still revalidate inside
    /// the application. Duplicate changed identities are canonicalized last-one-wins, and removal
    /// wins when the same identity appears in both collections; malformed input cannot trap the
    /// host process.
    public func receiveHostUpdate(_ update: PluginWorkspaceUpdate) {
        guard update.revision > revision else { return }

        var changedByKey: [PluginWorkspaceItemKey: PluginWorkspaceItem] = [:]
        var changedOrder: [PluginWorkspaceItemKey] = []
        changedByKey.reserveCapacity(update.items.count)
        changedOrder.reserveCapacity(update.items.count)
        for item in update.items {
            let key = PluginWorkspaceItemKey(item.identity)
            if changedByKey.updateValue(item, forKey: key) == nil { changedOrder.append(key) }
        }
        let removedKeys = Set(update.removedItems.map(PluginWorkspaceItemKey.init))

        if update.isReplacement {
            orderedKeys = changedOrder.filter { !removedKeys.contains($0) }
            orderedKeySet = Set(orderedKeys)
            itemsByKey = changedByKey.filter { !removedKeys.contains($0.key) }
            tombstoneCount = 0
        } else {
            for key in changedOrder where !removedKeys.contains(key) {
                guard let item = changedByKey[key] else { continue }
                if itemsByKey.updateValue(item, forKey: key) == nil {
                    if orderedKeySet.contains(key) {
                        tombstoneCount = max(0, tombstoneCount - 1)
                    } else {
                        orderedKeys.append(key)
                        orderedKeySet.insert(key)
                    }
                }
            }
            for key in removedKeys where itemsByKey.removeValue(forKey: key) != nil {
                tombstoneCount += 1
            }
            compactOrderIfNeeded()
        }

        if update.selectionChanged { selectedIdentity = update.selectedItemIdentity }
        revision = update.revision

        var canonicalRemovals: [PluginWorkspaceItemIdentity] = []
        var seenRemovals = Set<PluginWorkspaceItemKey>()
        for identity in update.removedItems {
            let key = PluginWorkspaceItemKey(identity)
            if seenRemovals.insert(key).inserted { canonicalRemovals.append(identity) }
        }
        let canonical = PluginWorkspaceUpdate(
            revision: update.revision,
            isReplacement: update.isReplacement,
            items: changedOrder.compactMap { key in
                removedKeys.contains(key) ? nil : changedByKey[key]
            },
            removedItems: canonicalRemovals,
            selectionChanged: update.selectionChanged,
            selectedItemIdentity: update.selectedItemIdentity
        )
        updateHandler?(canonical)
    }

    /// Tombstones make ordinary removal O(delta). Compact only after churn has made the retained
    /// order materially larger than live state, giving bounded amortized rather than per-edge
    /// whole-workspace work.
    private func compactOrderIfNeeded() {
        guard tombstoneCount >= 64, tombstoneCount * 2 >= orderedKeys.count else { return }
        orderedKeys = orderedKeys.filter { itemsByKey[$0] != nil }
        orderedKeySet = Set(orderedKeys)
        tombstoneCount = 0
    }
}

// MARK: - Bundle metadata

/// Static keys a host can inspect without mapping a plugin's executable.
public enum PluginBundleMetadata {
    public static let workspaceNavigators = "ThreadingWorkspaceNavigators"
    public static let identifier = "id"
    public static let title = "title"
    public static let preferredWidth = "preferredWidth"
}
