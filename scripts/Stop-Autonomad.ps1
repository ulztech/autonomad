# Autonomad v1 — scripts/Stop-Autonomad.ps1
#
# Graceful stop + state handoff (T9/Q17). Stops the container, then copies the
# /data volume out to the host (data-handoff/) via `docker cp`, which works on
# STOPPED containers — unlike `docker exec`. The full /data tree is preserved so
# learning.db, reports/, logs/, workspaces/ and last_tick.ts survive a restart.

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

# State handoff: copy the container's /data volume out to the host. `docker cp`
# works on STOPPED containers (unlike `docker exec`, which fails once the
# container is not running). The full /data tree is copied so learning.db,
# reports/, logs/, workspaces/ and last_tick.ts all survive a stop/start cycle.
$handoffDir = Join-Path $RepoRoot 'data-handoff'
if (-not (Test-Path -LiteralPath $handoffDir)) { New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null }

Write-Host "Copying /data from stopped container '$Name' -> $handoffDir"
docker cp "${Name}:/data/." $handoffDir
if ($LASTEXITCODE -ne 0) { throw "docker cp state handoff failed for container $Name" }

$copied = @(Get-ChildItem -LiteralPath $handoffDir -Recurse -File | ForEach-Object { $_.FullName.Substring($handoffDir.Length).TrimStart('\', '/') } | Sort-Object)
if ($copied.Count -eq 0) {
    Write-Host "WARNING: state handoff copied no files (was /data empty?)" -ForegroundColor Yellow
} else {
    Write-Host "State handoff complete — $($copied.Count) file(s) copied:"
    foreach ($rel in $copied) { Write-Host "  $rel" }
}
Write-Host "Resume later by restarting with scripts/Start-Autonomad.ps1 (state lives in $handoffDir)"

if ($Remove) {
    Write-Host "Removing container '$Name'"
    docker rm $Name | Out-Null
}

Write-Host "Stop complete. Start again with scripts/Start-Autonomad.ps1"
exit 0
