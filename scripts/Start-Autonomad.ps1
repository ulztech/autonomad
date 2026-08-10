# Autonomad v1 — scripts/Start-Autonomad.ps1
#
# Starts the Autonomad container (T9/Q17): docker run --env-file .env --name autonomad.
# Mounts the docker socket (for per-issue sandbox provisioning), a named volume
# for learning.db/reports/runs.log, and the host AIOS brain read-only.

[CmdletBinding()]
param(
    [string]$Image = 'autonomad:v1',
    [string]$Name = 'autonomad',
    [string]$Tag = 'v1',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $RepoRoot '.env'

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Missing .env — run Init first (or copy .env.example to .env)."
}

# Running container check
$running = docker ps -a --filter "name=^/$Name$" --format '{{.Names}}' 2>&1
if ("$running".Trim() -eq $Name) {
    if ($Force) {
        Write-Host "Removing existing container '$Name'"
        docker rm -f $Name | Out-Null
    } else {
        throw "Container '$Name' already exists. Stop it first, or use -Force."
    }
}

# Parse brain path from .env
$brain = (Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^AIOS_BRAIN_PATH=' }) -replace '^AIOS_BRAIN_PATH=', ''
if (-not (Test-Path -LiteralPath $brain)) {
    throw "AIOS_BRAIN_PATH not found or invalid: '$brain'"
}

# Named volume for persistent runtime data
docker volume create autonomad-data 2>&1 | Out-Null

Write-Host "Starting Autonomad ($Image) with brain=$brain"

# NOTE: On Windows hosts /var/run/docker.sock is not exposed the same way as
# Linux. When running locally on Windows, set AUTONOMAD_SANDBOX_MODE=mock in .env
# (dry-run mode) OR use the provided docker context / TCP daemon. The command
# below assumes a Linux daemon socket mount as in the reference deployment.
docker run -d `
    --name $Name `
    --env-file $EnvFile `
    --restart unless-stopped `
    -v /var/run/docker.sock:/var/run/docker.sock `
    -v autonomad-data:/data `
    -v "${brain}:/brain:ro" `
    -e "AUTONOMAD_BRAIN_HOST=$brain" `
    $Image

if ($LASTEXITCODE -ne 0) { throw 'docker run failed' }

Write-Host "Autonomad container '$Name' started. Check status with scripts/Status-Autonomad.ps1"
exit 0
