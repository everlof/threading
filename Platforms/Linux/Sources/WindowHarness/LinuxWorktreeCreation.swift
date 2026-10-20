import Foundation
@testable import CoreSlice

/// Repository mutation for the two host-owned New Worktree entry points. Call only on a
/// bounded worker; Git and the project import both touch disk and may block.
enum LinuxWorktreeCreation {
    static func create(branch: String, from projectPath: String) throws -> String {
        guard !branch.isEmpty, branch.utf8.count <= 255, !branch.contains("\n"),
              !branch.contains("\r"), !branch.contains("\0") else {
            throw WindowFailure("Enter a valid branch name.")
        }
        guard let checkout = LinuxGitCheckout.read(at: projectPath) else {
            throw WindowFailure("This project is not inside a git repository.")
        }
        let root = URL(fileURLWithPath: checkout.root, isDirectory: true)
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(safeBranch)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WindowFailure("\(destination.path) already exists.")
        }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        git.currentDirectoryURL = root
        git.arguments = ["-k", "2", "15", "/usr/bin/git", "worktree", "add", "-b",
                         branch, destination.path]
        git.standardInput = FileHandle.nullDevice
        let output = Pipe()
        git.standardOutput = output
        git.standardError = output
        try git.run()
        var bytes = Data()
        var exceeded = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if bytes.count + chunk.count > 4096 { exceeded = true }
            else if !exceeded { bytes.append(chunk) }
        }
        git.waitUntilExit()
        guard git.terminationStatus != 124, git.terminationStatus != 137 else {
            throw WindowFailure("Git timed out while creating the worktree.")
        }
        guard git.terminationStatus == 0 else {
            let detail = String(data: bytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Git failed"
            throw WindowFailure(exceeded ? "Git error exceeded its display limit." : detail)
        }
        guard let created = LinuxGitCheckout.read(at: destination.path),
              created.root == destination.path,
              created.repositoryIdentity == checkout.repositoryIdentity else {
            throw WindowFailure("Git did not create the expected worktree.")
        }
        return destination.path
    }
}
