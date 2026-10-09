import Foundation

// MARK: - Reading a chart back out of a tool call

extension ChartSpec {

    /// The chart a `display_chart` call describes, or nil for any other tool.
    ///
    /// A natively rendered conversation sees the same call the panel does, as the arguments the
    /// agent sent. Decoding here — rather than waiting for the tool's textual result — is what
    /// lets the transcript draw the chart itself instead of a line saying a chart was drawn
    /// somewhere else. Anything malformed returns nil and stays an ordinary tool row: the panel
    /// is the surface that refuses a bad call, and the transcript must not refuse it twice.
    static func decoded(fromToolNamed name: String, input: [String: Any]) -> ChartSpec? {
        guard name == MCPToolNaming.allowedToolName(MCPToolNaming.displayChart)
            || name == MCPToolNaming.displayChart
        else { return nil }

        // `series` stays all-or-nothing, and the `count` check further down already says so out
        // loud: a chart drawn from some of its series is not a smaller chart, it is a different
        // chart, and the axis, the legend and the comparison the agent was making all change
        // around the missing one with nothing on the picture to admit it. An element that is not
        // an object costs the whole spec exactly as an unreadable `name` or `values` does, and
        // the call stays an ordinary tool row showing the arguments as sent.
        guard let title = input["title"] as? String, !title.isEmpty,
              let categories = input["categories"] as? [String],
              let rawSeries = input["series"] as? [[String: Any]]
        else { return nil }

        let series: [Series] = rawSeries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            // Numbers arrive as `NSNumber` through the JSON bridge, so `as? [Double]` fails on
            // any array holding an integer literal — which every honest count is.
            guard let values = (entry["values"] as? [NSNumber])?.map(\.doubleValue) else {
                return nil
            }
            return Series(
                name: name,
                values: values,
                details: entry["details"] as? [String],
                emphasis: (entry["emphasis"] as? String).flatMap(Emphasis.init(rawValue:))
            )
        }
        guard series.count == rawSeries.count else { return nil }

        let spec = ChartSpec(
            title: title,
            summary: input["summary"] as? String,
            kind: (input["kind"] as? String).flatMap(Kind.init(rawValue:)) ?? .bar,
            categories: categories,
            series: series,
            stacked: input["stacked"] as? Bool ?? false,
            valueFormat: (input["value_format"] as? String)
                .flatMap(ValueFormat.init(rawValue:)) ?? .number,
            unit: input["unit"] as? String,
            maximumValue: (input["maximum_value"] as? NSNumber)?.doubleValue
        )
        return try? spec.validated()
    }
}
