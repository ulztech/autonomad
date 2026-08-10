# Autonomad v1 — scripts/Stop-Autonomad.ps1
#
# Graceful stop + state handoff (T9/Q17). Stops the container, waits for it to
# exit, then captures heartbeat + run log tail so state can be resumed later.

[CmdletBinding()]
param(
    [string]$Name = 'autonomad',
    [int]$TimeoutSeconds = 30,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

$running = docker ps -a --filter "name=^/$Name$" --format '{{.Names}}' 2>&1
if ("$running".Trim() -ne $Name) {
    Write-Host "Container '$Name' is not running. Nothing to stop."
    exit 0
}

Write-Host "Stopping container '$Name' (timeout ${TimeoutSeconds}s)..."
docker stop -t $TimeoutSeconds $Name
if ($LASTEXITCODE -ne 0) { throw 'docker stop failed' }
Write-Host "Container '$Name' stopped."

# State handoff: copy out last heartbeat + run log to the host reports dir
$hostReports = Join-Path $RepoRoot 'reports'
if (-not (Test-Path -LiteralPath $hostReports)) { New-Item -ItemType Directory -Path $hostReports -Force | Out-Null }

$copied = @()
$heartbeat = docker exec $Name cat /data/last_tick.ts 2>$null
if ("$heartbeat".Trim()) {
    [System.IO.File]::WriteAllText((Join-Path $hostReports 'last_tick.ts'), "$heartbeat", (New-Object System.Text.UTF8Encoding($false)))
    $copied += 'last_tick.ts'
}
$runsLog = docker exec $Name cat /data/logs/runs.log 2>$null
if ("$runsLog".Trim()) {
    [System.IO.File]::WriteAllText((Join-Path $hostReports 'runs.log'), "$runsLog", (New-Object System.Text.UTF8Encoding($false)))
    $copied += 'runs.log'
}
Write-Host "State handoff: $($copied -join ', ') -> $hostReports"

if ($Remove) {
    Write-Host "Removing container '$Name'"
    docker rm $Name | Out-Null
}

Write-Host "Stop complete. Start again with scripts/Start-Autonomad.ps1"
exit 0
