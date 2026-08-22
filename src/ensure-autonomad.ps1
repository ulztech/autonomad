# ensure-autonomad.ps1 — supervisor liveness check (issue #25)
#
# Starts the always-on supervisor if it is not running. The supervisor is a
# single hidden pwsh process with no self-restart, so after a crash, reboot or
# manual kill nothing revives it — this script is the recovery entry point.
#
# Usage:
#   pwsh -NoProfile -File src/ensure-autonomad.ps1 [-DataDir C:\GitRepos\autonomad-data] [-RepoRoot C:\GitRepos\autonomad] [-Quiet]
#
# Exit codes:
#   0  supervisor already running (or just started and verified)
#   1  supervisor started by this script
#   2  supervisor missing AND could not be started
#   3  invalid arguments / unusable paths

[CmdletBinding()]
param(
    [string]$DataDir = '',
    [string]$RepoRoot = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $DataDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $DataDir = if ($envData) { $envData } else { $RepoRoot }
}

function Write-Note {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

# ---- validate paths ----
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'src\supervisor.ps1'))) {
    Write-Note "ensure-autonomad: supervisor.ps1 not found under RepoRoot '$RepoRoot'"
    exit 3
}
if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

$StateFile = Join-Path $DataDir 'supervisor-state.json'
$LogsDir = Join-Path $DataDir 'logs'
if (-not (Test-Path -LiteralPath $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }

function Test-SupervisorAlive {
    param([string]$StateFilePath)
    if (-not (Test-Path -LiteralPath $StateFilePath)) { return $false }
    try {
        $state = Get-Content -LiteralPath $StateFilePath -Raw | ConvertFrom-Json
    } catch {
        # Unreadable state = not trustworthy; treat as down.
        Write-Note "ensure-autonomad: supervisor-state.json unreadable ($($_.Exception.Message)) — assuming down"
        return $false
    }
    $pidVal = $null
    try { $pidVal = [int]$state.pid } catch { }
    if ($pidVal -le 0) { return $false }
    try {
        $p = Get-Process -Id $pidVal -ErrorAction Stop
        return ($null -ne $p)
    } catch {
        return $false
    }
}

if (Test-SupervisorAlive -StateFilePath $StateFile) {
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Write-Note "ensure-autonomad: supervisor already running (pid $($state.pid), repo $($state.repo))"
    exit 0
}

# ---- start the supervisor hidden ----
$supervisor = Join-Path $RepoRoot 'src\supervisor.ps1'
try {
    $p = Start-Process pwsh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-File', $supervisor,
        '-DataDir', $DataDir,
        '-RepoRoot', $RepoRoot
    )
} catch {
    Write-Note "ensure-autonomad: FAILED to start supervisor: $($_.Exception.Message)"
    exit 2
}

# ---- verify: heartbeat within ~15s ----
$deadline = (Get-Date).AddSeconds(15)
$ok = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-SupervisorAlive -StateFilePath $StateFile) {
        $ok = $true
        break
    }
}
if ($ok) {
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Write-Note "ensure-autonomad: supervisor started (pid $($state.pid), repo $($state.repo))"
    exit 1
} else {
    Write-Note "ensure-autonomad: supervisor process launched (pid $($p.Id)) but no heartbeat within 15s — check $LogsDir\supervisor.log"
    exit 1
}
