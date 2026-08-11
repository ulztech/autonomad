# Autonomad v1 — scripts/Validate-Autonomad.ps1
#
# Repo self-check (M1). This is the repo.config `build_command`:
#   pwsh -NoProfile -File scripts/Validate-Autonomad.ps1
#
# Checks (all must pass for exit 0):
#   1. repo.config parses + validates via src/Config.ps1 (Read-RepoConfig).
#   2. pipeline-state.schema.json is valid JSON.
#   3. Every src/*.ps1 and scripts/*.ps1 parses cleanly under the PowerShell
#      language parser (catches syntax errors before a container run hits them).
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$errors = @()

# --- 1. repo.config parses + validates ---
try {
    . (Join-Path $RepoRoot 'src' 'Config.ps1')
    $cfg = Read-RepoConfig -ConfigPath (Join-Path $RepoRoot 'repo.config')
    Write-Host "OK repo.config: repo=$($cfg['repo']) harness=$($cfg['harness']) model=$($cfg['model']) base_branch=$($cfg['base_branch'])"
} catch {
    $errors += "repo.config: $($_.Exception.Message)"
}

# --- 2. pipeline-state.schema.json is valid JSON ---
$schemaPath = Join-Path $RepoRoot 'pipeline-state.schema.json'
try {
    if (-not (Test-Path -LiteralPath $schemaPath)) { throw 'file not found' }
    Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json | Out-Null
    Write-Host "OK pipeline-state.schema.json: valid JSON"
} catch {
    $errors += "pipeline-state.schema.json: $($_.Exception.Message)"
}

# --- 3. pwsh-parses all src/*.ps1 and scripts/*.ps1 ---
$files = @()
foreach ($dir in @((Join-Path $RepoRoot 'src'), (Join-Path $RepoRoot 'scripts'))) {
    if (Test-Path -LiteralPath $dir) {
        $files += @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File)
    }
}
if ($files.Count -eq 0) {
    $errors += 'No PowerShell files found to parse under src/ or scripts/'
} else {
    $parseErrorCount = 0
    foreach ($file in $files) {
        $tokens = $null
        $parseErr = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErr) | Out-Null
        if ($parseErr -and $parseErr.Count -gt 0) {
            $parseErrorCount += $parseErr.Count
            foreach ($e in $parseErr) {
                $errors += "$($file.Name): $($e.Message) (line $($e.Extent.StartLineNumber))"
            }
        }
    }
    if ($parseErrorCount -eq 0) {
        Write-Host "OK pwsh parse: $($files.Count) file(s) under src/ + scripts/ parsed cleanly"
    }
}

# --- report ---
if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host "VALIDATE FAILED ($($errors.Count) error(s)):" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    Write-Host 'Validate-Autonomad: FAILED' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'VALIDATE OK — all checks passed.' -ForegroundColor Green
exit 0
