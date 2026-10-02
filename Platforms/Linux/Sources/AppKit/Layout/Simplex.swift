import Foundation

/// A two-phase simplex that keeps its tableau, so the second solve is not a second solve.
///
/// Round two measured the from-scratch version at roughly 8× per doubling — five seconds for
/// eighty sidebar rows. That is what a dense simplex costs when every layout pass starts over, and
/// it is the reason the draft's phrase is "own the solver **and its invalidation contract**"
/// rather than "own the solver".
///
/// So this keeps `B⁻¹` alongside the tableau. Changing a constraint's `constant` changes only the
/// right-hand side of the program, which leaves the basis dual-feasible — the objective did not
/// move — and lets a handful of *dual* simplex pivots restore primal feasibility instead of a
/// fresh phase one and phase two. That is Cassowary's actual contribution, reduced to the one case
/// that matters most in a running window: a resize, a scroll offset, an animated constant.
///
/// Still dense, and still solves one whole subtree at a time. Both are known and measured rather
/// than assumed; see FINDINGS.
struct Simplex {

    enum Relation { case equal, lessThanOrEqual, greaterThanOrEqual }

    struct Row {
        var coefficients: [Int: Double]
        var relation: Relation
        var constant: Double
    }

    /// A solved program that can be re-solved after its constants move.
    @MainActor
    final class Solution {

        fileprivate var tableau: [[Double]]
        fileprivate var basis: [Int]
        /// Columns `[0, pivotable)` are real, slack and artificial variables. The `rowCount`
        /// columns after them carry `B⁻¹`, and the last column is the right-hand side.
        fileprivate let pivotable: Int
        fileprivate let rowCount: Int
        fileprivate let variableCount: Int
        fileprivate let artificials: Set<Int>
        fileprivate let cost: [Double]
        /// Each prepared row's sign flip, so a new constant can be prepared the same way.
        fileprivate let flipped: [Bool]

        /// Every variable's value, including the error terms.
        public private(set) var values: [Double]
        /// How many pivots the last update needed — the number that says whether warm-starting
        /// worked or quietly degenerated into a cold solve.
        public private(set) var lastPivotCount: Int = 0

        fileprivate init(
            tableau: [[Double]],
            basis: [Int],
            pivotable: Int,
            rowCount: Int,
            variableCount: Int,
            artificials: Set<Int>,
            cost: [Double],
            flipped: [Bool]
        ) {
            self.tableau = tableau
            self.basis = basis
            self.pivotable = pivotable
            self.rowCount = rowCount
            self.variableCount = variableCount
            self.artificials = artificials
            self.cost = cost
            self.flipped = flipped
            values = []
            readBack()
        }

        private var rhsColumn: Int { pivotable + rowCount }

        private func readBack() {
            var result = [Double](repeating: 0, count: variableCount)
            for (index, variable) in basis.enumerated() where variable < variableCount {
                result[variable] = tableau[index][rhsColumn]
            }
            values = result
        }

        /// Re-solve after the constants moved, reusing the basis. `constants` is in the caller's
        /// original row order and sign.
        ///
        /// Returns false when the new right-hand side cannot be satisfied — which means the
        /// constraint set became contradictory, not that the caller should lay out at zero.
        func update(constants: [Double]) -> Bool {
            precondition(constants.count == rowCount)
            // b′ = B⁻¹ · b, using the same sign preparation the original rows went through.
            for row in 0..<rowCount {
                var value = 0.0
                for source in 0..<rowCount {
                    let coefficient = tableau[row][pivotable + source]
                    guard coefficient != 0 else { continue }
                    value += coefficient * (flipped[source] ? -constants[source] : constants[source])
                }
                tableau[row][rhsColumn] = value
            }
            let feasible = dualSimplex()
            guard feasible else { return false }
            // An artificial left basic at a non-zero value means the required rows now contradict.
            for (index, variable) in basis.enumerated() where artificials.contains(variable) {
                if abs(tableau[index][rhsColumn]) > 1e-6 { return false }
            }
            readBack()
            return true
        }

        /// Restore primal feasibility from a dual-feasible basis. The objective has not changed,
        /// so the reduced costs are still non-negative and only the right-hand side can be wrong.
        private func dualSimplex(iterationLimit: Int = 5_000) -> Bool {
            lastPivotCount = 0
            var iterations = 0
            while true {
                iterations += 1
                guard iterations <= iterationLimit else { return false }

                var leaving = -1
                var mostNegative = -1e-7
                for row in 0..<rowCount where tableau[row][rhsColumn] < mostNegative {
                    mostNegative = tableau[row][rhsColumn]
                    leaving = row
                }
                guard leaving >= 0 else { return true }

                var reduced = cost
                for (index, variable) in basis.enumerated() {
                    let multiplier = cost[variable]
                    guard multiplier != 0 else { continue }
                    for column in 0..<pivotable {
                        reduced[column] -= multiplier * tableau[index][column]
                    }
                }

                var entering = -1
                var bestRatio = Double.greatestFiniteMagnitude
                for column in 0..<pivotable where tableau[leaving][column] < -1e-9 {
                    let ratio = reduced[column] / -tableau[leaving][column]
                    if ratio < bestRatio - 1e-12 {
                        bestRatio = ratio
                        entering = column
                    }
                }
                // No column can take the pivot: the program is primal infeasible.
                guard entering >= 0 else { return false }

                pivot(row: leaving, column: entering)
                lastPivotCount += 1
            }
        }

        private func pivot(row: Int, column: Int) {
            let divisor = tableau[row][column]
            for index in 0...rhsColumn { tableau[row][index] /= divisor }
            for other in 0..<rowCount where other != row {
                let factor = tableau[other][column]
                guard factor != 0 else { continue }
                for index in 0...rhsColumn {
                    tableau[other][index] -= factor * tableau[row][index]
                }
            }
            basis[row] = column
        }
    }

    /// Minimize `objective · x` subject to `rows`, with every variable ≥ 0.
    @MainActor
    static func solve(
        objective: [Int: Double],
        rows: [Row],
        variableCount: Int,
        iterationLimit: Int = 20_000
    ) -> Solution? {
        guard !rows.isEmpty else { return nil }

        // Standard form, step one: every right-hand side non-negative.
        var prepared: [Row] = []
        var flipped: [Bool] = []
        for row in rows {
            var row = row
            if row.constant < 0 {
                row.constant = -row.constant
                row.coefficients = row.coefficients.mapValues { -$0 }
                switch row.relation {
                case .equal: break
                case .lessThanOrEqual: row.relation = .greaterThanOrEqual
                case .greaterThanOrEqual: row.relation = .lessThanOrEqual
                }
                flipped.append(true)
            } else {
                flipped.append(false)
            }
            prepared.append(row)
        }

        // Step two: a slack per ≤, a surplus plus an artificial per ≥, an artificial per =.
        enum Extra { case slack(Int), surplus(Int), artificial(Int) }
        var extras: [Extra] = []
        for (index, row) in prepared.enumerated() {
            switch row.relation {
            case .lessThanOrEqual: extras.append(.slack(index))
            case .greaterThanOrEqual:
                extras.append(.surplus(index))
                extras.append(.artificial(index))
            case .equal:
                extras.append(.artificial(index))
            }
        }
        let pivotable = variableCount + extras.count
        let rowCount = prepared.count
        let rhsColumn = pivotable + rowCount

        var tableau: [[Double]] = prepared.map { row in
            var line = [Double](repeating: 0, count: rhsColumn + 1)
            for (variable, coefficient) in row.coefficients where variable < variableCount {
                line[variable] = coefficient
            }
            line[rhsColumn] = row.constant
            return line
        }
        // The B⁻¹ block starts as the identity and is carried through every pivot.
        for row in 0..<rowCount { tableau[row][pivotable + row] = 1 }

        var artificials: Set<Int> = []
        var basisFor: [Int: Int] = [:]
        var column = variableCount
        for extra in extras {
            switch extra {
            case .slack(let row):
                tableau[row][column] = 1
                basisFor[row] = column
            case .surplus(let row):
                tableau[row][column] = -1
            case .artificial(let row):
                tableau[row][column] = 1
                artificials.insert(column)
                basisFor[row] = column
            }
            column += 1
        }

        var basis = (0..<rowCount).map { basisFor[$0] ?? -1 }
        guard !basis.contains(-1) else { return nil }

        // Phase one: drive the artificials to zero, or declare the required rows unsatisfiable.
        if !artificials.isEmpty {
            var phaseOne = [Double](repeating: 0, count: pivotable)
            for artificial in artificials { phaseOne[artificial] = 1 }
            guard let residual = optimize(
                tableau: &tableau, basis: &basis, cost: phaseOne,
                pivotable: pivotable, rhsColumn: rhsColumn, iterationLimit: iterationLimit
            ), residual <= 1e-6 else { return nil }
        }

        // Phase two: the weighted sum of the soft constraints' error terms. The artificials keep a
        // large cost rather than being zeroed out of the tableau, because `B⁻¹` has to stay a true
        // inverse for the incremental path — and a basic artificial at zero is legitimate.
        var cost = [Double](repeating: 0, count: pivotable)
        for (variable, coefficient) in objective where variable < pivotable {
            cost[variable] = coefficient
        }
        for artificial in artificials { cost[artificial] = 1e12 }

        guard optimize(
            tableau: &tableau, basis: &basis, cost: cost,
            pivotable: pivotable, rhsColumn: rhsColumn, iterationLimit: iterationLimit
        ) != nil else { return nil }

        for (index, variable) in basis.enumerated() where artificials.contains(variable) {
            if abs(tableau[index][rhsColumn]) > 1e-6 { return nil }
        }

        return Solution(
            tableau: tableau,
            basis: basis,
            pivotable: pivotable,
            rowCount: rowCount,
            variableCount: variableCount,
            artificials: artificials,
            cost: cost,
            flipped: flipped
        )
    }

    /// The primal simplex, over an already-feasible basis. Returns the objective value.
    private static func optimize(
        tableau: inout [[Double]],
        basis: inout [Int],
        cost: [Double],
        pivotable: Int,
        rhsColumn: Int,
        iterationLimit: Int
    ) -> Double? {
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= iterationLimit else { return nil }

            var reduced = cost
            for (index, variable) in basis.enumerated() {
                let multiplier = cost[variable]
                guard multiplier != 0 else { continue }
                for column in 0..<pivotable {
                    reduced[column] -= multiplier * tableau[index][column]
                }
            }

            // Bland's rule: the lowest-index improving column, which cannot cycle. Slower than
            // steepest-edge and the only pivot rule worth trusting in code nobody will tune.
            var entering = -1
            for column in 0..<pivotable where reduced[column] < -1e-9 {
                entering = column
                break
            }
            guard entering >= 0 else {
                var value = 0.0
                for (index, variable) in basis.enumerated() {
                    value += cost[variable] * tableau[index][rhsColumn]
                }
                return value
            }

            var leaving = -1
            var bestRatio = Double.greatestFiniteMagnitude
            for index in tableau.indices where tableau[index][entering] > 1e-9 {
                let ratio = tableau[index][rhsColumn] / tableau[index][entering]
                if ratio < bestRatio - 1e-9 {
                    bestRatio = ratio
                    leaving = index
                } else if abs(ratio - bestRatio) <= 1e-9, leaving >= 0, basis[index] < basis[leaving] {
                    leaving = index
                }
            }
            guard leaving >= 0 else { return nil }

            let divisor = tableau[leaving][entering]
            for column in 0...rhsColumn { tableau[leaving][column] /= divisor }
            for index in tableau.indices where index != leaving {
                let factor = tableau[index][entering]
                guard factor != 0 else { continue }
                for column in 0...rhsColumn {
                    tableau[index][column] -= factor * tableau[leaving][column]
                }
            }
            basis[leaving] = entering
        }
    }
}
