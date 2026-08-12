import AppKit

// MARK: - Tree Shape

/// The sidebar's shape: which rows exist, nested how, in what order.
///
/// Deliberately carries identities rather than content — a session's title and a project's name
/// are absent, so a rename compares equal and takes the in-place refresh path. A branch heading's
/// *name* is part of its identity and is therefore included: renaming a branch regroups the
/// sessions under it, which is a different tree rather than a differently-labelled one.
///
/// This replaced a string signature that could only answer "did anything move?". Answering
/// *what* moved is what an animated update needs, and the two questions are the same walk.
struct SidebarTreeShape: Equatable {

    /// Every row in the tree, so "this parent is new" can be told from "this parent lost all
    /// its children" — which are the same absence in `childrenByParent` and want opposite
    /// treatment.
    private(set) var keys: Set<SidebarNodeKey> = []

    /// Children by parent, in display order; the roots sit under `nil`. A row with no children
    /// is absent rather than present-and-empty.
    private(set) var childrenByParent: [SidebarNodeKey?: [SidebarNodeKey]] = [:]

    init() {}

    init(roots: [NSObject]) {
        func walk(_ nodes: [NSObject], parent: SidebarNodeKey?) {
            let childKeys = nodes.compactMap { ($0 as? any SidebarOutlineNode)?.sidebarKey }
            guard !childKeys.isEmpty else { return }
            childrenByParent[parent] = childKeys
            keys.formUnion(childKeys)

            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                walk(node.sidebarChildren, parent: node.sidebarKey)
            }
        }

        walk(roots, parent: nil)
    }

    var isEmpty: Bool { keys.isEmpty }

    func children(of parent: SidebarNodeKey?) -> [SidebarNodeKey] {
        childrenByParent[parent] ?? []
    }

    /// Removes one leaf without reconstructing the containing project's complete shape.
    /// Returns its former child index, which is exactly the index `NSOutlineView` must receive.
    mutating func removeLeaf(
        _ key: SidebarNodeKey,
        from parent: SidebarNodeKey
    ) -> Int? {
        guard childrenByParent[key] == nil,
              var siblings = childrenByParent[parent],
              let index = siblings.firstIndex(of: key) else { return nil }

        siblings.remove(at: index)
        if siblings.isEmpty {
            childrenByParent.removeValue(forKey: parent)
        } else {
            childrenByParent[parent] = siblings
        }
        keys.remove(key)
        return index
    }

    /// Replaces only child ordering/parentage inside an identity-equivalent subtree.
    ///
    /// The caller proves the key sets match first. That invariant means the global `keys` set
    /// and the root list under `nil` stay untouched; only mappings whose parent belongs to the
    /// replacement need updating. This is what lets one title reorder remain proportional to
    /// its project instead of reconstructing the shape of every project in the sidebar.
    mutating func replaceSubtreeOrdering(with replacement: SidebarTreeShape) {
        for key in replacement.keys {
            if let children = replacement.childrenByParent[key] {
                childrenByParent[key] = children
            } else {
                childrenByParent.removeValue(forKey: key)
            }
        }
    }

    /// Replaces the descendants of one standing root, including identities that arrived or left.
    ///
    /// The `nil` child list belongs to the complete sidebar, while these two shapes were built
    /// with the affected project as their temporary root. Keeping the global root list and
    /// replacing only mappings below that shared project is what makes one deletion proportional
    /// to its project without losing repository grouping around it.
    mutating func replaceSubtree(
        _ original: SidebarTreeShape,
        with replacement: SidebarTreeShape
    ) -> Bool {
        guard original.children(of: nil) == replacement.children(of: nil),
              let root = original.children(of: nil).first,
              original.children(of: nil).count == 1 else { return false }

        let originalDescendants = original.keys.subtracting([root])
        keys.subtract(originalDescendants)
        keys.formUnion(replacement.keys)

        for key in original.keys {
            childrenByParent.removeValue(forKey: key)
        }
        for key in replacement.keys {
            if let children = replacement.childrenByParent[key] {
                childrenByParent[key] = children
            }
        }
        return true
    }
}

// MARK: - Outline Steps

/// One instruction for `NSOutlineView`, in the order the outline must be given it.
///
/// Indexes are a parent's *child* indexes, not rows, and each parent's are independent — which
/// is what lets the whole update be one flat list rather than a per-level dance. AppKit applies
/// the steps in the order given, each against the state the previous ones left, so a removal
/// index reads the list as it stood and an insertion index reads it as it will stand.
enum SidebarOutlineStep: Equatable {
    case remove(parent: SidebarNodeKey?, indexes: IndexSet)
    case move(parent: SidebarNodeKey?, from: Int, to: Int)
    case insert(parent: SidebarNodeKey?, indexes: IndexSet)
}

// MARK: - Update

/// Turns two shapes into the steps that take the outline from one to the other.
///
/// Pure, so the interesting half of an animated sidebar can be tested without a window: what the
/// outline is *told* is the part that has to be right, and the part AppKit will throw an
/// exception over when it is not.
enum SidebarOutlineUpdate {

    /// The steps taking `old` to `new`, grouped by phase.
    ///
    /// Removals for every parent come first, then moves, then insertions. Within a phase the
    /// parents are visited in display order. The phases matter for the one case that spans two
    /// parents: a session leaving a branch heading for the project above it is a removal *there*
    /// and an insertion *here*, and doing every removal before any insertion keeps the row from
    /// having to exist in both places at once.
    static func steps(from old: SidebarTreeShape, to new: SidebarTreeShape) -> [SidebarOutlineStep] {
        var removals: [SidebarOutlineStep] = []
        var moves: [SidebarOutlineStep] = []
        var insertions: [SidebarOutlineStep] = []

        // Only parents both shapes know are diffed. A parent the old shape never had arrives
        // whole with its own insertion, and one the new shape has dropped leaves with its
        // parent's removal — in both cases the outline reads its children from the data source
        // rather than from us.
        var pending: [SidebarNodeKey?] = [nil]
        var visited = 0

        while visited < pending.count {
            let parent = pending[visited]
            visited += 1

            let before = old.children(of: parent)
            let after = new.children(of: parent)
            let beforeSet = Set(before)
            let afterSet = Set(after)

            // Descend only into rows that stayed under *this* parent. A row that changed
            // parents is re-inserted whole, and diffing the children of a row the outline is
            // about to rebuild would describe a subtree that no longer exists.
            //
            // Children in *either* shape, not just the new one: a project whose last session
            // was deleted has no entry left, and skipping it there was a row that stayed on
            // screen with nothing behind it.
            let survivors = after.filter { beforeSet.contains($0) }
            pending.append(
                contentsOf: survivors.filter {
                    new.childrenByParent[$0] != nil || old.childrenByParent[$0] != nil
                }
            )

            guard before != after else { continue }

            let removed = IndexSet(before.indices.filter { !afterSet.contains(before[$0]) })
            if !removed.isEmpty {
                removals.append(.remove(parent: parent, indexes: removed))
            }

            // Survivors in the order they are in now, walked into the order they must end in.
            // Each step settles one position and never disturbs the ones already settled, so a
            // list that only shuffled costs one move per row that actually moved.
            var current = before.filter { afterSet.contains($0) }
            for (index, key) in survivors.enumerated() where current[index] != key {
                guard let from = current.firstIndex(of: key) else { continue }
                moves.append(.move(parent: parent, from: from, to: index))
                current.remove(at: from)
                current.insert(key, at: index)
            }

            let inserted = IndexSet(after.indices.filter { !beforeSet.contains(after[$0]) })
            if !inserted.isEmpty {
                insertions.append(.insert(parent: parent, indexes: inserted))
            }
        }

        return removals + moves + insertions
    }

    /// Hands a freshly built tree's content to the nodes already on screen, returning the roots
    /// to present.
    ///
    /// The outline identifies a row by the object it was handed, so a rebuild that replaces
    /// every node replaces every row — which is a reload, whatever it is called, and cannot be
    /// animated, cannot keep a name morphing from the one it is replacing, and cannot keep a
    /// row's expansion. Reusing the object for each surviving identity is what makes the
    /// difference between "these rows moved" and "this list is now a different list".
    static func adopt(_ rebuilt: [NSObject], reusing presented: [NSObject]) -> [NSObject] {
        // A cold outline has no identities to preserve. Walking every rebuilt node twice to
        // prove that, then asking each node to adopt its own children, made initial mounting pay
        // the full structural-update machinery for a list that had never been presented.
        guard !presented.isEmpty else { return rebuilt }

        var presentedByKey: [SidebarNodeKey: NSObject] = [:]
        func index(_ nodes: [NSObject]) {
            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                presentedByKey[node.sidebarKey] = node
                index(node.sidebarChildren)
            }
        }
        index(presented)

        // Which node stands in for each rebuilt one: the presented node of the same identity
        // where there is one, else the rebuilt node itself.
        var nodesByRebuilt: [ObjectIdentifier: NSObject] = [:]
        func choose(_ nodes: [NSObject]) {
            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                if let survivor = presentedByKey[node.sidebarKey], type(of: survivor) == type(of: node) {
                    nodesByRebuilt[ObjectIdentifier(node)] = survivor
                }
                choose(node.sidebarChildren)
            }
        }
        choose(rebuilt)

        // Then, with every substitution known, move the content across. Done in a second pass
        // because a node's children are resolved to survivors that the first pass may not have
        // reached yet.
        let substitution = SidebarNodeSubstitution(nodesByRebuilt: nodesByRebuilt)
        func transplant(_ nodes: [NSObject]) {
            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                transplant(node.sidebarChildren)
                substitution(node).adoptContent(of: node, substituting: substitution)
            }
        }
        transplant(rebuilt)

        return rebuilt.map { substitution($0) }
    }
}

private extension SidebarNodeSubstitution {
    /// The surviving node for a rebuilt one, as the protocol rather than the concrete type —
    /// which is all the transplant needs, and keeps the walk free of casts.
    func callAsFunction(_ rebuilt: any SidebarOutlineNode) -> any SidebarOutlineNode {
        callAsFunction(rebuilt as NSObject) as? any SidebarOutlineNode ?? rebuilt
    }
}
