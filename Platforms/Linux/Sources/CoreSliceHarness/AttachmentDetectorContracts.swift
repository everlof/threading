@testable import CoreSlice
import Foundation

/// The Linux host exercises the exact detector used by macOS before attaching a live pane.
func runAttachmentDetectorContracts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-attachment-detector-\(UUID().uuidString)",
                              isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let insideImage = project.appendingPathComponent("render.tiff")
    let insideReport = project.appendingPathComponent("report.png")
    let outsideImage = outside.appendingPathComponent("private.png")
    let outsideReport = outside.appendingPathComponent("report.png")
    for file in [insideImage, insideReport, outsideImage, outsideReport] {
        try Data("fixture".utf8).write(to: file)
    }
    let escapedOutside = project.appendingPathComponent("outside-link.png")
    try FileManager.default.createSymbolicLink(at: escapedOutside, withDestinationURL: outsideImage)

    let text = "`\(insideImage.path)` \(outsideImage.path) report.png `\(escapedOutside.path)`"
    let found = AttachmentReferenceDetector.resolve(
        text: text, projectRoot: project, currentDirectory: outside)
    try require(found.insideProject == [insideImage, insideReport],
                "same-name project file wins and .tiff is not truncated")
    try require(found.outsideProject == [outsideImage],
                "outside file and symlink cannot become project references")
    try require(AttachmentReferenceDetector.kind(for: insideImage) == .image,
                "shared kind classifier recognizes a TIFF image")

    let many = (0..<600).map { "missing\($0).png" }.joined(separator: " ")
    try require(AttachmentReferenceDetector.candidates(in: many).count
                == AttachmentReferenceDetector.maximumCandidatesPerScan,
                "untrusted output scan stops at its candidate ceiling")
    print("PASS shared attachment detector: project scope, symlink, suffix and bounded scan")
}
