# Autonomad v1 — scripts/Status-Autonomad.ps1
#
# Health snapshot (T9/Q17): docker ps + heartbeat (last_tick.ts) + run log tail.

[CmdletBinding()]
param(
    [string]$Name = 'autonomad',
    [int]$Tail = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "=== docker ps (filter name=$Name) ==="
$ps = docker ps --filter "name=^/$Name$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1
$ps

$running = docker ps --filter "name=^/$Name$" --format '{{.Names}}' 2>&1
if ("$running".Trim() -ne $Name) {
    Write-Host "`nContainer '$Name' is NOT running."
    exit 1
}

Write-Host "`n=== Heartbeat (last_tick.ts) ==="
$hb = docker exec $Name cat /data/last_tick.ts 2>$null
if ("$hb".Trim()) {
    Write-Host "last tick: $hb"
    try {
        $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse("$hb")).TotalSeconds
        Write-Host "age: $([math]::Round($age))s ago"
    } catch { }
} else {
    Write-Host "no heartbeat yet"
}

Write-Host "`n=== Run log tail ($Tail lines) ==="
$log = docker exec $Name sh -c "tail -n $Tail /data/reports/runs.log /data/logs/tick.log 2>/dev/null || true" 2>$null
if ("$log".Trim()) { Write-Host $log } else { Write-Host "no logs yet" }

Write-Host "`n=== Container data volume ==="
docker exec $Name sh -c "ls -la /data 2>/dev/null; echo '---'; ls /data/reports 2>/dev/null | tail -5" 2>$null

exit 0
