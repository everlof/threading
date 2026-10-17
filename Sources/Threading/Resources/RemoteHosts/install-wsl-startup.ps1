#Requires -RunAsAdministrator
<#
Start an existing Threading WSL host at Windows boot, without an interactive login or a
stored password. Run as the Windows account that owns the distribution. This installs no
binaries and never restarts services or enables controller workers.

Example (Administrator PowerShell):
  .\install-wsl-startup.ps1 -Distribution Ubuntu-24.04 -LinuxUser threading

To stop automatic startup, disable the "Threading WSL Host" task in Task Scheduler before
stopping it. Otherwise its five-minute recovery trigger will start WSL again.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Distribution = 'Ubuntu-24.04',
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$LinuxUser = 'threading'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:WSL_UTF8 = '1'
$taskName = 'Threading WSL Host'
$description = 'Threading-managed WSL startup: keeps the existing Linux host available for remote chats.'
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing -and $existing.Description -ne $description) {
    throw "A different task already uses the name '$taskName'; it was not changed."
}

# All shell text goes over stdin, not through PowerShell's native-argument quoting. No
# provider login, SSH private key or Windows password is read or stored by this installer.
$install = @'
set -eu
umask 077
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
[ "$(ps -p 1 -o comm=)" = systemd ] || { echo 'Enable systemd in /etc/wsl.conf first.' >&2; exit 1; }
[ "$(loginctl show-user "$(id -un)" -p Linger --value)" = yes ] || { echo 'Enable linger for the Linux user first.' >&2; exit 1; }
systemctl is-enabled --quiet ssh.service
systemctl --user is-enabled --quiet threading-ptyd.service
systemctl --user is-enabled --quiet threading-controller.service
directory="$HOME/.local/lib/threading/wsl-startup"
mkdir -p "$directory"
temporary=$(mktemp "$directory/keep-running.XXXXXX")
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" <<'KEEPER'
#!/bin/sh
set -eu
umask 077
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
# A cold boot may still be bringing up the lingering user's systemd manager.
attempt=0
until systemctl --user show-environment >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || exit 1
    sleep 2
done
timeout 60 systemctl --user start threading-ptyd.service threading-controller.service
systemctl --user is-active --quiet threading-ptyd.service
systemctl --user is-active --quiet threading-controller.service
mkdir -p "$HOME/.local/state/threading"
printf '%s\n' "$$" > "$HOME/.local/state/threading/wsl-startup.pid"
# systemd services alone do not hold WSL open. This foreground process does, without
# a visible terminal, a polling loop, or a change to Windows sleep/power settings.
exec /bin/sleep infinity
KEEPER
chmod 700 "$temporary"
mv -f "$temporary" "$directory/keep-running.sh"
printf '%s\n' "$directory/keep-running.sh"
'@
$result = ($install.Replace("`r`n", "`n") + "`n# end") |
    & $wsl -d $Distribution -u $LinuxUser --exec /bin/sh -s
if ($LASTEXITCODE -ne 0) { throw 'The existing Linux host did not pass the startup prerequisites.' }
$keeper = ($result | Select-Object -Last 1).Trim()
if ($keeper -notmatch '^/[A-Za-z0-9/_.-]+/keep-running\.sh$') { throw 'Unexpected Linux startup helper path.' }

$action = New-ScheduledTaskAction -Execute $wsl -Argument "-d $Distribution -u $LinuxUser --exec /bin/sh $keeper"
# S4U uses the distribution owner's profile without storing their Windows password.
# The task only starts a local executable; Linux services make their own network connections.
$principal = New-ScheduledTaskPrincipal -UserId $owner -LogonType S4U -RunLevel Limited
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $owner),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5))
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Description $description -Action $action `
    -Principal $principal -Trigger $triggers -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output "Installed and started '$taskName' for $owner ($Distribution / $LinuxUser)."
Write-Output 'Startup is enabled at boot and logon, with a five-minute recovery trigger and no run-time limit.'
Write-Output "Check: Get-ScheduledTask -TaskName '$taskName'; Get-ScheduledTaskInfo -TaskName '$taskName'"
