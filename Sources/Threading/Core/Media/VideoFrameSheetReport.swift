import CoreGraphics
import Foundation

// MARK: - Arguments to a request

extension VideoFrameSheetRequest {

    /// Why a set of arguments cannot become a request, in the words the caller gets back.
    ///
    /// Refusals live here rather than on the tool adapter because they are facts about the
    /// request, not about the transport that carried it: `to` before `from` is wrong whether it
    /// arrived over MCP, from a test, or from any later caller.
    static func refusal(for arguments: VideoFramesArguments) -> String? {
        if arguments.path?.isEmpty ?? true {
            return "Missing required argument: path"
        }
        if arguments.crop?.isPartial == true {
            return "crop needs all four of x, y, width and height, or none of them."
        }
        if let from = arguments.from, let to = arguments.to, to < from {
            return "`to` (\(from2(to))) is before `from` (\(from2(from)))."
        }
        if let from = arguments.from, from < 0 {
            return "`from` (\(from2(from))) is before the start of the clip."
        }
        if let frames = arguments.frames, frames < 1 {
            return "`frames` must be at least 1."
        }
        return nil
    }

    init(url: URL, arguments: VideoFramesArguments) {
        self.init(
            url: url,
            start: arguments.from,
            end: arguments.to,
            crop: arguments.crop?.rect,
            frames: arguments.frames
        )
    }

    private static func from2(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }
}

// MARK: - Result to words

extension VideoFrameSheetResult {

    /// Everything the picture cannot say about itself.
    ///
    /// The cell-to-time table is the load-bearing part. The obvious alternative is to burn each
    /// number into its own cell, which is what a `drawtext` filter is for — and the ffmpeg this
    /// was measured against is built without freetype, so that filter does not exist and the
    /// attempt fails twice before anyone remembers why. Text costs nothing and cannot fail.
    func report(fileName: String, destination: String) -> String {
        var lines: [String] = []

        lines.append(
            "\(fileName) — \(Self.seconds(source.duration)), "
                + "\(source.pixelWidth)×\(source.pixelHeight), "
                + "\(Self.rate(source.frameRate)), "
                + (source.hasAudio ? "has audio." : "no audio.")
        )

        var window = "Sampled \(timestamps.count) "
            + (timestamps.count == 1 ? "frame" : "frames")
            + " across \(Self.seconds(windowStart))–\(Self.seconds(windowEnd))"
        if let cropRect {
            window += ", cropped to \(Int(cropRect.width))×\(Int(cropRect.height))"
                + " at (\(Int(cropRect.minX)), \(Int(cropRect.minY)))"
        }
        lines.append(window + ".")

        lines.append(
            "Grid \(columns)×\(rows), reading left to right then down; "
                + "each cell \(cellPixelWidth)×\(cellPixelHeight)."
        )

        lines.append(
            "Cell times — "
                + timestamps.enumerated()
                    .map { "\($0.offset + 1): \(Self.seconds($0.element))" }
                    .joined(separator: "   ")
        )

        if deliveredCellWidth < VideoFrameDefaults.legibleCellWidth {
            lines.append(
                "Each cell is only \(deliveredCellWidth)px wide, which reads as a thumbnail. "
                    + "To see detail, call again with a narrower from/to window, fewer frames, "
                    + "or a crop — asking for more cells only makes them smaller."
            )
        }

        lines.append(destination)
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2fs", value) : "—"
    }

    private static func rate(_ value: Double) -> String {
        value > 0 ? String(format: "%.4g fps", value) : "variable frame rate"
    }
}
