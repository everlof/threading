import Foundation

/// Captures terminal output from shell integration for AI analysis.
final class OutputCapture {

    // MARK: - Properties

    /// Path to the file containing the last command's output.
    private(set) var lastOutputPath: String?

    /// Exit code of the last command.
    private(set) var lastExitCode: Int32?

    /// The last executed command.
    private(set) var lastCommand: String?

    // MARK: - Initialization

    init() {}

    // MARK: - OSC Sequence Handling

    /// Handles custom OSC sequences from shell integration.
    /// Expected format: SkalmanOutput=/path;ExitCode=1;Cmd=some command
    func handleOSCSequence(_ params: String) {
        // Parse the semicolon-separated parameters
        let parts = params.split(separator: ";")

        for part in parts {
            let keyValue = part.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }

            let key = String(keyValue[0])
            let value = String(keyValue[1])

            switch key {
            case "SkalmanOutput":
                lastOutputPath = value
            case "ExitCode":
                lastExitCode = Int32(value)
            case "Cmd":
                lastCommand = value
            default:
                break
            }
        }
    }

    // MARK: - Output Retrieval

    /// Returns the content of the last command's output, if available.
    func getLastOutput() -> String? {
        // Try OSC-provided path first
        if let path = lastOutputPath, FileManager.default.fileExists(atPath: path) {
            return readOutputFile(at: path)
        }

        // Fall back to standard location
        if FileManager.default.fileExists(atPath: standardOutputPath) {
            return readOutputFile(at: standardOutputPath)
        }

        return nil
    }

    private func readOutputFile(at path: String) -> String? {
        do {
            let output = try String(contentsOfFile: path, encoding: .utf8)
            // Limit to max output length
            if output.count > AIDefaults.maxOutputLength {
                return String(output.prefix(AIDefaults.maxOutputLength)) + "\n... (output truncated)"
            }
            return output
        } catch {
            return nil
        }
    }

    /// Returns true if output capture data is available.
    var hasOutput: Bool {
        // Check the well-known temp file location
        if let path = lastOutputPath, FileManager.default.fileExists(atPath: path) {
            return true
        }
        // Also check the standard location used by shell integration
        return FileManager.default.fileExists(atPath: standardOutputPath)
    }

    /// Standard path where shell integration stores output.
    private var standardOutputPath: String {
        let tmpDir = NSTemporaryDirectory()
        return (tmpDir as NSString).appendingPathComponent("skalman-last-output.txt")
    }

    /// Standard path where shell integration stores the last command.
    private var standardCommandPath: String {
        let tmpDir = NSTemporaryDirectory()
        return (tmpDir as NSString).appendingPathComponent("skalman-last-cmd.txt")
    }

    /// Standard path where shell integration stores the exit code.
    private var standardExitCodePath: String {
        let tmpDir = NSTemporaryDirectory()
        return (tmpDir as NSString).appendingPathComponent("skalman-last-exit.txt")
    }

    /// Gets the last command from the standard file location.
    func getLastCommand() -> String? {
        if let cmd = lastCommand, !cmd.isEmpty {
            return cmd
        }
        // Read from file
        if let cmd = try? String(contentsOfFile: standardCommandPath, encoding: .utf8) {
            return cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Gets the last exit code from the standard file location.
    func getLastExitCode() -> Int32 {
        if let code = lastExitCode {
            return code
        }
        // Read from file
        if let str = try? String(contentsOfFile: standardExitCodePath, encoding: .utf8),
           let code = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return code
        }
        return 0
    }

    /// Clears the captured output data.
    func clear() {
        // Clean up temp file if it exists
        if let path = lastOutputPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        lastOutputPath = nil
        lastExitCode = nil
        lastCommand = nil
    }
}

// MARK: - Shell Integration

enum ShellIntegration {

    /// Returns the path to the bundled shell integration script.
    static var scriptPath: String? {
        // For development builds, the script is in the source directory
        // For release builds, it should be in the app bundle Resources

        // Check bundle resources first
        if let bundlePath = Bundle.main.path(forResource: "skalman-shell-integration", ofType: "sh") {
            return bundlePath
        }

        // Check Resources directory
        if let resourcePath = Bundle.main.resourcePath {
            let scriptPath = (resourcePath as NSString).appendingPathComponent("skalman-shell-integration.sh")
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }

        // For development: check relative to executable
        let executablePath = Bundle.main.executablePath ?? ""
        let devPath = (executablePath as NSString)
            .deletingLastPathComponent
            .appending("/../../../Sources/Skalman/Resources/skalman-shell-integration.sh")
        let resolvedDevPath = (devPath as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolvedDevPath) {
            return resolvedDevPath
        }

        return nil
    }

    /// Returns the source command to add to shell profile.
    static var sourceCommand: String {
        if let path = scriptPath {
            return "source \"\(path)\""
        } else {
            // Fallback: use a path relative to /Applications
            return "source \"/Applications/Skalman.app/Contents/Resources/skalman-shell-integration.sh\""
        }
    }

    /// Returns full setup instructions.
    static var setupInstructions: String {
        """
        To enable AI output analysis, add this line to your shell profile (.bashrc, .zshrc, etc.):

        \(sourceCommand)

        Then restart your terminal or run: source ~/.bashrc (or ~/.zshrc)
        """
    }
}
