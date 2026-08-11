# Pester tests for the dependency/parent extraction regexes (Fix 2).
# Loads the two pure functions from src/tick.ps1 via AST so the main loop's side
# effects never run, then exercises the real implementation.
# NOTE: written for Pester 3.4 (old-style BeforeEach/It; no BeforeAll).

$script:Src = Join-Path $PSScriptRoot '..\src\tick.ps1'
$script:TickAst = $null
$tokens = $null; $errors = $null
$script:TickAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:Src, [ref]$tokens, [ref]$errors)
if ($errors) { throw "Parse of tick.ps1 failed: $($errors | Out-String)" }

function Get-TickFunction {
    param([string]$Name)
    $fn = $script:TickAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $fn) { throw "Function $Name not found in tick.ps1" }
    return $fn.Extent.Text
}

Describe 'Get-DependencyRefs' {
    BeforeEach {
        Invoke-Expression (Get-TickFunction -Name 'Get-DependencyRefs')
    }

    It 'extracts inline "Blocked by #N"' {
        $deps = Get-DependencyRefs -Body 'Blocked by #42'
        $deps | Should Be @(42)
    }

    It 'extracts inline "Depends on #N"' {
        $deps = Get-DependencyRefs -Body 'Depends on #7'
        $deps | Should Be @(7)
    }

    It 'extracts a bullet under "## Blocked by"' {
        $deps = Get-DependencyRefs -Body "## Blocked by`n`n- #316 — Flexi balance tables migration + schema mirrors"
        $deps | Should Be @(316)
    }

    It 'extracts multiple bullets under "## Blocked by"' {
        $deps = Get-DependencyRefs -Body "## Blocked by`n- #5 — first`n- #6 — second"
        $deps | Should Be @(5, 6)
    }

    It 'dedupes repeated references' {
        $deps = Get-DependencyRefs -Body "Blocked by #9`n- #9 - dup"
        $deps | Should Be @(9)
    }

    It 'returns empty for a body with no dependency' {
        $deps = Get-DependencyRefs -Body 'No blockers here'
        @($deps).Count | Should Be 0
    }

    It 'returns empty for a null/empty body' {
        $deps = Get-DependencyRefs -Body ''
        @($deps).Count | Should Be 0
    }
}

Describe 'Get-ParentRef' {
    BeforeEach {
        Invoke-Expression (Get-TickFunction -Name 'Get-ParentRef')
    }

    It 'extracts inline "Parent: #N"' {
        Get-ParentRef -Body 'Parent: #313' | Should Be 313
    }

    It 'extracts a GitHub issue URL parent' {
        Get-ParentRef -Body "## Parent`n`nhttps://github.com/ulztech/HRSystem-Legacy/issues/313" | Should Be 313
    }

    It 'extracts a bullet-list URL parent' {
        Get-ParentRef -Body "## Parent`n`n- https://github.com/ulztech/HRSystem-Legacy/issues/313" | Should Be 313
    }

    It 'returns null when no parent is declared' {
        Get-ParentRef -Body 'Standalone ticket' | Should Be $null
    }
}
