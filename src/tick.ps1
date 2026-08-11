# Autonomad v1 — src/tick.ps1
#
# Pure-shell tick loop (Q15). Orchestrates everything; the LLM only ever runs
# inside the per-issue dev sandbox + the harvest step.
#
# Flow per tick:
#   1. Poll  gh issue list --label autonomous --assignee=none --limit 1
#   2. Claim gh issue edit <N> --add-assignee <bot> --remove-label autonomous --add-label in-progress
#   3. Gate 0: branch + pipeline-state.json committed
#   4. Provision sandbox (brain read-only, marketplace, .env) + run adapter
#   5. Gate discipline: read state back, verify gates advanced (fails closed)
#   6. Close-out (green): push branch, PR "Fixes #N", pending-review, report, runs.log
#   7. Halt (confidence<90 / escalation / fatal flaw / N=max_retries): needs-human
#
# Usage:
#   pwsh -File src/tick.ps1 [-Once] [-ConfigPath x] [-DataDir y] [-GhBin z] [-MaxTicks n]
#
# Env overrides:
#   GH_BIN                gh executable (tests inject a mock)
#   AUTONOMAD_SANDBOX_MODE  docker | mock   (mock = dry-run E2E without docker)

[CmdletBinding()]
param(
    [switch]$Once,
    [string]$ConfigPath = '',
    [string]$DataDir = '',
    [string]$GhBin = '',
    [string]$EnvFile = '',
    [string]$BrainRoot = '',
    [int]$MaxTicks = 0          # 0 = unlimited (tests cap this)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- resolve repo root (dir containing repo.config) ---
$RepoRoot = if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'repo.config' }
if (-not $EnvFile) { $EnvFile = Join-Path $RepoRoot '.env' }
if (-not $DataDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $DataDir = if ($envData) { $envData } else { $RepoRoot }
}
$script:GhBin = if ($GhBin) { $GhBin } else {
    $envGh = [System.Environment]::GetEnvironmentVariable('GH_BIN')
    if ($envGh) { $envGh } else { 'gh' }
}

# --- load shared modules ---
. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Pipeline.ps1')
. (Join-Path $PSScriptRoot 'provision.ps1')

# --- load config + env ---
$Config = Read-RepoConfig -ConfigPath $ConfigPath
Import-EnvFile -EnvFilePath $EnvFile
$script:BrainRoot = if ($BrainRoot) { $BrainRoot } else {
    [System.Environment]::GetEnvironmentVariable('AIOS_BRAIN_PATH')
}
$script:SchemaPath = Get-PipelineSchemaPath -RepoRoot $RepoRoot
$script:DataDir = $DataDir
$script:WorkspacesDir = Join-Path $DataDir 'workspaces'
$script:ReportsDir = Join-Path $DataDir 'reports'
$script:LogsDir = Join-Path $DataDir 'logs'
$script:HeartbeatFile = Join-Path $DataDir 'last_tick.ts'
foreach ($d in @($DataDir, $script:WorkspacesDir, $script:ReportsDir, $script:LogsDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- logging helpers ---
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$ts] [$Level] $Message"
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value "[$ts] [$Level] $Message"
    }
}

<#
.SYNOPSIS
  Invoke the gh binary. Returns the raw stdout as a single string; throws with
  stderr on non-zero exit.
  NOTE (m5): stdout and stderr are captured to separate temp files instead of
  using `2>&1`. The merged stream turns stderr lines into ErrorRecords that
  corrupt multi-line JSON when piped to ConvertFrom-Json.
#>
function Invoke-Gh {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args
    )
    $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) "gh-out-$([guid]::NewGuid().ToString('N')).txt"
    $tmpErr = Join-Path ([System.IO.Path]::GetTempPath()) "gh-err-$([guid]::NewGuid().ToString('N')).txt"
    try {
        & $script:GhBin @Args 1> $tmpOut 2> $tmpErr
        $code = $LASTEXITCODE
        $output = if (Test-Path -LiteralPath $tmpOut) { Get-Content -LiteralPath $tmpOut -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $tmpErr) { Get-Content -LiteralPath $tmpErr -Raw } else { '' }
        if ($code -ne 0) {
            $detail = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } else { $output.Trim() }
            throw "gh $($Args -join ' ') failed (exit $code): $detail"
        }
        # Single string so `gh ... | ConvertFrom-Json` sees the whole document.
        return $output.TrimEnd("`r", "`n")
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Label helpers (idempotent)
# ============================================================
$script:Labels = @{
    'autonomous'     = 'Ready for the autonomous developer'
    'in-progress'    = 'Currently being developed by Autonomad'
    'pending-review' = 'PR opened; waiting for human review'
    'reviewing'      = 'Human reviewer is reviewing the PR'
    'approved'       = 'Human approved; ready to merge'
    'needs-human'    = 'Autonomad halted; requires human intervention'
}
$script:LabelColors = @{
    'autonomous'     = '0E8A16'
    'in-progress'    = 'FB9C00'
    'pending-review' = '1D76DB'
    'reviewing'      = 'B60205'
    'approved'       = '5319E7'
    'needs-human'    = 'D93F0B'
}

function Ensure-Labels {
    [CmdletBinding()]
    param()
    $repo = $Config['repo']
    foreach ($name in $script:Labels.Keys) {
        $out = & $script:GhBin label create $name --repo $repo --color $script:LabelColors[$name] --description $script:Labels[$name] 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            # idempotent: "already exists" is fine; anything else is fatal
            $msg = "$out"
            if ($msg -match 'already exists') {
                Write-Log "Label '$name' already exists (ok)" -Level 'DEBUG'
            } else {
                throw "Failed to ensure label '$name': $msg"
            }
        } else {
            Write-Log "Ensured label '$name'"
        }
    }
}

function Set-IssueLabel {
    param([int]$IssueNumber, [string[]]$Add, [string[]]$Remove)
    if ($Add.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Config['repo'], '--add-label', ($Add -join ',')) | Out-Null
    }
    if ($Remove.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Config['repo'], '--remove-label', ($Remove -join ',')) | Out-Null
    }
}

function Add-IssueComment {
    param([int]$IssueNumber, [string]$Body)
    $bodyFile = Join-Path $script:DataDir "comment-$IssueNumber.md"
    [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Gh @('issue', 'comment', "$IssueNumber", '--repo', $Config['repo'], '--body-file', $bodyFile) | Out-Null
    Remove-Item -LiteralPath $bodyFile -Force
}

# ============================================================
# Poll + claim
# ============================================================
function Get-CandidateIssue {
    [CmdletBinding()]
    param()
    $json = Invoke-Gh @('issue', 'list', '--label', 'autonomous', '--assignee', 'none',
        '--limit', '1', '--state', 'open', '--repo', $Config['repo'],
        '--json', 'number,title,url,body,labels,assignees')
    $items = $json | ConvertFrom-Json
    if (-not $items -or $items.Count -eq 0) { return $null }
    return $items[0]
}

function Test-IssueClaimedByBot {
    param([object]$Issue)
    foreach ($a in @($Issue.assignees)) {
        # Real gh returns assignee objects; the mock returns plain strings.
        $login = if ($a -is [string]) { $a } elseif ($a.login) { $a.login } else { $null }
        if ($login -eq $Config['bot_login']) { return $true }
    }
    return $false
}

function Claim-Issue {
    [CmdletBinding()]
    param([int]$IssueNumber)
    # Atomic-ish claim: assign bot + move labels in one gh call.
    $out = & $script:GhBin issue edit "$IssueNumber" --repo $Config['repo'] `
        --add-assignee $Config['bot_login'] `
        --remove-label 'autonomous' `
        --add-label 'in-progress' 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Lost the race / label moved -> not ours.
        Write-Log "Claim failed for #$IssueNumber : $out" -Level 'WARN'
        return $false
    }
    # Re-check: confirm the bot actually owns it now.
    $view = Invoke-Gh @('issue', 'view', "$IssueNumber", '--repo', $Config['repo'],
        '--json', 'number,assignees,labels') | ConvertFrom-Json
    if (-not (Test-IssueClaimedByBot -Issue $view)) {
        Write-Log "Claim race lost for #$IssueNumber (bot not assignee)" -Level 'WARN'
        return $false
    }
    return $true
}

# ============================================================
# Workspace + gate 0
# ============================================================
<#
.SYNOPSIS
  Write a GIT_ASKPASS helper that supplies the bot token only when git prompts,
  so the token is never embedded in the clone URL. Embedding the token in the
  URL persists it in <workspace>/.git/config (m12); the helper file only
  references the token via the environment (no secret is written to disk).
  The helper is stored under <DataDir> (git-ignored runtime dir).
#>
function Write-GitAskPass {
    [CmdletBinding()]
    param()
    $token = [System.Environment]::GetEnvironmentVariable('GH_TOKEN')
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }

    if ($IsWindows) {
        $path = Join-Path $script:DataDir '.git-askpass.cmd'
        $content = "@echo off`r`n" +
            'echo %1 | findstr /i "username" >nul' + "`r`n" +
            'if %errorlevel%==0 (echo x-access-token) else (echo %GH_TOKEN%)' + "`r`n" +
            'exit /b 0' + "`r`n"
    } else {
        $path = Join-Path $script:DataDir '.git-askpass.sh'
        $content = "#!/bin/sh`n" +
            'case "$1" in' + "`n" +
            '  *[Uu]sername*) printf "%s\n" "x-access-token" ;;' + "`n" +
            '  *) printf "%s\n" "$GH_TOKEN" ;;' + "`n" +
            'esac' + "`n"
    }
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $IsWindows) {
        # Linux: the helper must be executable (best-effort).
        & bash -c "chmod +x '$path'" 2>$null | Out-Null
    }
    [System.Environment]::SetEnvironmentVariable('GIT_ASKPASS', $path)
    # Never hang on an interactive credential prompt; fail instead.
    [System.Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0')
    return $path
}

function Get-RepoCloneUrl {
    # No token here by design (m12): Write-GitAskPass supplies credentials when
    # git prompts. The workspace lives under <DataDir>/workspaces (git-ignored),
    # but keeping the token out of .git/config is the real fix.
    return "https://github.com/$($Config['repo']).git"
}

function Initialize-Workspace {
    [CmdletBinding()]
    param([string]$Workspace, [string]$Branch)
    if (Test-Path -LiteralPath (Join-Path $Workspace '.git')) {
        Write-Log "Workspace exists, fetching (resume path)"
        Push-Location $Workspace
        try {
            git fetch --all 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git fetch failed in $Workspace" }
        } finally { Pop-Location }
        return
    }
    if (-not (Test-Path -LiteralPath $Workspace)) { New-Item -ItemType Directory -Path $Workspace -Force | Out-Null }
    Write-Log "Cloning $($Config['repo']) into $Workspace"
    Push-Location (Split-Path -Parent $Workspace)
    try {
        git clone --no-checkout (Get-RepoCloneUrl) $Workspace 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Workspace" }
    } finally { Pop-Location }
}

function Checkout-IssueBranch {
    [CmdletBinding()]
    param([string]$Workspace, [string]$Branch)
    Push-Location $Workspace
    try {
        $branches = git branch -a 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'git branch -a failed' }
        $branchExists = ($branches | Select-String -SimpleMatch "origin/$Branch") -ne $null -or
                        ($branches | Select-String -SimpleMatch "  $Branch") -ne $null
        if ($branchExists) {
            git checkout "$Branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        } else {
            git checkout -b "$Branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git checkout -b $Branch failed" }
        }
    } finally { Pop-Location }
}

function Commit-PipelineState {
    [CmdletBinding()]
    param([string]$Workspace, [object]$State, [string]$Message)
    Push-Location $Workspace
    try {
        $statePath = Join-Path $Workspace 'pipeline-state.json'
        Write-PipelineState -Path $statePath -State $State | Out-Null
        git add pipeline-state.json 2>&1 | Out-Null
        git -c user.name="$($Config['bot_login'])" -c user.email="$($Config['bot_login'])@users.noreply.github.com" `
            commit -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # nothing to commit is fine (same state)
            Write-Log "No new pipeline-state changes to commit" -Level 'DEBUG'
        } else {
            Write-Log "Committed pipeline-state ($Message)"
        }
    } finally { Pop-Location }
}

function New-IssueSnapshot {
    param([object]$Issue)
    # Real gh returns label objects; the mock returns plain strings.
    $labelNames = @($Issue.labels | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($_.name) { $_.name } else { "$_" }
    })
    return @{
        title  = $Issue.title
        body   = $Issue.body
        labels = $labelNames
        url    = $Issue.url
    }
}

# ============================================================
# Prompt assembly
# ============================================================
function Build-DevPrompt {
    [CmdletBinding()]
    param(
        [object]$State,
        [object]$Issue,
        [string]$BrainPath
    )
    $gatesText = ($State.gates.PSObject.Properties | ForEach-Object { "  - $($_.Name): $($_.Value)" }) -join "`n"
    $completedText = ($State.completed -join ', ')
    $pendingText = ($State.pending -join ', ')

    $brain = if ($BrainPath) { $BrainPath } else { '<AIOS_BRAIN_PATH not set>' }

    return @"
# Autonomad dev task — $(if ($Issue) { $Issue.title })

You are the Autonomad dev agent for issue **#$($State.issue_number)** in **$($State.repo)**.

## Task
Develop the issue described below. Load the repo-native marketplace skills and consult the
AIOS brain (read-only) where helpful. Follow the pipeline-state gates strictly: complete each
gate in order, run the build and test commands green BEFORE advancing, and commit
pipeline-state.json after every gate.

## Issue
Title: $(if ($Issue) { $Issue.title } else { $State.issue_ref })
Body:
$(if ($Issue) { $Issue.body } else { '' })

## Repo configuration
- Harness: $($State.harness)
- Model override: $(if ($State.model) { $State.model } else { '<harness default>' })
- Build command: $($Config['build_command'])
- Test command: $($Config['test_command'])

## Pipeline state (current)
- current_step: $($State.current_step)
- next_gate: $($State.next_gate)
- attempts: $($State.attempts) / max $($State.max_retries)
- completed gates: $($completedText)
- pending gates: $($pendingText)
- gate statuses:
$gatesText

## Gates (order)
branch_guard -> implementation -> tester_gate -> review_gate -> security_gate -> verifier_gate -> commit_push -> artifact_report -> github_sync -> human_approval

Resume from `next_gate` if it is not the first gate. Do NOT re-run completed gates.

## AIOS brain (READ-ONLY)
The brain is mounted read-only at:
- /brain/graphify-out  (knowledge graph output)
- /brain/context       (context docs)
- /brain/references    (reference material)
- /brain/decisions     (decision records)
- /brain/skills        (skills — loaded via skills.paths)
- /brain/agents        (agent specs)
Host brain path: $brain

You may READ the brain freely. NEVER write to /brain.

## Marketplace
Repo-native agent specs are in /opt/autonomad/marketplace (dev.agent.md, verifier.agent.md).
Use dev.agent.md for this task. verifier.agent.md is available but NOT used in the dev flow.

## Autonomy boundary (from AGENTS.md)
- You develop and commit locally. The tick loop pushes and opens the PR.
- NEVER merge. NEVER apply the `approved` label. NEVER close the issue.
- If the plan confidence is < 0.90, if the plan escalates out of scope, or if you hit a fatal
  flaw, STOP and write pipeline-state.json with status=needs-human and a halt_reason.

## Output contract
Write pipeline-state.json to the workspace root after every gate and commit it. After the
final gate, ensure status is one of: in_progress (more gates), needs-human (halt), or done.
Report your outcome in /workspace/.autonomad/result.json with this shape:
{
  "outcome": "success" | "needs-human" | "failed",
  "confidence": 0.0-1.0,
  "fatal_flaw": bool,
  "plan_escalation": bool,
  "summary": "short summary"
}
"@
}

# ============================================================
# Sandbox result handling
# ============================================================
function Read-ResultJson {
    param([string]$Workspace)
    # Multi-arg Join-Path (not a literal backslash): on Linux a backslash is a
    # legal filename character, so '.autonomad\result.json' would never resolve.
    $p = Join-Path $Workspace '.autonomad' 'result.json'
    if (-not (Test-Path -LiteralPath $p)) {
        # The mock agent may only write pipeline-state; synthesize a result.
        return $null
    }
    try {
        return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    } catch {
        Write-Log "result.json unreadable: $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}

# ============================================================
# Close-out (T6)
# ============================================================
function Close-OutIssue {
    [CmdletBinding()]
    param([object]$State, [object]$Issue, [string]$Workspace)

    $branch = $State.branch
    $issueRef = $State.issue_ref

    # Push branch
    Push-Location $Workspace
    try {
        git push -u origin "$branch" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git push failed for branch $branch" }
    } finally { Pop-Location }
    Write-Log "Pushed branch $branch"

    # PR
    $prBody = "Fixes #$($State.issue_number)`n`nAutonomad v1 — developed autonomously. See the report for details."
    $prBodyFile = Join-Path $script:DataDir "pr-body-$issueRef.md"
    [System.IO.File]::WriteAllText($prBodyFile, $prBody, (New-Object System.Text.UTF8Encoding($false)))
    $prOut = Invoke-Gh @('pr', 'create', '--repo', $Config['repo'], '--title', "Autonomad: $($Issue.title)",
        '--body-file', $prBodyFile, '--head', $branch, '--base', $Config['base_branch']) | Out-String
    Remove-Item -LiteralPath $prBodyFile -Force
    $prUrl = ($prOut | Select-String -Pattern 'https://github.com/.*/pull/\d+' | Select-Object -First 1).Matches.Value
    if (-not $prUrl) { $prUrl = $prOut.Trim() }
    Write-Log "PR created: $prUrl"

    # Label pending-review
    Set-IssueLabel -IssueNumber $State.issue_number -Add @('pending-review') -Remove @('in-progress')

    # Update state
    $State.status = 'pending-review'
    $State.pr_url = $prUrl
    $State.current_step = 'github_sync'
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $State.PSObject.Properties.Name.Contains('timestamps')) { $State | Add-Member -NotePropertyName timestamps -NotePropertyValue @{} }
    $State.timestamps.github_sync = (Get-Date).ToUniversalTime().ToString('o')

    # Report + runs.log (T6) — runs.log lands in reports/ (matches .gitignore).
    & (Join-Path $PSScriptRoot 'report.ps1') -State $State -ReportsDir $script:ReportsDir -LogsDir $script:ReportsDir -Issue $Issue
    if ($LASTEXITCODE -ne 0) { Write-Log "report.ps1 failed (exit $LASTEXITCODE)" -Level 'WARN' }

    return $State
}

# ============================================================
# Halt (T7)
# ============================================================
function Halt-Issue {
    [CmdletBinding()]
    param([object]$State, [object]$Issue, [string]$Reason)
    Write-Log "HALT #$($State.issue_number): $Reason" -Level 'WARN'
    $State.status = 'needs-human'
    $State.halt_reason = $Reason
    $State.current_step = 'halted'
    $State.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $statePath = Join-Path (Join-Path $script:WorkspacesDir $State.issue_ref) 'pipeline-state.json'
    if (Test-Path -LiteralPath $statePath) {
        Write-PipelineState -Path $statePath -State $State | Out-Null
        Commit-PipelineState -Workspace (Join-Path $script:WorkspacesDir $State.issue_ref) -State $State -Message "halt: needs-human"
    }
    try {
        Set-IssueLabel -IssueNumber $State.issue_number -Add @('needs-human') -Remove @('in-progress', 'autonomous')
        Add-IssueComment -IssueNumber $State.issue_number -Body "Autonomad halted and needs a human. Reason: $Reason"
    } catch {
        Write-Log "Halt label/comment failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

# ============================================================
# Resume detection
# ============================================================
function Find-ResumableIssue {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:WorkspacesDir)) { return $null }
    $ttlSeconds = [int]$Config['ttl']
    foreach ($dir in Get-ChildItem -LiteralPath $script:WorkspacesDir -Directory) {
        $statePath = Join-Path $dir.FullName 'pipeline-state.json'
        if (-not (Test-Path -LiteralPath $statePath)) { continue }
        try {
            $state = Read-PipelineState -Path $statePath -SchemaPath $script:SchemaPath
        } catch {
            # Fails closed: an unreadable state is a plan-level failure -> halt
            Write-Log "Resume scan: unreadable pipeline-state in $($dir.Name): $($_.Exception.Message)" -Level 'WARN'
            continue
        }
        if ($state.status -eq 'needs-human') {
            Write-Log "Skipping $($dir.Name): needs-human" -Level 'DEBUG'
            continue
        }
        if ($state.status -in @('claimed', 'in_progress')) {
            # TTL-stale -> HALT with needs-human + comment (m7). Silently skipping
            # would strand the claim: the issue keeps the bot's assignee and the
            # in-progress label forever, so no human or bot can pick it up.
            $age = $null
            try {
                $updated = [datetime]::Parse($state.updated_at)
                $age = ((Get-Date).ToUniversalTime() - $updated).TotalSeconds
            } catch {
                Write-Log "Resume scan: unparseable updated_at in $($dir.Name): $($_.Exception.Message)" -Level 'WARN'
            }
            if ($null -eq $age) {
                # Cannot compute staleness -> do not blindly resume; leave it for
                # the next run (fails closed without stranding anything new).
                Write-Log "Skipping $($dir.Name): cannot compute age (no TTL handling)" -Level 'WARN'
                continue
            }
            if ($age -gt $ttlSeconds) {
                Write-Log "TTL-stale $($dir.Name) ($([math]::Round($age))s > ${ttlSeconds}s) — halting with needs-human" -Level 'WARN'
                try {
                    Halt-Issue -State $state -Reason "TTL-stale: in-progress for $([math]::Round($age))s (ttl=${ttlSeconds}s); Autonomad halted the stranded claim"
                } catch {
                    Write-Log "TTL-stale halt failed for $($dir.Name): $($_.Exception.Message)" -Level 'ERROR'
                }
                continue
            }
            # Confirm the issue is still open + assigned to bot
            try {
                $view = Invoke-Gh @('issue', 'view', "$($state.issue_number)", '--repo', $Config['repo'],
                    '--json', 'state,assignees,labels') | ConvertFrom-Json
                if ($view.state -ne 'OPEN') { Write-Log "Skipping $($dir.Name): issue not open"; continue }
                if (-not (Test-IssueClaimedByBot -Issue $view)) { Write-Log "Skipping $($dir.Name): not assigned to bot"; continue }
            } catch {
                Write-Log "Skipping $($dir.Name): cannot verify issue state: $($_.Exception.Message)" -Level 'WARN'
                continue
            }
            return @{ State = $state; Workspace = $dir.FullName }
        }
    }
    return $null
}

# ============================================================
# One issue lifecycle
# ============================================================
function Process-Issue {
    [CmdletBinding()]
    param([object]$Issue, [object]$Resume = $null)

    $issueNum = $Issue.number
    $issueRef = "issue-$issueNum"
    $branch = "$($Config['branch_prefix'])/$issueRef"
    $workspace = Join-Path $script:WorkspacesDir $issueRef

    # --- resume vs new ---
    $state = $null
    if ($Resume) {
        $state = $Resume.State
        $workspace = $Resume.Workspace
        $branch = $state.branch
        $issueRef = $state.issue_ref
        $issueNum = $state.issue_number
        Write-Log "RESUME #$issueNum from gate '$($state.next_gate)'"
        Initialize-Workspace -Workspace $workspace -Branch $branch
    } else {
        # Gate 0
        Write-Log "CLAIM #$issueNum"
        Initialize-Workspace -Workspace $workspace -Branch $branch
        Checkout-IssueBranch -Workspace $workspace -Branch $branch
        $state = New-PipelineState -IssueNumber $issueNum -Repo $Config['repo'] -Branch $branch `
            -Owner $Config['bot_login'] -Harness $Config['harness'] -Model $Config['model'] `
            -MaxRetries ([int]$Config['max_retries']) -IssueSnapshot (New-IssueSnapshot -Issue $Issue)
        $state.status = 'in_progress'
        $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Commit-PipelineState -Workspace $workspace -State $state -Message "gate 0: claim #$issueNum (branch_guard)"
        Write-Log "Gate 0 complete: branch_guard"
    }

    $prompt = Build-DevPrompt -State $state -Issue $Issue -BrainPath $script:BrainRoot

    # --- run sandbox (dev agent) ---
    $result = Invoke-Sandbox -Config $Config -State $state -Workspace $workspace -Prompt $prompt `
        -DataDir $script:DataDir -EnvFile $EnvFile -BrainRoot $script:BrainRoot

    # --- read back the dev agent's state (FAILS CLOSED) ---
    $statePath = Join-Path $workspace 'pipeline-state.json'
    try {
        $newState = Read-PipelineState -Path $statePath -SchemaPath $script:SchemaPath
    } catch {
        Write-Log "Missing/empty pipeline-state after sandbox: fails closed." -Level 'ERROR'
        if ($Resume) {
            Halt-Issue -State $state -Issue $Issue -Reason "pipeline-state missing/empty after dev run (plan-level failure)"
        } else {
            Halt-Issue -State $state -Issue $Issue -Reason "pipeline-state missing/empty after dev run (plan-level failure)"
        }
        return
    }
    $agentResult = Read-ResultJson -Workspace $workspace
    $outcome = if ($agentResult -and $agentResult.outcome) { $agentResult.outcome } else { $newState.status }

    # --- halt triggers (T7) ---
    $confidence = if ($agentResult -and $null -ne $agentResult.confidence) { [double]$agentResult.confidence } else { 1.0 }
    $fatalFlaw = ($agentResult -and $agentResult.fatal_flaw)
    $escalation = ($agentResult -and $agentResult.plan_escalation)

    if ($newState.status -eq 'needs-human') {
        # halt_reason is dev-agent-controlled text — trim and cap length; display-only.
        $reason = [string]$newState.halt_reason
        if ($reason.Length -gt 500) { $reason = $reason.Substring(0, 500) }
        $reason = ($reason -replace '\s+', ' ').Trim()
        Halt-Issue -State $newState -Issue $Issue -Reason ($reason ?? 'dev agent requested human halt')
        return
    }
    if ($confidence -lt 0.90) {
        Halt-Issue -State $newState -Issue $Issue -Reason "plan confidence $([math]::Round($confidence*100))% < 90%"
        return
    }
    if ($fatalFlaw) {
        Halt-Issue -State $newState -Issue $Issue -Reason 'fatal flaw reported by dev agent'
        return
    }
    if ($escalation) {
        Halt-Issue -State $newState -Issue $Issue -Reason 'plan escalation reported by dev agent'
        return
    }
    if ($outcome -eq 'failed') {
        $newState.attempts = [int]$newState.attempts + 1
        $newState.last_error = if ($agentResult -and $agentResult.summary) { $agentResult.summary } else { 'dev run failed' }
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        Commit-PipelineState -Workspace $workspace -State $newState -Message "attempt $($newState.attempts) failed"
        Write-Log "Dev run failed (attempt $($newState.attempts)/$($Config['max_retries']))"
        if ($newState.attempts -ge [int]$Config['max_retries']) {
            Halt-Issue -State $newState -Issue $Issue -Reason "N=$($Config['max_retries']) failed attempts (hard stop)"
        } else {
            Write-Log "Retrying #$issueNum (attempt $($newState.attempts))"
        }
        return
    }

    # --- success path ---
    if ($outcome -eq 'success' -or (Test-PipelineComplete -State $newState)) {
        Write-Log "Dev run green for #$issueNum — close-out"
        $newState = Close-OutIssue -State $newState -Issue $Issue -Workspace $workspace
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        Commit-PipelineState -Workspace $workspace -State $newState -Message "close-out: PR created"
        # Harvest (T8)
        & (Join-Path $PSScriptRoot 'learn.ps1') -State $newState -Workspace $workspace -DataDir $script:DataDir -Mode closeout
        if ($LASTEXITCODE -ne 0) { Write-Log "learn.ps1 (closeout) failed (exit $LASTEXITCODE)" -Level 'WARN' }
        Write-Log "DONE #$issueNum — PR $($newState.pr_url) pending human review."
        return
    }

    Write-Log "Dev run finished with status '$outcome' (no close-out condition) — will re-poll."
}

# ============================================================
# Main loop
# ============================================================
function Write-Heartbeat {
    [System.IO.File]::WriteAllText($script:HeartbeatFile, (Get-Date).ToUniversalTime().ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
}

function Test-IdleTimeout {
    param([datetime]$LastWorkAt)
    if (-not $LastWorkAt) { return $false }
    $idleSeconds = [int]$Config['idle_timeout']
    $elapsed = ((Get-Date).ToUniversalTime() - $LastWorkAt).TotalSeconds
    return ($elapsed -gt $idleSeconds)
}

$script:LogFile = Join-Path $script:LogsDir 'tick.log'

Write-Log "Autonomad tick starting (repo=$($Config['repo']), harness=$($Config['harness']), data=$DataDir)"
Write-Log "Brain root: $(if ($script:BrainRoot) { $script:BrainRoot } else { '<unset>' })"
Write-Log "Sandbox mode: $([System.Environment]::GetEnvironmentVariable('AUTONOMAD_SANDBOX_MODE') ?? 'docker')"

# Init: idempotent labels
Ensure-Labels
# Wire git auth (m12): GIT_ASKPASS supplies the bot token at prompt time instead
# of embedding it in the clone URL (keeps it out of <workspace>/.git/config).
$script:AskPassPath = Write-GitAskPass
Write-Heartbeat

$tickCount = 0
$lastWorkAt = (Get-Date).ToUniversalTime()

while ($true) {
    $tickCount++
    Write-Heartbeat

    if ($MaxTicks -gt 0 -and $tickCount -gt $MaxTicks) {
        Write-Log "MaxTicks ($MaxTicks) reached — exiting."
        exit 0
    }

    # 1) Resume any in-progress issue owned by the bot first (crash recovery, Q16).
    $resumable = Find-ResumableIssue
    if ($resumable) {
        try {
            $issueView = Invoke-Gh @('issue', 'view', "$($resumable.State.issue_number)", '--repo', $Config['repo'],
                '--json', 'number,title,url,body,labels,assignees') | ConvertFrom-Json
            Process-Issue -Issue $issueView -Resume $resumable
        } catch {
            Write-Log "Resume processing failed: $($_.Exception.Message)" -Level 'ERROR'
        }
        $lastWorkAt = (Get-Date).ToUniversalTime()
        if ($Once) { exit 0 }
        # m8: backoff between resume attempts. Without this, a workspace that
        # fails fast (e.g. an exception mid-resume) spins the loop at full speed.
        Start-Sleep -Seconds 5
        continue
    }

    # 2) Poll for a fresh autonomous issue.
    $candidate = $null
    try {
        $candidate = Get-CandidateIssue
    } catch {
        Write-Log "Poll failed: $($_.Exception.Message)" -Level 'ERROR'
    }

    if (-not $candidate) {
        Write-Log "No autonomous issue available — idle."
        if ($Once) {
            Write-Log "--once: nothing to do, exiting cleanly."
            exit 0
        }
        if (Test-IdleTimeout -LastWorkAt $lastWorkAt) {
            Write-Log "Idle timeout ($($Config['idle_timeout'])s) reached — exiting."
            exit 0
        }
        Start-Sleep -Seconds ([int]$Config['poll_interval'])
        continue
    }

    # 3) Claim + process.
    if (Claim-Issue -IssueNumber $candidate.number) {
        Write-Log "Claimed #$($candidate.number)"
        $lastWorkAt = (Get-Date).ToUniversalTime()
        try {
            Process-Issue -Issue $candidate
        } catch {
            Write-Log "Issue processing failed: $($_.Exception.Message)" -Level 'ERROR'
            # Fails closed on unexpected errors -> needs-human on the claimed issue.
            try {
                Halt-Issue -State (New-PipelineState -IssueNumber $candidate.number -Repo $Config['repo'] `
                    -Branch "$($Config['branch_prefix'])/issue-$($candidate.number)" -Owner $Config['bot_login']) `
                    -Issue $candidate -Reason "unhandled tick error: $($_.Exception.Message)"
            } catch {
                Write-Log "Halt fallback also failed: $($_.Exception.Message)" -Level 'ERROR'
            }
        }
    } else {
        Write-Log "Could not claim #$($candidate.number) (race or labels changed)."
    }

    if ($Once) { exit 0 }
}
