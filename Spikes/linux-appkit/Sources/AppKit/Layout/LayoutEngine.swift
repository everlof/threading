import Foundation

/// Turns a view's active constraints into a linear program, solves it, and writes frames back.
///
/// The coordinate space inside the solve is **root-absolute and top-down**, for two reasons. A
/// constraint may reach across the tree to any common ancestor, so a per-superview space would
/// need conversions inside the solve; and `topAnchor` means the visual top regardless of whether a
/// view is flipped, which is a statement about the layout space, not about the drawing one. The
/// flip is applied once, on the way out, when each frame is written into its superview's space.
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
    }

    @discardableResult
    public static func layout(_ root: NSView) -> Diagnosis {
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

        let variableCount = items.count * Column.stride
        var rows: [Simplex.Row] = []
        var objective: [Int: Double] = [:]
        var nextError = variableCount

        func column(_ item: NSLayoutItem, _ which: Column) -> Int {
            indexOf[ObjectIdentifier(item)]! * Column.stride + which.rawValue
        }

        /// A layout attribute as a linear expression over the item's six columns.
        func expression(_ item: NSLayoutItem, _ attribute: NSLayoutConstraint.Attribute) -> [Int: Double] {
            let x = [column(item, .xPositive): 1.0, column(item, .xNegative): -1.0]
            let y = [column(item, .yPositive): 1.0, column(item, .yNegative): -1.0]
            let width = column(item, .width)
            let height = column(item, .height)
            switch attribute {
            case .left, .leading: return x
            case .right, .trailing: return x.merging([width: 1], uniquingKeysWith: +)
            case .centerX: return x.merging([width: 0.5], uniquingKeysWith: +)
            case .top: return y
            case .bottom: return y.merging([height: 1], uniquingKeysWith: +)
            case .centerY: return y.merging([height: 0.5], uniquingKeysWith: +)
            case .width: return [width: 1]
            case .height: return [height: 1]
            // One recorded liberty: with no text stack there is no baseline, so the first baseline
            // is the top edge and the last is the bottom. Every baseline-aligned row in the app is
            // therefore wrong here by the font's ascender, which is a text problem wearing a
            // layout problem's clothes.
            case .firstBaseline: return y
            case .lastBaseline: return y.merging([height: 1], uniquingKeysWith: +)
            case .notAnAttribute: return [:]
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
        add([column(root, .width): 1], .equal, Double(root.frame.width), priority: .required)
        add([column(root, .height): 1], .equal, Double(root.frame.height), priority: .required)

        for item in items where !(item === root) {
            // A view still translating its autoresizing mask keeps the frame it was given. Mixing
            // the two is normal and load-bearing: most of this app's constraint code hangs off a
            // container whose own frame comes from a split view.
            if let view = item as? NSView, view.translatesAutoresizingMaskIntoConstraints {
                let absolute = rootAbsolute(view, root: root)
                add([column(item, .xPositive): 1, column(item, .xNegative): -1], .equal, Double(absolute.minX), priority: .required)
                add([column(item, .yPositive): 1, column(item, .yNegative): -1], .equal, Double(absolute.minY), priority: .required)
                add([column(item, .width): 1], .equal, Double(absolute.width), priority: .required)
                add([column(item, .height): 1], .equal, Double(absolute.height), priority: .required)
                continue
            }

            // Intrinsic size enters as the pair AppKit describes: hugging pulls the edge in,
            // compression resistance pushes it out, and the two priorities decide who wins.
            if let view = item as? NSView {
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
            var terms = expression(first, constraint.firstAttribute)
            if let second = constraint.secondItem as? NSLayoutItem,
               indexOf[ObjectIdentifier(second)] != nil,
               constraint.secondAttribute != .notAnAttribute {
                for (variable, coefficient) in expression(second, constraint.secondAttribute) {
                    terms[variable, default: 0] -= coefficient * Double(constraint.multiplier)
                }
            }
            let relation: Simplex.Relation
            switch constraint.relation {
            case .equal: relation = .equal
            case .lessThanOrEqual: relation = .lessThanOrEqual
            case .greaterThanOrEqual: relation = .greaterThanOrEqual
            }
            add(terms, relation, Double(constraint.constant), priority: constraint.priority)
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

        let solution = Simplex.minimize(
            objective: objective,
            rows: rows,
            variableCount: nextError
        )

        var diagnosis = Diagnosis(
            itemCount: items.count,
            constraintCount: constraints.count,
            rowCount: rows.count,
            variableCount: nextError,
            solved: solution != nil,
            seconds: 0
        )

        if let solution {
            var absolute: [ObjectIdentifier: NSRect] = [:]
            for (index, item) in items.enumerated() {
                let base = index * Column.stride
                absolute[ObjectIdentifier(item)] = NSRect(
                    x: CGFloat(solution[base] - solution[base + 1]),
                    y: CGFloat(solution[base + 2] - solution[base + 3]),
                    width: CGFloat(solution[base + 4]),
                    height: CGFloat(solution[base + 5])
                )
            }
            for item in items where !(item === root) {
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
        return diagnosis
    }

    /// A frame-driven view's current rectangle, expressed in the solve's root-absolute top-down
    /// space so it can be pinned there.
    private static func rootAbsolute(_ view: NSView, root: NSView) -> NSRect {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var cursor: NSView? = view
        var box = view.frame
        while let current = cursor, current !== root, let superview = current.superview {
            x += current.frame.minX
            y += superview.isFlipped
                ? current.frame.minY
                : superview.frame.height - current.frame.maxY
            cursor = superview
            box = current.frame
        }
        return NSRect(x: x, y: y, width: box.width, height: box.height)
    }
}
