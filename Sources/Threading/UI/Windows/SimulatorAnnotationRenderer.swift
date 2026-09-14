import Foundation

/// Renders the user's pinned Simulator notes into the `simulator_annotations` tool result. A plain
/// enum (not main-actor isolated) so its small, bounded JSON encode does not count as main-actor
/// latency; the browser's annotation reader shapes its payload the same way.
enum SimulatorAnnotationRenderer {
    private struct Payload: Encodable {
        struct Note: Encodable {
            let pin: Int
            let note: String
            let x: Double
            let y: Double
        }

        let provenance: String
        let deviceID: String
        let count: Int
        let annotations: [Note]

        private enum CodingKeys: String, CodingKey {
            case provenance, count, annotations
            case deviceID = "device_id"
        }
    }

    static func result(annotations: [ImageAnnotation], device: SimulatorDevice) -> MCPToolResult {
        let payload = Payload(
            provenance: "user_authored",
            deviceID: device.id.rawValue,
            count: annotations.count,
            annotations: annotations.enumerated().map { index, annotation in
                Payload.Note(
                    pin: index + 1,
                    note: annotation.note,
                    x: Double(annotation.point.x),
                    y: Double(annotation.point.y)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not encode the Simulator notes.")
        }
        return .success(text)
    }
}
