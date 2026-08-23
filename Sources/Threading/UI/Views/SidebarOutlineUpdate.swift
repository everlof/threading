import AppKit

// MARK: - Tree Shape

/// The sidebar's shape: which rows exist, nested how, in what order.
///
/// Deliberately carries identities rather than content — a session's title and a project's name
/// are absent, so a rename compares equal and takes the in-place refresh path. A branch heading's
/// *name* is part of its identity and is therefore included: a branch heading gathers the rows
/// standing on one branch, so a different name usually means different rows.
///
/// Usually, not always. When the heading's members are exactly the ones it already had, the
/// checkout moved and took every row with it, and the group was relabelled rather than replaced —
/// `SidebarOutlineUpdate.branchRenames(from:to:)` finds that case and `renamingKeys` folds it
/// out of the comparison, so the diff describes a rename instead of a removal and an arrival.
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

    /// Inserts one new leaf without reconstructing the containing project's complete shape.
    /// Returns false when the caller's presented-node assumptions do not match this ledger.
    mutating func insertLeaf(
        _ key: SidebarNodeKey,
        into parent: SidebarNodeKey,
        at index: Int
    ) -> Bool {
        guard keys.contains(parent),
              !keys.contains(key),
              childrenByParent[key] == nil else { return false }
        var siblings = childrenByParent[parent] ?? []
        guard siblings.indices.contains(index) || index == siblings.endIndex else { return false }
        siblings.insert(key, at: index)
        childrenByParent[parent] = siblings
        keys.insert(key)
        return true
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

    /// This shape with the given identities substituted, leaving every position untouched.
    ///
    /// Used on the *presented* shape before diffing, so a row whose key carries a display value
    /// that moved — a branch heading, and nothing else today — compares equal to the row that
    /// replaced it instead of being described as a departure and an arrival at the same index.
    func renamingKeys(_ renames: [SidebarNodeKey: SidebarNodeKey]) -> SidebarTreeShape {
        guard !renames.isEmpty else { return self }

        var renamed = SidebarTreeShape()
        renamed.keys = Set(keys.map { renames[$0] ?? $0 })
        renamed.childrenByParent.reserveCapacity(childrenByParent.count)
        for (parent, children) in childrenByParent {
            renamed.childrenByParent[parent.map { renames[$0] ?? $0 }] =
                children.map { renames[$0] ?? $0 }
        }
        return renamed
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

    /// The branch headings `new` merely relabelled, as old key → new key.
    ///
    /// A checkout switching branch moves every row standing in it at once, so the heading over
    /// them ends up with a new name and exactly the membership it already had. Keyed by name, that
    /// reads as a group leaving and another arriving: the outline fades the heading and every row
    /// under it out, inserts a closed heading, and re-expands it — the branch visibly disappearing
    /// and coming back, with the group's collapsed state and the name's morph lost on the way.
    ///
    /// The test is membership, because membership is what a group *is*. Only a lone departure
    /// answered by a lone arrival under one parent qualifies; two branches merging into one, or a
    /// switch that also gains or loses a chat, is a genuine regrouping and still moves rows.
    static func branchRenames(
        from old: SidebarTreeShape,
        to new: SidebarTreeShape
    ) -> [SidebarNodeKey: SidebarNodeKey] {
        var renames: [SidebarNodeKey: SidebarNodeKey] = [:]

        for (parent, after) in new.childrenByParent {
            // Runs on every structural reload, so the parents that did not change — every one of
            // them, on the pass this exists for — cost a comparison and no allocation, exactly
            // as they do in `steps`.
            let before = old.children(of: parent)
            guard !before.isEmpty, before != after else { continue }

            let beforeSet = Set(before)
            let afterSet = Set(after)
            let leaving = before.filter { $0.branchGroup != nil && !afterSet.contains($0) }
            let arriving = after.filter { $0.branchGroup != nil && !beforeSet.contains($0) }
            guard leaving.count == 1, arriving.count == 1,
                  let from = leaving.first, let to = arriving.first else { continue }

            // A heading with no children cannot prove it is the same heading, and the builder
            // never makes one — so an empty membership is a shape we do not recognise.
            let members = old.children(of: from)
            guard !members.isEmpty, members == new.children(of: to) else { continue }

            renames[from] = to
        }

        return renames
    }

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
    ///
    /// `renames` maps a presented identity to the rebuilt identity standing for the same row, for
    /// the one row whose key carries a display value — see `branchRenames(from:to:)`. Without it a
    /// relabelled branch heading looks like a stranger and is replaced, which discards the row the
    /// outline is showing along with its expansion and the name it would have morphed from.
    static func adopt(
        _ rebuilt: [NSObject],
        reusing presented: [NSObject],
        renaming renames: [SidebarNodeKey: SidebarNodeKey] = [:]
    ) -> [NSObject] {
        // A cold outline has no identities to preserve. Walking every rebuilt node twice to
        // prove that, then asking each node to adopt its own children, made initial mounting pay
        // the full structural-update machinery for a list that had never been presented.
        guard !presented.isEmpty else { return rebuilt }

        var presentedByKey: [SidebarNodeKey: NSObject] = [:]
        func index(_ nodes: [NSObject]) {
            for node in nodes {
                guard let node = node as? any SidebarOutlineNode else { continue }
                let key = node.sidebarKey
                presentedByKey[renames[key] ?? key] = node
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
