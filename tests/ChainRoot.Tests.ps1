# Pester tests for chain-root resolution (Fix 6).
# A sequential chain (316 -> 317 -> 318) must resolve every child back to the
# chain ROOT (the ticket with no blockers) so all children reuse one branch + PR.
# NOTE: written for Pester 3.4 (old-style It/Should Be).

$script:Src = Join-Path $PSScriptRoot '..\src\tick.ps1'
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

# Load the real functions under test.
Invoke-Expression (Get-TickFunction -Name 'Get-DependencyRefs')
Invoke-Expression (Get-TickFunction -Name 'Resolve-ChainRootRef')

# Minimal Write-Log stub (the function references it in its catch path).
function global:Write-Log { param($Message, $Level) }

# Invoke-Gh stub backed by a script-scope body map. NOTE: param must NOT be named
# $Args — that collides with PowerShell's automatic $args variable inside Pester
# and never binds. $GhArgs is a safe name; positional splatting still binds.
$script:Bodies = @{}
function global:Invoke-Gh {
    param([string[]]$GhArgs)
    if ($GhArgs[0] -eq 'issue' -and $GhArgs[1] -eq 'view') {
        $num = $GhArgs[2]
        return (@{ number = [int]$num; body = $script:Bodies["$num"] } | ConvertTo-Json -Compress)
    }
    throw "unexpected gh call: $($GhArgs -join ' ')"
}

Describe 'Resolve-ChainRootRef' {
    It 'resolves a chain child back to the head' {
        $script:Bodies = @{
            '316' = 'no blockers'
            '317' = "## Blocked by`n- #316 — root"
        }
        $script:Config = @{ repo = 'test/repo' }
        $root = Resolve-ChainRootRef -Issue (@{ number = 317; body = $script:Bodies['317'] })
        $root | Should Be 316
    }

    It 'resolves a 3-deep chain to the ultimate head' {
        $script:Bodies = @{
            '316' = 'no blockers'
            '317' = "## Blocked by`n- #316"
            '318' = "## Blocked by`n- #317"
        }
        $script:Config = @{ repo = 'test/repo' }
        $root = Resolve-ChainRootRef -Issue (@{ number = 318; body = $script:Bodies['318'] })
        $root | Should Be 316
    }

    It 'returns own number for a ticket with no blockers' {
        $script:Bodies = @{ '316' = 'no blockers' }
        $script:Config = @{ repo = 'test/repo' }
        $root = Resolve-ChainRootRef -Issue (@{ number = 316; body = $script:Bodies['316'] })
        $root | Should Be 316
    }
}
