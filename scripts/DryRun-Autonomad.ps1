# Autonomad v1 — scripts/DryRun-Autonomad.ps1
#
# Dry-run E2E (T9). Exercises the full claim -> develop -> close-out -> harvest
# path WITHOUT docker, without real GitHub, and without an LLM:
#
#   - a throwaway local git repo acts as the "remote" (bare repo + workspace clone)
#   - scripts/mock-gh.ps1 fakes the gh CLI (state + events JSON)
#   - scripts/mock-dev-agent.ps1 fakes the dev agent (pipeline-state + result)
#   - src/tick.ps1 runs the real loop in --once mode with AUTONOMAD_SANDBOX_MODE=mock
#
# Scenarios (AUTONOMAD_DRYRUN_SCENARIO):
#   success   — green dev -> PR created, pending-review, report, learning.db, runs.log
#   halt      — low confidence -> needs-human, comment, NO PR
#   fail      — 2 failed attempts -> needs-human hard stop, NO PR
#   missing   — dev agent writes nothing -> fails closed -> needs-human
#
# Asserts the autonomy boundary: no merge events, no `approved` label applied by
# the bot in ANY scenario.
#
# Usage:  pwsh -File scripts/DryRun-Autonomad.ps1 [-Scenario success|halt|fail|missing|all]

[CmdletBinding()]
param(
    [ValidateSet('success', 'halt', 'fail', 'missing', 'all')]
    [string]$Scenario = 'all'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ScriptsDir = $PSScriptRoot
$SrcDir = Join-Path $RepoRoot 'src'

$TempBase = Join-Path ([System.IO.Path]::GetTempPath()) "autonomad-dryrun-$([guid]::NewGuid().ToString('N'))"

function New-ScenarioDir([string]$Name) {
    $dir = Join-Path $TempBase $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-BareRepo([string]$Dir) {
    # Throwaway remote (bare) + a workspace clone that tick will use.
    $bare = Join-Path $Dir 'remote.git'
    $ws = Join-Path $Dir 'workspace'
    git init --bare $bare | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init --bare failed' }
    # Seed main with a file, push to the bare remote.
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    Push-Location $ws
    try {
        git init | Out-Null
        git remote add origin $bare
        Set-Content -LiteralPath 'README.md' -Value '# Throwaway repo for Autonomad dry-run'
        git add README.md
        git -c user.name='seed' -c user.email='seed@example.com' commit -m 'seed main' | Out-Null
        git branch -M main
        git push -u origin main | Out-Null
        git checkout -b main 2>$null | Out-Null
    } finally { Pop-Location }
    return @{ Bare = $bare; Workspace = $ws }
}

function New-MockState([string]$Dir, [int]$IssueNumber = 1, [string]$Title = 'Dry-run issue') {
    $state = @{
        labels = @{}
        issues = @{
            "$IssueNumber" = @{
                number = $IssueNumber
                title = $Title
                body = "Synthetic issue for Autonomad dry-run.`n`nTest body with multiple lines."
                url = "https://github.com/throwaway/autonomad/issues/$IssueNumber"
                state = 'OPEN'
                labels = @('autonomous')
                assignees = @()
            }
        }
        next_pr = 1
    }
    $stateFile = Join-Path $Dir 'mock-state.json'
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8
    return $stateFile
}

function New-RepoConfig([string]$Dir) {
    $cfg = @"
repo = throwaway/autonomad
harness = opencode
model = mock-model
base_branch = main
test_command = echo test-ok
build_command = echo build-ok
poll_interval = 1
idle_timeout = 30
ttl = 3600
max_retries = 2
bot_login = autonomad-bot
branch_prefix = autonomad
brain_paths = graphify-out,context,references,decisions,.github/skills,.github/agents
"@
    Set-Content -LiteralPath (Join-Path $Dir 'repo.config') -Value $cfg -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'pipeline-state.schema.json') -Destination (Join-Path $Dir 'pipeline-state.schema.json')
}

function Set-ScenarioEnv([string]$ScenarioDir, [string]$StateFile, [string]$Outcome) {
    [System.Environment]::SetEnvironmentVariable('GH_BIN', (Join-Path $ScriptsDir 'mock-gh.ps1'))
    [System.Environment]::SetEnvironmentVariable('MOCK_GH_STATE', $StateFile)
    [System.Environment]::SetEnvironmentVariable('AUTONOMAD_SANDBOX_MODE', 'mock')
    [System.Environment]::SetEnvironmentVariable('AUTONOMAD_MOCK_OUTCOME', $Outcome)
    [System.Environment]::SetEnvironmentVariable('AUTONOMAD_MOCK_SCRIPT', (Join-Path $ScriptsDir 'mock-dev-agent.ps1'))
    [System.Environment]::SetEnvironmentVariable('GH_TOKEN', '')   # no real auth
    [System.Environment]::SetEnvironmentVariable('AIOS_BRAIN_PATH', '')
    # Force a real SQLite backend (m10) so the learning.db assert below is
    # deterministic instead of falling back to JSONL when sqlite3/python are
    # missing. Prefer sqlite3 CLI (matches the production image); fall back to
    # python (built-in sqlite3 module). Neither present -> fail loudly.
    $backend = $null
    if (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        $backend = 'sqlite3cli'
    } else {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            $probe = & $py.Source -c "import sqlite3; print(sqlite3.sqlite_version)" 2>$null
            if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -match '^\d+\.\d+') { $backend = 'python' }
        }
    }
    if (-not $backend) {
        throw 'Dry-run requires sqlite3 CLI or python (with sqlite3) so the learning.db assert stays on real SQLite (m10).'
    }
    [System.Environment]::SetEnvironmentVariable('AUTONOMAD_LEARN_BACKEND', $backend)
}

function Invoke-TickOnce([string]$ConfigDir, [string]$DataDir) {
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $SrcDir 'tick.ps1') `
        -ConfigPath (Join-Path $ConfigDir 'repo.config') `
        -DataDir $DataDir `
        -MaxTicks 5 `
        -Once 2>&1
    $code = $LASTEXITCODE
    return @{ Code = $code; Output = ($out -join "`n") }
}

function Get-Events([string]$Dir) {
    $f = Join-Path $Dir 'events.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @(Get-Content -LiteralPath $f | Where-Object { $_ -notmatch '^\s*$' } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-IssueState([string]$StateFile) {
    return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    Write-Host "  PASS: $Message"
}

function Test-Scenario([string]$ScenarioName, [string]$Outcome, [string[]]$SetupMode = @()) {
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "SCENARIO: $ScenarioName (mock outcome=$Outcome)"
    Write-Host "======================================================"
    $dir = New-ScenarioDir $ScenarioName
    New-RepoConfig $dir
    $git = New-BareRepo $dir
    $stateFile = New-MockState $dir
    # tick expects the workspace at <DataDir>/workspaces/issue-1 — pre-seed the clone
    $dataDir = Join-Path $dir 'data'
    $wsTarget = Join-Path $dataDir 'workspaces' 'issue-1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $wsTarget) -Force | Out-Null
    Copy-Item -Recurse -LiteralPath $git.Workspace -Destination $wsTarget
    # point origin at the local bare remote
    Push-Location $wsTarget
    try {
        git remote set-url origin $git.Bare
        git checkout main 2>$null | Out-Null
    } finally { Pop-Location }

    Set-ScenarioEnv $dir $stateFile $Outcome

    $r1 = Invoke-TickOnce $dir $dataDir
    Write-Host "--- tick run output (first) ---"
    Write-Host $r1.Output

    $events = Get-Events $dir
    $issue = Get-IssueState $stateFile
    $iss1 = $issue.issues.'1'

    if ($ScenarioName -eq 'fail') {
        # Second run must RESUME (attempt 1 persisted) then hard-stop at 2.
        $r2 = Invoke-TickOnce $dir $dataDir
        Write-Host "--- tick run output (second) ---"
        Write-Host $r2.Output
        $events = Get-Events $dir
        $issue = Get-IssueState $stateFile
        $iss1 = $issue.issues.'1'
    }

    # --- autonomy boundary (universal) ---
    $mergeEvents = @($events | Where-Object { $_.type -eq 'merge' })
    Assert ($mergeEvents.Count -eq 0) "no merge events in ANY scenario"
    Assert ($iss1.labels -notcontains 'approved') "bot never applies 'approved' label"

    switch ($ScenarioName) {
        'success' {
            $prs = @($events | Where-Object { $_.type -eq 'pr_create' })
            Assert ($prs.Count -eq 1) "exactly one PR created (got $($prs.Count))"
            Assert ($prs[0].body -match 'Fixes #1') "PR body contains 'Fixes #1'"
            Assert ($prs[0].head -eq 'autonomad/issue-1') "PR head branch is autonomad/issue-1"
            Assert ($iss1.labels -contains 'pending-review') "issue labeled pending-review"
            Assert ($iss1.labels -notcontains 'autonomous') "issue removed from autonomous"
            Assert (Test-Path -LiteralPath (Join-Path $dataDir 'reports' 'issue-1.html')) "report issue-1.html generated"
            Assert (Test-Path -LiteralPath (Join-Path $dataDir 'reports' 'runs.log')) "runs.log appended"
            Assert (Test-Path -LiteralPath (Join-Path $dataDir 'learning.db')) "learning.db created (SQLite)"
            $logLine = Get-Content -LiteralPath (Join-Path $dataDir 'reports' 'runs.log') -Raw
            Assert ($logLine -match 'issue-1') "runs.log mentions issue-1"
            # branch pushed to the throwaway remote
            $branches = git --git-dir="$($git.Bare)" for-each-ref --format='%(refname)' 2>&1
            Assert (($branches -join "`n") -match 'autonomad/issue-1') "branch autonomad/issue-1 pushed to remote"
        }
        'halt' {
            $prs = @($events | Where-Object { $_.type -eq 'pr_create' })
            Assert ($prs.Count -eq 0) "NO PR created on halt"
            Assert ($iss1.labels -contains 'needs-human') "issue labeled needs-human"
            Assert ($iss1.labels -notcontains 'pending-review') "not labeled pending-review"
            $comments = @($events | Where-Object { $_.type -eq 'issue_comment' })
            Assert ($comments.Count -ge 1) "halt comment left on issue"
            Assert (($comments[0].body -join '') -match 'needs a human') "comment explains needs-human reason"
        }
        'fail' {
            $prs = @($events | Where-Object { $_.type -eq 'pr_create' })
            Assert ($prs.Count -eq 0) "NO PR created after 2 failed attempts"
            Assert ($iss1.labels -contains 'needs-human') "hard stop labeled needs-human"
            $comments = @($events | Where-Object { $_.type -eq 'issue_comment' })
            Assert (($comments | Measure-Object).Count -ge 1) "halt comment left after hard stop"
        }
        'missing' {
            $prs = @($events | Where-Object { $_.type -eq 'pr_create' })
            Assert ($prs.Count -eq 0) "NO PR created when state missing (fails closed)"
            Assert ($iss1.labels -contains 'needs-human') "fails-closed labeled needs-human"
            $comments = @($events | Where-Object { $_.type -eq 'issue_comment' })
            Assert (($comments | Measure-Object).Count -ge 1) "fails-closed comment left"
        }
    }
    Write-Host "SCENARIO $ScenarioName PASSED"
}

# --- run ---
try {
    if ($Scenario -eq 'all' -or $Scenario -eq 'success') { Test-Scenario 'success' 'success' }
    if ($Scenario -eq 'all' -or $Scenario -eq 'halt') { Test-Scenario 'halt' 'halt-conf' }
    if ($Scenario -eq 'all' -or $Scenario -eq 'fail') { Test-Scenario 'fail' 'fail' }
    if ($Scenario -eq 'all' -or $Scenario -eq 'missing') { Test-Scenario 'missing' 'missing' }
    Write-Host ""
    Write-Host "DRY-RUN E2E: ALL SCENARIOS PASSED"
    Write-Host "Temp workspace kept at: $TempBase (delete manually after inspection)"
    exit 0
} catch {
    Write-Host ""
    Write-Host "DRY-RUN E2E FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Temp workspace: $TempBase"
    exit 1
}
