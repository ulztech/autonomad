# Autonomad v1 — scripts/Init-Autonomad.ps1
#
# One-time / idempotent setup (T9/Q17): environment verify, gh auth check,
# idempotent label creation, image build, scaffold dirs.
#
# Usage:  pwsh -File scripts/Init-Autonomad.ps1 [-SkipImageBuild]

[CmdletBinding()]
param([switch]$SkipImageBuild)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Step($Name, [scriptblock]$Body) {
    Write-Host ""
    Write-Host "==> $Name"
    & $Body
}

# --- verify pwsh version ---
Step 'PowerShell version' {
    if ($PSVersionTable.PSVersion -lt [version]'7.0') {
        throw "Autonomad requires PowerShell 7+. Found $($PSVersionTable.PSVersion)"
    }
    Write-Host "pwsh $($PSVersionTable.PSVersion) OK"
}

# --- verify docker ---
Step 'Docker' {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'docker CLI not found. Install Docker Desktop and try again.'
    }
    $v = docker --version 2>&1
    Write-Host "$v"
}

# --- verify gh + auth ---
Step 'GitHub CLI auth' {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh CLI not found. Install GitHub CLI and run gh auth login.'
    }
    gh auth status
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated. Run gh auth login first.' }
    Write-Host "gh $((gh --version | Select-Object -First 1)) OK"
}

# --- verify .env ---
Step 'Environment (.env)' {
    $envFile = Join-Path $RepoRoot '.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        throw "Missing .env. Copy .env.example to .env and fill in GH_TOKEN + AIOS_BRAIN_PATH."
    }
    $envVars = @{}
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { $envVars[$Matches[1]] = $true }
    }
    foreach ($req in @('GH_TOKEN', 'AIOS_BRAIN_PATH')) {
        if (-not $envVars.ContainsKey($req)) {
            throw ".env is missing required variable: $req"
        }
    }
    $brain = (Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^AIOS_BRAIN_PATH=' }) -replace '^AIOS_BRAIN_PATH=', ''
    if (-not (Test-Path -LiteralPath $brain)) {
        throw "AIOS_BRAIN_PATH points to a missing directory: $brain"
    }
    Write-Host ".env OK (brain=$brain)"
}

# --- validate repo.config + brain subdirs (corrected paths) ---
Step 'repo.config + brain layout' {
    . (Join-Path $RepoRoot 'src\Config.ps1')
    $cfg = Read-RepoConfig -ConfigPath (Join-Path $RepoRoot 'repo.config')
    Write-Host "repo=$($cfg['repo']) harness=$($cfg['harness']) model=$($cfg['model'])"
    $envBrain = (Get-Content -LiteralPath (Join-Path $RepoRoot '.env') | Where-Object { $_ -match '^AIOS_BRAIN_PATH=' }) -replace '^AIOS_BRAIN_PATH=', ''
    $resolved = Resolve-BrainPaths -BrainRoot $envBrain
    Write-Host "Brain mounts resolved: $($resolved.Count)/$((ConvertFrom-BrainPaths $cfg['brain_paths']).Count) available"
    foreach ($name in $resolved.Keys) {
        Write-Host "  $name -> $($resolved[$name])"
    }
    if ($resolved.Count -eq 0) {
        Write-Host 'WARNING: no brain directories resolved. Sandbox will run without the AIOS brain.' -ForegroundColor Yellow
    }
}

# --- validate pipeline-state.schema.json ---
Step 'pipeline-state.schema.json' {
    $schemaPath = Join-Path $RepoRoot 'pipeline-state.schema.json'
    Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json | Out-Null
    Write-Host "schema valid JSON"
}

# --- idempotent label creation (dry run against gh) ---
Step 'Labels (idempotent)' {
    . (Join-Path $RepoRoot 'src\Config.ps1')
    $cfg = Read-RepoConfig -ConfigPath (Join-Path $RepoRoot 'repo.config')
    $labels = @{
        'autonomous'     = '0E8A16'
        'in-progress'    = 'FB9C00'
        'pending-review' = '1D76DB'
        'reviewing'      = 'B60205'
        'approved'       = '5319E7'
        'needs-human'    = 'D93F0B'
    }
    foreach ($name in $labels.Keys) {
        $out = & gh label create $name --repo $cfg['repo'] --color $labels[$name] --description "Autonomad label: $name" 2>&1
        if ($LASTEXITCODE -eq 0 -or "$out" -match 'already exists') {
            Write-Host "  label '$name' OK"
        } else {
            throw "Failed to ensure label '$name': $out"
        }
    }
}

# --- scaffold dirs ---
Step 'Scaffold dirs' {
    foreach ($d in @('reports', 'workspaces', 'logs', 'adapters', 'marketplace', 'src', 'scripts')) {
        $p = Join-Path $RepoRoot $d
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    Write-Host 'directories OK'
}

# --- build image ---
if (-not $SkipImageBuild) {
    Step 'Docker image build' {
        docker build -t autonomad:v1 "$RepoRoot"
        if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }
        Write-Host 'image autonomad:v1 built'
    }
} else {
    Write-Host ''
    Write-Host '==> Docker image build (skipped by -SkipImageBuild)'
}

Write-Host ''
Write-Host 'Init complete. Next: copy .env, run scripts/Start-Autonomad.ps1'
exit 0
