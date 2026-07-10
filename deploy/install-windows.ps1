# install-windows.ps1 — register the tailmon agent on the Windows box.
#
# RUN ONCE, MANUALLY, IN AN *ADMIN* POWERSHELL by the machine owner:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1
#
# (An ssh session is NOT elevated — this script cannot be run remotely by an
# automation agent. Dropping tailmon.exe in the home dir is all a remote
# session should ever do; this script handles the rest.)
#
# What it does:
#   1. copies tailmon.exe (from the same directory, or %USERPROFILE%) to C:\Tools\tailmon\
#   2. registers a Task Scheduler ONSTART task running as SYSTEM
#   3. starts it now

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

$dest = "C:\Tools\tailmon"
$exe  = Join-Path $dest "tailmon.exe"

# Find the built exe: next to this script, else the user's home dir (where a
# remote `scp dist/tailmon-windows-amd64.exe barat@...:tailmon.exe` lands it).
$candidates = @(
    (Join-Path $PSScriptRoot "tailmon.exe"),
    (Join-Path $PSScriptRoot "tailmon-windows-amd64.exe"),
    (Join-Path $env:USERPROFILE "tailmon.exe")
)
$src = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $src) {
    Write-Error "tailmon.exe not found (looked in: $($candidates -join ', '))"
    exit 1
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Force $src $exe
Write-Host "copied $src -> $exe"

# ONSTART task as SYSTEM: survives logoff, starts with the machine.
schtasks /create /f /sc onstart /ru SYSTEM /tn tailmon-agent /tr "`"$exe`" agent"
schtasks /run /tn tailmon-agent

Start-Sleep -Seconds 2
try {
    $health = Invoke-RestMethod "http://127.0.0.1:7020/health"
    Write-Host "tailmon agent is up: version $($health.version), rss $($health.rss_mb) MB"
} catch {
    Write-Warning "agent not answering yet on 127.0.0.1:7020 — check: schtasks /query /tn tailmon-agent"
}
