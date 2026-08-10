# Autonomad v1 — scripts/Validate-Autonomad.ps1
#
# Build-time validation for the Autonomad repo itself (its own target). Runs
# green BEFORE any gate advances: verifies that repo.config parses + validates,
# pipeline-state.schema.json is valid JSON, and every *.ps1 parses without
# syntax errors. Exits 0 when all checks pass, 1 otherwise.
#
# Usage:
#   pwsh -NoProfile -File scripts/Validate-Autonomad.ps1 [-RepoRoot <dir>]

[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fail = $false
function Assert-Pass([string]$Name, [scriptblock]$Body) {
    try {
        & $Body | Out-Null
        Write-Host "  PASS: $Name"
    } catch {
        Write-Host "  FAIL: $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:fail = $true
    }
}

Write-Host "Validating Autonomad scaffold at $RepoRoot"

# 1. repo.config parses + validates (all declared fields).
Assert-Pass 'repo.config parses + validates' {
    . (Join-Path $RepoRoot 'src\Config.ps1')
    $cfg = Read-RepoConfig -ConfigPath (Join-Path $RepoRoot 'repo.config')
    foreach ($req in @('repo', 'harness', 'test_command', 'build_command')) {
        if ([string]::IsNullOrWhiteSpace($cfg[$req])) { throw "missing config key $req" }
    }
}

# 2. pipeline-state.schema.json is valid JSON.
Assert-Pass 'pipeline-state.schema.json is valid JSON' {
    Get-Content -LiteralPath (Join-Path $RepoRoot 'pipeline-state.schema.json') -Raw | ConvertFrom-Json | Out-Null
}

# 3. All PowerShell scripts parse without syntax errors.
Assert-Pass 'PowerShell scripts parse cleanly' {
    $parser = [System.Management.Automation.Language.Parser]
    $errors = @()
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter *.ps1 | ForEach-Object {
        $tokens = $null
        $parseErrors = $null
        [void]$parser::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
        $errors += @($parseErrors)
    }
    if ($errors.Count -gt 0) {
        throw (($errors | Select-Object -First 5 | ForEach-Object { $_.Message }) -join '; ')
    }
}

# 4. Env contract: .env.example declares the required runtime vars.
Assert-Pass '.env.example declares GH_TOKEN + AIOS_BRAIN_PATH' {
    $envEx = Get-Content -LiteralPath (Join-Path $RepoRoot '.env.example') -Raw
    foreach ($v in @('GH_TOKEN', 'AIOS_BRAIN_PATH', 'OPENCODE_MODEL')) {
        if ($envEx -notmatch "(?m)^$v=") { throw ".env.example missing $v" }
    }
}

if ($script:fail) {
    Write-Host "VALIDATION FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "VALIDATION OK"
exit 0
