@testable import CoreSlice
import Foundation

func runTerminalPlanContracts() throws {
    let project = Project(name: "Owner", folderURL:
        URL(fileURLWithPath: "/work/ägare 日本語/space & percent %", isDirectory: true))
    let terminal = ProjectTerminal(id: TerminalID(), title: "Shell", customTitle: nil,
        currentDirectory: "/another checkout/日本語 👩🏽‍💻", branch: nil, themeID: nil,
        soundOverrides: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let available = ProjectTerminalStartPlan(terminal: terminal, project: project,
                                             preferredDirectoryIsAvailable: true)
    try require(available.terminalID == terminal.id && available.projectID == project.id,
                "recorded cwd retains typed terminal and owning project identities")
    try require(available.directory.path == terminal.currentDirectory,
                "host-admitted recorded directory is used without discovery")

    let fallback = ProjectTerminalStartPlan(terminal: terminal, project: project,
                                            preferredDirectoryIsAvailable: false)
    try require(fallback.directory == project.folderURL,
                "unavailable recorded directory falls back to owning project with Unicode intact")
    try require(fallback.terminalID == terminal.id && fallback.projectID == project.id,
                "fallback cannot replace terminal identity or move project ownership")
    var refused = terminal
    refused.currentDirectory = "/"
    try require(ProjectTerminalStartPlan(terminal: refused, project: project,
                preferredDirectoryIsAvailable: false).directory == project.folderURL,
                "host refusal remains authoritative even for a real filesystem directory")
    print("PASS shared terminal start plan: host availability, typed ownership and Unicode fallback")
}
