# Repository entry point. The app exports the canonical installer as a standalone file.
[CmdletBinding()]
param(
    [string]$Distribution,
    [string]$LinuxUser
)
$installer = Join-Path $PSScriptRoot '..\..\Sources\Threading\Resources\RemoteHosts\install-wsl-startup.ps1'
& $installer @PSBoundParameters
