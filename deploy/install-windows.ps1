# install-windows.ps1 --- register the tailmon agent on the Windows box.
#
# RUN ONCE in an *elevated* context:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1
#
# (If your ssh sessions carry an admin token - e.g. the key is in
# administrators_authorized_keys - this can be run remotely over ssh.)
# NOTE: keep this file ASCII-only - PowerShell 5.1 parses BOM-less UTF-8
# as ANSI and multi-byte characters corrupt string literals.
#
# What it does:
#   1. copies tailmon.exe (from the same directory, or %USERPROFILE%) to C:\Tools\tailmon\
#   2. runs `tailmon service install`: Task Scheduler ONSTART task as SYSTEM,
#      started right away

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

# The scheduled task itself (ONSTART as SYSTEM, no 72h execution limit, runs
# on battery, restart on failure, below-normal priority) is written by the
# binary - the same code every install route uses.
& $exe service install
if ($LASTEXITCODE -ne 0) {
    Write-Error "tailmon service install failed (exit $LASTEXITCODE)"
    exit 1
}

Start-Sleep -Seconds 2
try {
    $health = Invoke-RestMethod "http://127.0.0.1:7020/health"
    Write-Host "tailmon agent is up: version $($health.version), rss $($health.rss_mb) MB"
} catch {
    Write-Warning "agent not answering yet on 127.0.0.1:7020 --- check: schtasks /query /tn tailmon-agent"
}
