# Autonomad — scripts/Check-LegacyApp.ps1
#
# Structural health check for a legacy HRIS solution checkout. Self-contained,
# PowerShell 7 compatible, requires NO external modules.
#
# Usage:
#   pwsh -File scripts/Check-LegacyApp.ps1 [-SolutionRoot <dir>]
#
# Checks (each reported as PASS / WARN / FAIL):
#   1. HRSystem.sln exists at the solution root.
#   2. src/ and tests/ directories exist.
#   3. The solution file references at least one .csproj under src/.
#   4. The tests/ directory contains at least one test project (.csproj).
#
# WARNs (non-fatal, informational):
#   - solution references projects outside src/ (e.g. under tests/ or elsewhere)
#   - a test project does not reference a common test SDK
#     (Microsoft.NET.Test.Sdk / xunit / NUnit / MSTest)
#
# Exit codes: 0 = no FAIL, 1 = at least one FAIL.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SolutionRoot = './'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- resolve + normalize the solution root ---
$Root = (Resolve-Path -LiteralPath $SolutionRoot -ErrorAction SilentlyContinue)
if (-not $Root) {
    Write-Host "ERROR: solution root not found: $SolutionRoot" -ForegroundColor Red
    exit 1
}
$Root = $Root.Path.TrimEnd('\', '/')

$rows = @()   # each: @{ Check; Result; Detail }
$fails = 0

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Detail = ''
    )
    $script:rows += [pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail }
    if ($Result -eq 'FAIL') { $script:fails++ }
}

# --- check 1: HRSystem.sln exists at the root ---
$slnPath = Join-Path $Root 'HRSystem.sln'
if (Test-Path -LiteralPath $slnPath -PathType Leaf) {
    Add-Result -Check 'HRSystem.sln present' -Result 'PASS' -Detail $slnPath
} else {
    Add-Result -Check 'HRSystem.sln present' -Result 'FAIL' -Detail 'HRSystem.sln not found at solution root'
}

# --- check 2: src/ and tests/ directories exist ---
$srcDir = Join-Path $Root 'src'
$testsDir = Join-Path $Root 'tests'
$srcOk = Test-Path -LiteralPath $srcDir -PathType Container
$testsOk = Test-Path -LiteralPath $testsDir -PathType Container

if ($srcOk) {
    Add-Result -Check 'src/ exists' -Result 'PASS'
} else {
    Add-Result -Check 'src/ exists' -Result 'FAIL' -Detail 'src/ directory not found'
}
if ($testsOk) {
    Add-Result -Check 'tests/ exists' -Result 'PASS'
} else {
    Add-Result -Check 'tests/ exists' -Result 'FAIL' -Detail 'tests/ directory not found'
}

# --- parse .csproj references from the solution file ---
$slnProjects = @()
if (Test-Path -LiteralPath $slnPath -PathType Leaf) {
    $slnText = Get-Content -LiteralPath $slnPath -Raw
    $matches = [regex]::Matches($slnText, '([A-Za-z]:[\\/]|[\\/])?[^"(),]*\.csproj', 'IgnoreCase')
    $slnProjects = @($matches | ForEach-Object { $_.Value.Trim() } | Sort-Object -Unique)
}

$srcProjects = @()
if ($srcOk) {
    $srcProjects = @(Get-ChildItem -LiteralPath $srcDir -Recurse -Filter '*.csproj' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}

$testsProjects = @()
if ($testsOk) {
    $testsProjects = @(Get-ChildItem -LiteralPath $testsDir -Recurse -Filter '*.csproj' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
}

# --- check 3: solution references at least one .csproj under src/ ---
$srcRefs = @($slnProjects | Where-Object {
    $normalized = $_.Replace('\', '/')
    $normalized -match '(?i)^(\./)?src/'
})
if ($srcRefs.Count -gt 0) {
    Add-Result -Check 'solution references src/ project' -Result 'PASS' -Detail "$($srcRefs.Count) project(s) under src/"
} elseif ($slnProjects.Count -eq 0 -and (Test-Path -LiteralPath $slnPath -PathType Leaf)) {
    Add-Result -Check 'solution references src/ project' -Result 'FAIL' -Detail 'solution file references no .csproj projects'
} else {
    Add-Result -Check 'solution references src/ project' -Result 'FAIL' -Detail 'solution references no .csproj under src/'
}

# --- check 4: tests/ contains at least one test project ---
if ($testsProjects.Count -gt 0) {
    Add-Result -Check 'tests/ has test project' -Result 'PASS' -Detail "$($testsProjects.Count) .csproj under tests/"
} else {
    Add-Result -Check 'tests/ has test project' -Result 'FAIL' -Detail 'tests/ contains no .csproj test project'
}

# --- WARNs (non-fatal) ---
# WARN: solution references projects outside src/ and tests/ (informational —
# test projects under tests/ are expected and do not warn).
$outsideRefs = @($slnProjects | Where-Object {
    $normalized = $_.Replace('\', '/')
    $normalized -notmatch '(?i)^(\./)?(src|tests)/'
})
if ($outsideRefs.Count -gt 0) {
    Add-Result -Check 'projects outside src/ and tests/' -Result 'WARN' -Detail "$($outsideRefs.Count) reference(s) elsewhere in the solution"
}

# WARN: test projects missing a common test SDK reference.
if ($testsProjects.Count -gt 0) {
    foreach ($proj in $testsProjects) {
        $projText = Get-Content -LiteralPath $proj -Raw -ErrorAction SilentlyContinue
        if ($projText -and $projText -notmatch 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest|MSTest\.TestFramework') {
            Add-Result -Check 'test project SDK reference' -Result 'WARN' -Detail "$(Split-Path -Leaf $proj) has no common test SDK reference"
        }
    }
}

# --- compact summary table ---
Write-Host ''
Write-Host "Legacy HRIS structural health check — $(Split-Path -Leaf $Root)" -ForegroundColor Cyan
Write-Host ('-' * 78)
foreach ($row in $rows) {
    $color = switch ($row.Result) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    $detail = if ($row.Detail) { "  ($($row.Detail))" } else { '' }
    Write-Host ("{0,-36} {1,-6} {2}" -f $row.Check, $row.Result, $detail) -ForegroundColor $color
}
Write-Host ('-' * 78)
$passCount = @($rows | Where-Object { $_.Result -eq 'PASS' }).Count
$warnCount = @($rows | Where-Object { $_.Result -eq 'WARN' }).Count
Write-Host ("Summary: {0} PASS / {1} WARN / {2} FAIL" -f $passCount, $warnCount, $fails)

if ($fails -gt 0) {
    Write-Host "Check-LegacyApp: FAILED ($fails issue(s) found)" -ForegroundColor Red
    exit 1
}
Write-Host 'Check-LegacyApp: OK — all checks passed.' -ForegroundColor Green
exit 0
