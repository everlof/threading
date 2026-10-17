import Foundation

struct RemoteHostAvailabilityDidChange: AppEvent {
    static let name = Notification.Name("RemoteHostAvailabilityDidChange")
    let coordinator: ObjectIdentifier
    let destination: RemoteHostDestination
}

/// Availability after this connection ends is separate from whether the host answers now.
/// These are observed configuration facts, never a promise that a machine is powered on.
struct RemoteHostAvailability: Equatable, Sendable {
    enum Startup: String, Sendable { case unknown, automatic, manual }
    enum Sleep: String, Sendable { case unknown, maySleep, idleDisabled }
    enum Platform: String, Sendable { case unknown, linux, wsl }

    var startup: Startup = .unknown
    var sleep: Sleep = .unknown
    var platform: Platform = .unknown
}

struct RemoteHostAvailabilityCheck: Equatable, Sendable {
    var facts = RemoteHostAvailability()
    var checkedAt: Date?
    var isChecking = false
    var failed = false
}

/// One bounded, read-only SSH command, outside the launch critical path. No power settings,
/// services, tasks, credentials or controller workers are changed by a check.
enum RemoteHostAvailabilityProbe {
    static let timeout: TimeInterval = 20

    static func parse(_ output: String) -> RemoteHostAvailability? {
        guard output.utf8.count <= 8192 else { return nil }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard values["availability"] == "1",
              let platform = RemoteHostAvailability.Platform(rawValue: values["platform"] ?? "") else { return nil }
        var result = RemoteHostAvailability(platform: platform)
        let linuxReady = values["linger"] == "yes" && values["services"] == "enabled" && values["ssh"] == "enabled"
        if values["linger"] == "no" || values["services"] == "disabled" {
            result.startup = .manual
        } else if linuxReady, platform == .linux {
            result.startup = .automatic
        }
        guard platform == .wsl else { return result }

        // A task for another WSL distribution or Unix account proves nothing about this host.
        let root = values["wslRoot"] ?? ""
        let distribution = root.hasPrefix("\\\\wsl.localhost\\") || root.hasPrefix("\\\\wsl$\\")
            ? root.split(separator: "\\").last.map(String.init) : nil
        let matchesHost = values["home"]?.hasPrefix("/") == true && values["user"]?.isEmpty == false
            && distribution != nil && distribution == values["taskDistro"]
            && values["user"] == values["taskUser"]
            && values["taskScript"] == (values["home"] ?? "") + "/.local/lib/threading/wsl-startup/keep-running.sh"
        if matchesHost {
            if values["taskStartup"] == "manual" { result.startup = .manual }
            if linuxReady, values["taskStartup"] == "automatic" { result.startup = .automatic }
        }
        // Both AC and battery values are required. A missing/unrecognized answer is unknown,
        // never zero. These are idle timers; lid closure/manual sleep remain separate.
        if let ac = values["sleepAC"].flatMap(UInt32.init), let dc = values["sleepDC"].flatMap(UInt32.init),
           let hibernateAC = values["hibernateAC"].flatMap(UInt32.init),
           let hibernateDC = values["hibernateDC"].flatMap(UInt32.init) {
            result.sleep = [ac, dc, hibernateAC, hibernateDC].contains(where: { $0 > 0 }) ? .maySleep : .idleDisabled
        }
        return result
    }

    static var script: String {
        let encoded = Data(windowsScript.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
        return #"""
        set -u
        command -v timeout >/dev/null 2>&1 || exit 1
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        printf 'availability=1\nhome=%s\nuser=%s\n' "$HOME" "$(id -un)"
        printf 'linger=%s\n' "$(timeout 3 loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
        services=unknown
        # The controller bundle's unit, or the single active app-managed instance. Multiple
        # generations are ambiguous and must not become an automatic-start claim.
        unit=
        if timeout 3 systemctl --user is-active --quiet threading-ptyd.service 2>/dev/null; then
          unit=threading-ptyd.service
        else
          units=$(timeout 3 systemctl --user list-units 'threading-ptyd@*.service' --state=active --plain --no-legend 2>/dev/null | head -n 2 | awk '{print $1}')
          case "$units" in *'
        '*|'') ;; *) unit=$units ;; esac
        fi
        if [ -n "$unit" ]; then
          value=$(timeout 3 systemctl --user is-enabled "$unit" 2>/dev/null)
          case "$value" in enabled) services=enabled ;; disabled|masked|enabled-runtime) services=disabled ;; esac
        fi
        printf 'services=%s\n' "$services"
        ssh_boot=unknown
        for ssh_unit in ssh.service sshd.service ssh.socket sshd.socket; do
          value=$(timeout 1 systemctl is-enabled "$ssh_unit" 2>/dev/null)
          if [ "$value" = enabled ]; then ssh_boot=enabled; break; fi
        done
        printf 'ssh=%s\n' "$ssh_boot"
        case "$(uname -r)" in
          *[Mm]icrosoft*|*WSL*)
            printf 'platform=wsl\n'
            printf 'wslRoot=%s\n' "$(wslpath -w / 2>/dev/null)"
            powershell=$(command -v powershell.exe 2>/dev/null || true)
            [ -n "$powershell" ] || powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
            if [ -x "$powershell" ]; then
              timeout 10 "$powershell" -NoLogo -NoProfile -NonInteractive -EncodedCommand \#(encoded) 2>/dev/null | tr -d '\r'
            fi
            ;;
          *) printf 'platform=linux\n' ;;
        esac
        exit 0
        """#
    }

    /// Bounded queries for our one task and two power settings. Never enumerate all tasks,
    /// processes or credentials. Match the action before emitting any of its arguments.
    static let windowsScript = #"""
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
        try {
          $task = Get-ScheduledTask -TaskName 'Threading WSL Host' -TaskPath '\' -ErrorAction Stop
          $action = @($task.Actions)
          if ($action.Count -eq 1 -and [IO.Path]::GetFileName($action[0].Execute) -ieq 'wsl.exe' -and
              $action[0].Arguments -match '^-d (?<distro>[A-Za-z0-9._-]+) -u (?<user>[a-z_][a-z0-9_-]*) --exec /bin/sh (?<script>/[A-Za-z0-9/_.-]+/keep-running\.sh)$') {
            "taskDistro=$($Matches.distro)"
            "taskUser=$($Matches.user)"
            "taskScript=$($Matches.script)"
            $boot = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and $_.Enabled })
            $owner = [Security.Principal.NTAccount]::new($task.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value
            $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ($owner -eq $current -and (-not $task.Settings.Enabled -or $boot.Count -eq 0 -or $task.Principal.LogonType -eq 'Interactive')) {
              'taskStartup=manual'
            } elseif ($owner -eq $current -and $task.Principal.LogonType -in @('S4U', 'Password') -and
                      $task.Settings.ExecutionTimeLimit -eq 'PT0S' -and
                      -not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries) {
              'taskStartup=automatic'
            }
          }
        } catch { }
        foreach ($setting in @(@('STANDBYIDLE', 'sleep'), @('HIBERNATEIDLE', 'hibernate'))) {
          try {
            $text = (& "$env:SystemRoot\System32\powercfg.exe" /query SCHEME_CURRENT SUB_SLEEP $setting[0]) -join "`n"
            if ($LASTEXITCODE -ne 0) { continue }
            # The final two hexadecimal fields are the AC/DC indices; the preceding fields
            # describe the allowed range. Their labels are localized, their order is fixed.
            $indices = [regex]::Matches($text, '0x([0-9a-fA-F]{8})\s*(?:\r?\n|$)')
            if ($indices.Count -eq 5) {
              "$($setting[1])AC=$([Convert]::ToUInt32($indices[3].Groups[1].Value, 16))"
              "$($setting[1])DC=$([Convert]::ToUInt32($indices[4].Groups[1].Value, 16))"
            }
          } catch { }
        }
        """#
}
