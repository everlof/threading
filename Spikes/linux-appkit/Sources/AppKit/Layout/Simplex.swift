import Foundation

/// A dense two-phase simplex, which is the honest way to answer the draft's open question about
/// layout: it says "a Cassowary-family solver is a candidate, not a decision", and the way to find
/// out is to put a real linear solver under our real constraint sets and look at what comes out —
/// both the geometry and the clock.
///
/// Deliberately *not* incremental. Cassowary's whole contribution is editing a live tableau
/// cheaply; this re-solves from scratch on every layout pass. That is the wrong long-term answer
/// and the right spike: it separates "can our constraints be expressed and solved correctly" from
/// "can they be re-solved fast enough", so the second question gets measured rather than assumed
/// away. `LayoutBenchmark` reports what it costs.
struct Simplex {

    enum Relation { case equal, lessThanOrEqual, greaterThanOrEqual }

    struct Row {
        var coefficients: [Int: Double]
        var relation: Relation
        var constant: Double
    }

    /// Minimize `objective · x` subject to `rows`, with every variable ≥ 0.
    ///
    /// Returns nil when the rows are infeasible or unbounded. A caller must treat that as a broken
    /// constraint set and say so — never as a layout of zeros, which is how an unsatisfiable
    /// constraint turns into an invisible view instead of a diagnosable one.
    static func minimize(
        objective: [Int: Double],
        rows: [Row],
        variableCount: Int,
        iterationLimit: Int = 20_000
    ) -> [Double]? {
        guard !rows.isEmpty else { return [Double](repeating: 0, count: variableCount) }

        // Standard form, step one: every right-hand side non-negative.
        var prepared: [Row] = []
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
            }
            prepared.append(row)
        }

        // Step two: a slack column per ≤, a surplus plus an artificial per ≥, an artificial per =.
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
        let columnCount = variableCount + extras.count

        var tableau: [[Double]] = prepared.map { row in
            var line = [Double](repeating: 0, count: columnCount + 1)
            for (variable, coefficient) in row.coefficients where variable < variableCount {
                line[variable] = coefficient
            }
            line[columnCount] = row.constant
            return line
        }

        var artificials: [Int] = []
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
                artificials.append(column)
                basisFor[row] = column
            }
            column += 1
        }

        var basis = (0..<prepared.count).map { basisFor[$0] ?? -1 }
        guard !basis.contains(-1) else { return nil }

        // Phase one: drive the artificials to zero, or declare the required rows unsatisfiable.
        if !artificials.isEmpty {
            var phaseOne = [Double](repeating: 0, count: columnCount)
            for artificial in artificials { phaseOne[artificial] = 1 }
            guard let residual = optimize(
                tableau: &tableau, basis: &basis, cost: phaseOne,
                columnCount: columnCount, iterationLimit: iterationLimit
            ), residual <= 1e-6 else { return nil }
            // Keep the artificials out of the phase-two basis.
            for artificial in artificials where !basis.contains(artificial) {
                for index in tableau.indices { tableau[index][artificial] = 0 }
            }
        }

        // Phase two: the real objective — the weighted sum of the soft constraints' error terms.
        var cost = [Double](repeating: 0, count: columnCount)
        for (variable, coefficient) in objective where variable < columnCount {
            cost[variable] = coefficient
        }
        guard optimize(
            tableau: &tableau, basis: &basis, cost: cost,
            columnCount: columnCount, iterationLimit: iterationLimit
        ) != nil else { return nil }

        var result = [Double](repeating: 0, count: variableCount)
        for (index, variable) in basis.enumerated() where variable < variableCount {
            result[variable] = tableau[index][columnCount]
        }
        return result
    }

    /// One optimization over an already-feasible basis; returns the objective value, or nil if the
    /// problem is unbounded or the iteration limit is reached.
    private static func optimize(
        tableau: inout [[Double]],
        basis: inout [Int],
        cost: [Double],
        columnCount: Int,
        iterationLimit: Int
    ) -> Double? {
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= iterationLimit else { return nil }

            // Reduced costs from the current basis.
            var reduced = cost
            for (index, variable) in basis.enumerated() {
                let multiplier = cost[variable]
                guard multiplier != 0 else { continue }
                for column in 0..<columnCount {
                    reduced[column] -= multiplier * tableau[index][column]
                }
            }

            // Bland's rule: the *lowest-index* improving column, which cannot cycle. Slower than
            // steepest-edge and the only pivot rule worth trusting in code nobody will tune.
            var entering = -1
            for column in 0..<columnCount where reduced[column] < -1e-9 {
                entering = column
                break
            }
            guard entering >= 0 else {
                var value = 0.0
                for (index, variable) in basis.enumerated() {
                    value += cost[variable] * tableau[index][columnCount]
                }
                return value
            }

            var leaving = -1
            var bestRatio = Double.greatestFiniteMagnitude
            for index in tableau.indices where tableau[index][entering] > 1e-9 {
                let ratio = tableau[index][columnCount] / tableau[index][entering]
                if ratio < bestRatio - 1e-9 {
                    bestRatio = ratio
                    leaving = index
                } else if abs(ratio - bestRatio) <= 1e-9, leaving >= 0, basis[index] < basis[leaving] {
                    leaving = index
                }
            }
            guard leaving >= 0 else { return nil }

            let pivot = tableau[leaving][entering]
            for column in 0...columnCount { tableau[leaving][column] /= pivot }
            for index in tableau.indices where index != leaving {
                let factor = tableau[index][entering]
                guard factor != 0 else { continue }
                for column in 0...columnCount {
                    tableau[index][column] -= factor * tableau[leaving][column]
                }
            }
            basis[leaving] = entering
        }
    }
}
