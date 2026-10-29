@testable import CoreSlice
import Foundation

/// Exercise the exact Mac store on Linux at the custody and read boundaries.
@MainActor
func runAttachmentStoreContracts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-attachment-store-\(UUID().uuidString)", isDirectory: true)
    let project = directory.appendingPathComponent("project", isDirectory: true)
    let outside = directory.appendingPathComponent("outside", isDirectory: true)
    let custody = directory.appendingPathComponent("custody", isDirectory: true)
    for url in [project, outside, custody] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: directory) }

    let projectImage = project.appendingPathComponent("chart.png")
    let outsideImage = outside.appendingPathComponent("private.png")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: projectImage)
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outsideImage)
    let escape = project.appendingPathComponent("escape.png")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideImage)

    let session = SessionID()
    var payloads: [SessionID: String] = [:]
    var allowsOutside = false
    func makeStore() -> SessionAttachmentStore {
        SessionAttachmentStore(
            loadPayload: { payloads[$0] },
            savePayload: { payload, id in payloads[id] = payload },
            copiesDirectory: { custody },
            referenceRoot: { _ in project },
            allowsFilesOutsideProject: { allowsOutside }
        )
    }

    let store = makeStore()
    store.recordReferences(
        in: "saved \(projectImage.path) \(outsideImage.path) \(escape.path)",
        sessionID: session, projectRoot: project
    )
    try require(store.attachments(for: session).map(\.name) == ["chart.png"],
                "only the in-project reference is initially readable")
    try require(store.countOfFilesOutsideProject(for: session) == 1,
                "the outside file is withheld without becoming readable")
    try require(payloads[session] != nil, "the admitted reference persists")

    allowsOutside = true
    let admitted = store.admitWithheldFilesOutsideProject(for: session)
    try require(admitted.count == 1 && admitted[0].isOutsideProject,
                "widening scope admits the withheld file")
    try require(admitted[0].url.path.hasPrefix(custody.path + "/"),
                "outside file is copied into app custody")
    try require(try Data(contentsOf: admitted[0].url) == Data(contentsOf: outsideImage),
                "custody copy has the original bytes")

    allowsOutside = false
    try require(store.attachments(for: session).map(\.name) == ["chart.png"],
                "narrowing scope hides the copied outside file at read time")
    allowsOutside = true
    let restored = makeStore()
    try require(restored.attachments(for: session).count == 2,
                "a new store reloads the same persisted references and custody")

    try FileManager.default.removeItem(at: projectImage)
    try require(restored.attachments(for: session).count == 1,
                "deleted project references are pruned on read")
    print("PASS shared attachment store custody, scope, reload and pruning")
}
