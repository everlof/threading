import Foundation

/// Turns a view's active constraints into a linear program, solves it, and writes frames back.
///
/// The coordinate space inside the solve is **root-absolute and top-down**, for two reasons. A
/// constraint may reach across the tree to any common ancestor, so a per-superview space would
/// need conversions inside the solve; and `topAnchor` means the visual top regardless of whether a
/// view is flipped, which is a statement about the layout space, not about the drawing one. The
/// flip is applied once, on the way out, when each frame is written into its superview's space.
///
/// The program is rebuilt every pass — that is cheap, linear in the constraints — but the *solve*
/// is not. When the rebuilt program differs from the last one only in its constants, the retained
/// tableau is warm-started instead, which is the difference between a resize costing seconds and
/// costing a frame. See `Simplex`.
@MainActor
public enum LayoutEngine {

    /// Six columns per item. `width`/`height` are non-negative by construction, so only the
    /// origins are split into a positive and a negative part — the standard way to give a simplex
    /// a free variable when every column must be ≥ 0.
    private enum Column: Int {
        case xPositive = 0, xNegative, yPositive, yNegative, width, height
        static let stride = 6
    }

    public struct Diagnosis {
        public var itemCount: Int
        public var constraintCount: Int
        public var rowCount: Int
        public var variableCount: Int
        /// False means the required constraints could not all be met. A caller must surface that;
        /// a layout of zeros is how an unsatisfiable constraint becomes an invisible view.
        public var solved: Bool
        public var seconds: Double
        /// True when the retained tableau was reused because only constants had moved.
        public var incremental: Bool = false
        /// Dual-simplex pivots taken on the incremental path. A number near the row count means
        /// the warm start degenerated into a cold solve and is no longer buying anything.
        public var pivots: Int = 0
    }

    // MARK: - The retained program

    private final class Cache {
        var itemKeys: [ObjectIdentifier]
        var rows: [Simplex.Row]
        var objective: [Int: Double]
        var variableCount: Int
        var solution: Simplex.Solution
        var lastUsed: UInt64 = 0

        init(
            itemKeys: [ObjectIdentifier],
            rows: [Simplex.Row],
            objective: [Int: Double],
            variableCount: Int,
            solution: Simplex.Solution
        ) {
            self.itemKeys = itemKeys
            self.rows = rows
            self.objective = objective
            self.variableCount = variableCount
            self.solution = solution
        }

        /// Whether a freshly built program is the same program with different numbers on the
        /// right. Compared rather than hashed: a false positive here silently lays the window out
        /// against the wrong constraints, and the comparison is linear in a program we just built.
        func matchesStructure(
            itemKeys: [ObjectIdentifier],
            rows: [Simplex.Row],
            objective: [Int: Double],
            variableCount: Int
        ) -> Bool {
            guard self.variableCount == variableCount,
                  self.itemKeys == itemKeys,
                  self.rows.count == rows.count,
                  self.objective == objective else { return false }
            for (mine, theirs) in zip(self.rows, rows) {
                if mine.relation != theirs.relation { return false }
                if mine.coefficients != theirs.coefficients { return false }
            }
            return true
        }
    }

    private static var caches: [ObjectIdentifier: Cache] = [:]
    private static var fittingCaches: [ObjectIdentifier: Cache] = [:]
    private static var fittingUse: UInt64 = 0
    private static let maximumFittingCaches = 128

    /// Drop a root's retained tableau. Called when a tree is torn down; also the escape hatch if a
    /// caller wants to prove a cold number.
    public static func forget(_ root: NSView) {
        caches.removeValue(forKey: ObjectIdentifier(root))
        fittingCaches.removeValue(forKey: ObjectIdentifier(root))
    }

    public static func forgetAll() {
        caches.removeAll()
        fittingCaches.removeAll()
        fittingUse = 0
    }

    // MARK: - Laying out

    @discardableResult
    public static func layout(_ root: NSView) -> Diagnosis {
        solve(root, measuring: false).diagnosis
    }

    /// Measure the constraints with a 50-priority zero-size proposal, as AppKit's fitting
    /// pass does. This never writes frames into the live tree; a later layout still uses the
    /// actual root frame and its separate warm-start tableau.
    public static func fittingSize(of root: NSView) -> NSSize {
        solve(root, measuring: true).size ?? .zero
    }

    private static func solve(_ root: NSView, measuring: Bool)
        -> (diagnosis: Diagnosis, size: NSSize?) {
        let started = Date()

        var items: [NSLayoutItem] = []
        var indexOf: [ObjectIdentifier: Int] = [:]
        func register(_ item: NSLayoutItem) {
            let key = ObjectIdentifier(item)
            guard indexOf[key] == nil else { return }
            indexOf[key] = items.count
            items.append(item)
        }

        func collect(_ view: NSView) {
            register(view)
            for guide in view.layoutGuides { register(guide) }
            for subview in view.subviews { collect(subview) }
        }
        collect(root)

        var constraints: [NSLayoutConstraint] = []
        func gather(_ view: NSView) {
            constraints.append(contentsOf: view.activeConstraints)
            for subview in view.subviews { gather(subview) }
        }
        gather(root)

        // A fixed-frame tree has no equations to solve. A navigator viewport can mount dozens
        // of labels whose owners already placed them; feeding those frames into simplex makes
        // a resize or selection pay for a large required-constraint tableau to rediscover the
        // same rectangles. A single explicit Auto Layout item or constraint keeps the solver.
        if !measuring && constraints.isEmpty && items.allSatisfy({ item in
            guard let view = item as? NSView else { return false }
            return view.translatesAutoresizingMaskIntoConstraints
        }) {
            return (Diagnosis(itemCount: items.count, constraintCount: 0, rowCount: 0,
                              variableCount: 0, solved: true,
                              seconds: Date().timeIntervalSince(started)), nil)
        }

        let variableCount = items.count * Column.stride
        var rows: [Simplex.Row] = []
        var objective: [Int: Double] = [:]
        var nextError = variableCount

        func column(_ item: NSLayoutItem, _ which: Column) -> Int {
            indexOf[ObjectIdentifier(item)]! * Column.stride + which.rawValue
        }

        /// A layout attribute as a linear expression over the item's six columns, plus its
        /// constant. Font baselines are measured offsets inside a view, and a centred label's
        /// baseline also moves with a fraction of its solved height.
        func expression(_ item: NSLayoutItem, _ attribute: NSLayoutConstraint.Attribute)
            -> (terms: [Int: Double], offset: Double) {
            let x = [column(item, .xPositive): 1.0, column(item, .xNegative): -1.0]
            let y = [column(item, .yPositive): 1.0, column(item, .yNegative): -1.0]
            let width = column(item, .width)
            let height = column(item, .height)
            switch attribute {
            case .left, .leading: return (x, 0)
            case .right, .trailing: return (x.merging([width: 1], uniquingKeysWith: +), 0)
            case .centerX: return (x.merging([width: 0.5], uniquingKeysWith: +), 0)
            case .top: return (y, 0)
            case .bottom: return (y.merging([height: 1], uniquingKeysWith: +), 0)
            case .centerY: return (y.merging([height: 0.5], uniquingKeysWith: +), 0)
            case .width: return ([width: 1], 0)
            case .height: return ([height: 1], 0)
            case .firstBaseline, .lastBaseline:
                let metric: NSBaselineMetric
                if let view = item as? NSView {
                    metric = attribute == .firstBaseline
                        ? view.firstBaselineMetric : view.lastBaselineMetric
                } else {
                    metric = NSBaselineMetric(
                        heightFraction: attribute == .lastBaseline ? 1 : 0, offset: 0)
                }
                return (y.merging([height: Double(metric.heightFraction)], uniquingKeysWith: +),
                        Double(metric.offset))
            case .notAnAttribute: return ([:], 0)
            }
        }

        func add(
            _ terms: [Int: Double],
            _ relation: Simplex.Relation,
            _ constant: Double,
            priority: NSLayoutConstraint.Priority
        ) {
            guard !terms.isEmpty else { return }
            if priority >= .required {
                rows.append(Simplex.Row(coefficients: terms, relation: relation, constant: constant))
                return
            }
            // A soft constraint is the same row with somewhere to put its failure, and the
            // objective pays for that failure in proportion to the priority. This is the whole of
            // what a priority *means*, and it is why a priority cannot be honoured by a sort order.
            var terms = terms
            let weight = Double(priority.rawValue)
            switch relation {
            case .equal:
                let over = nextError, under = nextError + 1
                nextError += 2
                terms[over] = -1
                terms[under] = 1
                objective[over] = weight
                objective[under] = weight
            case .lessThanOrEqual:
                let slack = nextError
                nextError += 1
                terms[slack] = -1
                objective[slack] = weight
            case .greaterThanOrEqual:
                let slack = nextError
                nextError += 1
                terms[slack] = 1
                objective[slack] = weight
            }
            rows.append(Simplex.Row(coefficients: terms, relation: relation, constant: constant))
        }

        // The root is the frame everything else is measured against.
        add([column(root, .xPositive): 1, column(root, .xNegative): -1], .equal, 0, priority: .required)
        add([column(root, .yPositive): 1, column(root, .yNegative): -1], .equal, 0, priority: .required)
        add([column(root, .width): 1], .equal, measuring ? 0 : Double(root.frame.width),
            priority: measuring ? .fittingSizeCompression : .required)
        add([column(root, .height): 1], .equal, measuring ? 0 : Double(root.frame.height),
            priority: measuring ? .fittingSizeCompression : .required)

        for item in items {
            // A view still translating its autoresizing mask keeps the frame it was given. Mixing
            // the two is normal and load-bearing: most of this app's constraint code hangs off a
            // container whose own frame comes from a split view.
            if item !== root, let view = item as? NSView,
               view.translatesAutoresizingMaskIntoConstraints {
                let absolute = rootAbsolute(view, root: root)
                add([column(item, .xPositive): 1, column(item, .xNegative): -1], .equal, Double(absolute.minX), priority: .required)
                add([column(item, .yPositive): 1, column(item, .yNegative): -1], .equal, Double(absolute.minY), priority: .required)
                add([column(item, .width): 1], .equal, Double(absolute.width), priority: .required)
                add([column(item, .height): 1], .equal, Double(absolute.height), priority: .required)
                continue
            }

            // Intrinsic size enters as the pair AppKit describes: hugging pulls the edge in,
            // compression resistance pushes it out, and the two priorities decide who wins.
            if let view = item as? NSView, item !== root || measuring {
                let intrinsic = view.intrinsicContentSize
                if intrinsic.width != NSView.noIntrinsicMetric {
                    add([column(item, .width): 1], .lessThanOrEqual, Double(intrinsic.width),
                        priority: view.contentHuggingPriority(for: .horizontal))
                    add([column(item, .width): 1], .greaterThanOrEqual, Double(intrinsic.width),
                        priority: view.contentCompressionResistancePriority(for: .horizontal))
                }
                if intrinsic.height != NSView.noIntrinsicMetric {
                    add([column(item, .height): 1], .lessThanOrEqual, Double(intrinsic.height),
                        priority: view.contentHuggingPriority(for: .vertical))
                    add([column(item, .height): 1], .greaterThanOrEqual, Double(intrinsic.height),
                        priority: view.contentCompressionResistancePriority(for: .vertical))
                }
            }
        }

        for constraint in constraints {
            guard let first = constraint.firstItem as? NSLayoutItem,
                  indexOf[ObjectIdentifier(first)] != nil else { continue }
            let firstExpression = expression(first, constraint.firstAttribute)
            var terms = firstExpression.terms
            var constant = Double(constraint.constant) - firstExpression.offset
            if let second = constraint.secondItem as? NSLayoutItem,
               indexOf[ObjectIdentifier(second)] != nil,
               constraint.secondAttribute != .notAnAttribute {
                let secondExpression = expression(second, constraint.secondAttribute)
                for (variable, coefficient) in secondExpression.terms {
                    terms[variable, default: 0] -= coefficient * Double(constraint.multiplier)
                }
                constant += secondExpression.offset * Double(constraint.multiplier)
            }
            let relation: Simplex.Relation
            switch constraint.relation {
            case .equal: relation = .equal
            case .lessThanOrEqual: relation = .lessThanOrEqual
            case .greaterThanOrEqual: relation = .greaterThanOrEqual
            }
            add(terms, relation, constant, priority: constraint.priority)
        }

        // The tie-break. An under-determined system has many feasible vertices and AppKit's choice
        // among them is its own; this one prefers the smallest, topmost, leftmost, at a weight far
        // below any real priority so it can never outvote one. Ambiguity resolving *somewhere* is
        // not the same as resolving where AppKit would — see FINDINGS.
        for index in items.indices {
            let base = index * Column.stride
            for offset in 0..<Column.stride {
                objective[base + offset, default: 0] += 1e-4
            }
        }

        var diagnosis = Diagnosis(
            itemCount: items.count,
            constraintCount: constraints.count,
            rowCount: rows.count,
            variableCount: nextError,
            solved: false,
            seconds: 0
        )

        let key = ObjectIdentifier(root)
        let itemKeys = items.map { ObjectIdentifier($0) }
        var solution: Simplex.Solution?
        if measuring { fittingUse &+= 1 }

        let cacheForMode = measuring ? fittingCaches[key] : caches[key]
        if let cache = cacheForMode,
           cache.matchesStructure(itemKeys: itemKeys, rows: rows, objective: objective, variableCount: nextError),
           cache.solution.update(constants: rows.map(\.constant)) {
            solution = cache.solution
            cache.rows = rows
            if measuring { cache.lastUsed = fittingUse }
            diagnosis.incremental = true
            diagnosis.pivots = cache.solution.lastPivotCount
        } else {
            solution = Simplex.solve(objective: objective, rows: rows, variableCount: nextError)
            if let solution {
                let retained = Cache(
                    itemKeys: itemKeys,
                    rows: rows,
                    objective: objective,
                    variableCount: nextError,
                    solution: solution
                )
                if measuring {
                    retained.lastUsed = fittingUse
                    fittingCaches[key] = retained
                    if fittingCaches.count > maximumFittingCaches,
                       let oldest = fittingCaches.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                        fittingCaches.removeValue(forKey: oldest.key)
                    }
                } else {
                    caches[key] = retained
                }
            } else {
                if measuring { fittingCaches.removeValue(forKey: key) }
                else { caches.removeValue(forKey: key) }
            }
        }

        diagnosis.solved = solution != nil

        var fittedSize: NSSize?
        if let solution {
            let values = solution.values
            if measuring {
                fittedSize = NSSize(width: CGFloat(values[Column.width.rawValue]),
                                    height: CGFloat(values[Column.height.rawValue]))
            }
            var absolute: [ObjectIdentifier: NSRect] = [:]
            for (index, item) in items.enumerated() {
                let base = index * Column.stride
                absolute[ObjectIdentifier(item)] = NSRect(
                    x: CGFloat(values[base] - values[base + 1]),
                    y: CGFloat(values[base + 2] - values[base + 3]),
                    width: CGFloat(values[base + 4]),
                    height: CGFloat(values[base + 5])
                )
            }
            for item in items where !measuring && !(item === root) {
                guard let box = absolute[ObjectIdentifier(item)],
                      let superview = item.layoutSuperview,
                      let container = absolute[ObjectIdentifier(superview)] else { continue }
                let frame = NSRect(
                    x: box.minX - container.minX,
                    // The single place the drawing coordinate system re-enters.
                    y: superview.isFlipped
                        ? box.minY - container.minY
                        : (container.minY + container.height) - (box.minY + box.height),
                    width: box.width,
                    height: box.height
                )
                if let view = item as? NSView, !view.translatesAutoresizingMaskIntoConstraints {
                    view.setLaidOutFrame(frame)
                } else if let guide = item as? NSLayoutGuide {
                    guide.frame = frame
                }
            }
        }

        diagnosis.seconds = Date().timeIntervalSince(started)
        return (diagnosis, fittedSize)
    }

    /// A frame-driven view's current rectangle, expressed in the solve's root-absolute top-down
    /// space so it can be pinned there.
    private static func rootAbsolute(_ view: NSView, root: NSView) -> NSRect {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var cursor: NSView? = view
        let size = view.frame.size
        while let current = cursor, current !== root, let superview = current.superview {
            x += current.frame.minX
            y += superview.isFlipped
                ? current.frame.minY
                : superview.frame.height - current.frame.maxY
            cursor = superview
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
