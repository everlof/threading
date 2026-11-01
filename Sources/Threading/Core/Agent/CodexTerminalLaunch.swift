import Foundation

/// A terminal and its queue client must address the same app-server. The ordinary Codex TUI
/// embeds one when per-session config overrides exclude it from the shared daemon.
enum CodexTerminalLaunch {
    static let directory = "/tmp/threading-codex-\(getuid())"

    static func socketPath(for sessionID: SessionID) -> String {
        "\(directory)/\(sessionID.uuidString.lowercased()).sock"
    }

    /// Resolution happens before wrapping so both processes use the selected installation.
    /// The env/account prefix remains outside the long-lived shell: no credential enters its
    /// script or argv. The PTY owns the supervisor, server and TUI as one process group.
    static func wrap(_ command: ShellCommand, server: ShellCommand, socketPath: String,
                     store: ManagedAgentRuntimeStore?) -> ShellCommand {
        let resolved = store?.resolve(command) ?? (command, [:])
        let server = store?.resolve(server).command ?? server
        guard let executable = resolved.0.executableWord else { return command }
        let wrapped = resolved.0.replacingExecutable(with: "/bin/sh", arguments: [
            "-c", script(server: server, socketPath: socketPath), "threading-codex", executable
        ])
        guard !resolved.1.isEmpty else { return wrapped }
        var environment = ShellCommand(word: "env")
        for key in resolved.1.keys.sorted() { environment.append(word: "\(key)=\(resolved.1[key]!)") }
        environment.append(contentsOf: wrapped)
        return environment
    }

    static func script(server: ShellCommand, socketPath: String) -> String {
        let directory = (socketPath as NSString).deletingLastPathComponent
        // All variable input remains a quoted shell word, including the server invocation.
        var assignDirectory = ShellCommand(word: "set")
        assignDirectory.append(operator: .endOfOptions)
        assignDirectory.append(word: directory)
        assignDirectory.append(word: socketPath)
        let locations = assignDirectory.source
        return """
        threading_codex="$1"; shift
        if ! "$threading_codex" app-server --help 2>/dev/null | /usr/bin/grep -q 'unix://PATH'; then
            exec "$threading_codex" "$@"
        fi
        if ! "$threading_codex" queue --help 2>/dev/null | /usr/bin/grep -q -- '--remote'; then
            exec "$threading_codex" "$@"
        fi
        threading_locations() { \(locations); threading_dir="$1"; threading_socket="$2"; }
        threading_locations
        umask 077
        [ ! -L "$threading_dir" ] && /bin/mkdir -p "$threading_dir" || exit 1
        [ "$(/usr/bin/stat -f '%u:%Lp' "$threading_dir")" = "$(/usr/bin/id -u):700" ] || exit 1
        if [ -e "$threading_socket" ] || [ -L "$threading_socket" ]; then
            [ ! -L "$threading_socket" ] || exit 1
            if /usr/bin/nc -z -U -w 1 "$threading_socket" >/dev/null 2>&1; then
                printf '%s\\n' 'This Codex terminal already has a running server.' >&2; exit 1
            fi
            /bin/rm -f "$threading_socket" || exit 1
        fi
        threading_server=''
        threading_cleanup() {
            trap - EXIT HUP TERM
            if [ -n "$threading_server" ]; then
                kill "$threading_server" 2>/dev/null
                threading_stops=0
                while kill -0 "$threading_server" 2>/dev/null; do
                    threading_stops=$((threading_stops + 1))
                    [ "$threading_stops" -lt 40 ] || { kill -KILL "$threading_server" 2>/dev/null; break; }
                    sleep 0.05
                done
                wait "$threading_server" 2>/dev/null
            fi
            /bin/rm -f "$threading_socket"
        }
        trap threading_cleanup EXIT
        trap 'exit 143' HUP TERM
        \(server.source) </dev/null >/dev/null &
        threading_server=$!
        threading_attempt=0
        while [ ! -S "$threading_socket" ]; do
            kill -0 "$threading_server" 2>/dev/null || exit 1
            threading_attempt=$((threading_attempt + 1))
            [ "$threading_attempt" -lt 200 ] || exit 1
            sleep 0.05
        done
        "$threading_codex" --remote "unix://$threading_socket" "$@"
        threading_status=$?
        exit "$threading_status"
        """
    }
}
