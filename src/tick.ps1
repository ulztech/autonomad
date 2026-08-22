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
#   pwsh -File src/tick.ps1 [-Once] [-ReconcileOnce [-ReconcileDryRun]] [-ConfigPath x] [-DataDir y] [-GhBin z] [-MaxTicks n]
#
# Env overrides:
#   GH_BIN                gh executable (tests inject a mock)
#   AUTONOMAD_SANDBOX_MODE  docker | mock   (mock = dry-run E2E without docker)

[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$ReconcileOnce,
    [switch]$ReconcileDryRun,
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
# Load .env into the process env. Capture the return — otherwise the parsed
# hashtable (including API key values) is emitted to stdout. SECURITY: never
# let .env contents reach stdout/logs.
$null = Import-EnvFile -EnvFilePath $EnvFile
$script:BrainRoot = if ($BrainRoot) { $BrainRoot } else {
    [System.Environment]::GetEnvironmentVariable('AIOS_BRAIN_PATH')
}
$script:SchemaPath = Get-PipelineSchemaPath -RepoRoot $RepoRoot
$script:DataDir = $DataDir
$script:WorkspacesDir = Join-Path $DataDir 'workspaces'
$script:ReportsDir = Join-Path $DataDir 'reports'
$script:LogsDir = Join-Path $DataDir 'logs'
$script:HeartbeatFile = Join-Path $DataDir 'last_tick.ts'
$script:TickStateFile = Join-Path $DataDir 'tick-state.json'
$script:TickStatus = 'idle'      # 'idle' | 'working' — read by the reconcile quiet-gate
$script:TickClaim = $null        # issue-ref currently being processed, if any
$script:LastWorkUtc = $null      # null = never worked a claim (fresh tick is idle)
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
    'ready-for-agent' = 'Ready for the autonomous developer (dual-label board)'
    'in-progress'    = 'Currently being developed by Autonomad'
    'pending-review' = 'PR opened; waiting for human review'
    'reviewing'      = 'Human reviewer is reviewing the PR'
    'approved'       = 'Human approved; ready to merge'
    'needs-human'    = 'Autonomad halted; requires human intervention'
    'blocked'        = 'Blocked on an open dependency (Depends on / Blocked by #N)'
}
$script:LabelColors = @{
    'autonomous'     = '0E8A16'
    'ready-for-agent' = '0E8A16'
    'in-progress'    = 'FB9C00'
    'pending-review' = '1D76DB'
    'reviewing'      = 'B60205'
    'approved'       = '5319E7'
    'needs-human'    = 'D93F0B'
    'blocked'        = 'C5DEF5'
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
    param([int]$IssueNumber, [string[]]$Add = @(), [string[]]$Remove = @(), [string]$Repo = '')
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    if ($Add.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Repo, '--add-label', ($Add -join ',')) | Out-Null
    }
    if ($Remove.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Repo, '--remove-label', ($Remove -join ',')) | Out-Null
    }
}

<#
.SYNOPSIS
  Normalize an issue's labels array to plain strings. Real gh returns label
  objects; the mock returns plain strings. Both must compare the same.
#>
function Get-IssueLabelNames {
    [CmdletBinding()]
    param([object]$Issue)
    # `,@()` keeps the result an array even when the issue has no labels.
    return ,@($Issue.labels | ForEach-Object {
        if ($_ -is [string]) { $_ } elseif ($_.name) { $_.name } else { "$_" }
    })
}

function Add-IssueComment {
    param([int]$IssueNumber, [string]$Body, [string]$Repo = '')
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    $bodyFile = Join-Path $script:DataDir "comment-$IssueNumber.md"
    [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Gh @('issue', 'comment', "$IssueNumber", '--repo', $Repo, '--body-file', $bodyFile) | Out-Null
    Remove-Item -LiteralPath $bodyFile -Force
}

# ============================================================
# Live display sync (Phase 3 — AIOS pipeline-state pattern)
# ============================================================
<#
.SYNOPSIS
  Human-readable gate names for the issue-body checklist.
#>
$script:GateDisplayNames = @{
    'branch_guard'   = 'Branch Guard'
    'implementation' = 'Implementation'
    'tester_gate'    = 'Tester Gate'
    'review_gate'    = 'Review Gate'
    'security_gate'  = 'Security Gate'
    'verifier_gate'  = 'Verifier Gate'
    'commit_push'    = 'Commit & Push'
    'artifact_report' = 'Artifact Report'
    'github_sync'    = 'GitHub Sync'
    'human_approval' = 'Human Approval'
}

<#
.SYNOPSIS
  Rebuild the issue body's pipeline checklist so completed gates read - [x].
  Idempotent: replaces any existing "### Pipeline" block with the current gate
  states from pipeline-state.json (AIOS display-sync pattern).
#>
function Sync-IssueChecklist {
    [CmdletBinding()]
    param([int]$IssueNumber, [object]$State)
    $repo = $State.repo ?? $Config['repo']
    try {
        $view = Invoke-Gh @('issue', 'view', "$IssueNumber", '--repo', $repo,
            '--json', 'body') | ConvertFrom-Json
    } catch {
        Write-Log "Checklist sync: cannot read issue body: $($_.Exception.Message)" -Level 'WARN'
        return
    }
    $body = [string]$view.body
    # Keep everything above the current Pipeline block (if any), drop the rest.
    $idx = $body.IndexOf('### Pipeline')
    if ($idx -ge 0) { $body = $body.Substring(0, $idx).TrimEnd() }
    # Build the checklist from the live gate states.
    $lines = @('', '### Pipeline', '')
    foreach ($g in $script:AllGates) {
        $disp = $script:GateDisplayNames[$g]
        $st = try { $State.gates.$g } catch { 'pending' }
        $box = if ($st -eq 'completed') { 'x' } else { ' ' }
        $lines += "- [$box] $disp"
    }
    $lines += ''
    $newBody = ($body.TrimEnd() + ($lines -join "`n")).Trim()
    # Preserve the original Pipeline header marker for idempotent re-sync.
    if ($newBody -notmatch '### Pipeline') { $newBody = $body.TrimEnd() + "`n### Pipeline`n" + ($lines[2..($lines.Count - 1)] -join "`n") }
    try {
        $bodyFile = Join-Path $script:DataDir "checklist-$IssueNumber.md"
        [System.IO.File]::WriteAllText($bodyFile, $newBody, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $repo, '--body-file', $bodyFile) | Out-Null
        Remove-Item -LiteralPath $bodyFile -Force
        Write-Log "Checklist synced for #$IssueNumber" -Level 'DEBUG'
    } catch {
        Write-Log "Checklist sync failed for #$IssueNumber : $($_.Exception.Message)" -Level 'WARN'
    }
}

<#
.SYNOPSIS
  Append a structured gate comment (AIOS pipeline-state display pattern):
    ## Gate: <name> — pass|fail|blocked
#>
function Add-GateComment {
    [CmdletBinding()]
    param(
        [int]$IssueNumber,
        [string]$Gate,
        [string]$Status,      # pass | fail | blocked
        [string]$Agent = 'autonomad-tick',
        [hashtable]$Fields = @{},
        [string]$Summary = '',
        [string]$Repo = ''
    )
    $lines = @(
        "## Gate: $Gate — $Status",
        '',
        '| Field | Value |',
        '|-------|-------|',
        "| agent | $Agent |",
        "| status | $Status |",
        "| gate | $Gate |",
        "| ts | $((Get-Date).ToUniversalTime().ToString('o')) |"
    )
    foreach ($k in $Fields.Keys) { $lines += "| $k | $($Fields[$k]) |" }
    if ($Summary) {
        $lines += '', '### Summary', $Summary
    }
    Add-IssueComment -IssueNumber $IssueNumber -Body ($lines -join "`n") -Repo $Repo
}

<#
.SYNOPSIS
  Post the canonical `## Tracking` block on a claimed issue (Phase 2). This is
  the single reference point both the human and autonomad anchor on: the ticket
  number, its root ticket, the (possibly reused) branch, and the PR.
  `tracking_ref` is the ticket number (#N); `root_ref` is the root of the
  revision chain (equals tracking_ref for a root ticket).
#>
function Add-TrackingComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$IssueNumber,
        [Parameter(Mandatory = $true)][int]$TrackingRef,
        [int]$RootRef = 0,
        [string]$Branch = '',
        [string]$PrUrl = '',
        [string]$Repo = ''
    )
    $lines = @(
        '## Tracking',
        '',
        '| Field | Value |',
        '|-------|-------|',
        "| tracking_ref | #$TrackingRef |",
        "| root_ref | #$(if ($RootRef -gt 0) { $RootRef } else { $TrackingRef }) |",
        "| branch | $Branch |",
        "| pr | $($PrUrl -replace '\|', '&#124;') |"
    )
    try {
        Add-IssueComment -IssueNumber $IssueNumber -Body ($lines -join "`n") -Repo $Repo
        $resolvedRoot = if ($RootRef -gt 0) { $RootRef } else { $TrackingRef }
        Write-Log "Tracking comment posted for #$IssueNumber (tracking_ref #$TrackingRef, root #$resolvedRoot)"
    } catch {
        Write-Log "Tracking comment failed for #$IssueNumber : $($_.Exception.Message)" -Level 'WARN'
    }
}

# ============================================================
# Poll + claim
# ============================================================
<#
.SYNOPSIS
  Extract dependency issue references ("Depends on #N" / "Blocked by #N")
  from an issue body. Returns an array of ints (deduped).
#>
function Get-DependencyRefs {
    [CmdletBinding()]
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return ,@() }
    $refs = @()
    # Inline form: "Blocked by #316" / "Depends on #316".
    foreach ($m in [regex]::Matches($Body, '(?i)(?:depends\s+on|blocked\s+by)\s+#(\d+)')) {
        $refs += [int]$m.Groups[1].Value
    }
    # Markdown-list form: a "Blocked by" / "Depends on" section whose following
    # list items are "- #N — description". Collect #N until the next heading.
    foreach ($m in [regex]::Matches($Body, '(?is)(?:depends\s+on|blocked\s+by)\b[^\r\n]*(?:\r?\n)(.*?)(?=\r?\n#{1,6}\s|\Z)')) {
        $section = $m.Groups[1].Value
        foreach ($item in [regex]::Matches($section, '(?im)^\s*(?:-|•|\*)?\s*#(\d+)\b')) {
            $refs += [int]$item.Groups[1].Value
        }
    }
    # `,@()` keeps the result an array even when empty (a bare empty array is
    # unrolled to $null on return, and .Count on $null throws under StrictMode).
    return ,@($refs | Sort-Object -Unique)
}

<#
.SYNOPSIS
  Extract the revision parent reference ("Parent: #N") from an issue body.
  Returns the issue number as an int, or $null when the body declares no parent.
  A ticket WITHOUT a `Parent: #N` marker IS the root of its revision chain.
#>
function Get-ParentRef {
    [CmdletBinding()]
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    foreach ($m in [regex]::Matches($Body, '(?i)parent\s*:\s*#(\d+)')) {
        return [int]$m.Groups[1].Value
    }
    return $null
}

<#
.SYNOPSIS
  Resolve the ROOT ticket of a revision chain by walking `Parent: #N` upward.
  A ticket with no parent marker IS the root (returns its own number). Cycle-
  safe (a chain that loops back returns the current number to avoid an infinite
  loop). Falls back to the current number when a parent cannot be fetched.
#>
function Resolve-RootRef {
    [CmdletBinding()]
    param(
        [object]$Issue,
        [string]$Repo = '',
        [hashtable]$Seen = @{}
    )
    if ($null -eq $Issue) { return $null }
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    $parent = Get-ParentRef -Body $Issue.body
    if ($null -eq $parent) { return [int]$Issue.number }
    if ($Seen.ContainsKey($Issue.number.ToString())) { return [int]$Issue.number }
    $Seen[$Issue.number.ToString()] = $true
    try {
        $view = Invoke-Gh @('issue', 'view', "$parent", '--repo', $Repo,
            '--json', 'number,body') | ConvertFrom-Json
        return Resolve-RootRef -Issue $view -Repo $Repo -Seen $Seen
    } catch {
        Write-Log "Cannot resolve parent #$parent for #$($Issue.number): $($_.Exception.Message) — treating as root" -Level 'WARN'
        return [int]$Issue.number
    }
}

<#
.SYNOPSIS
  Fetch the open/closed state of a single issue.
#>
function Get-IssueState {
    [CmdletBinding()]
    param([int]$IssueNumber)
    try {
        $view = Invoke-Gh @('issue', 'view', "$IssueNumber", '--repo', $Config['repo'],
            '--json', 'state') | ConvertFrom-Json
        return $view.state
    } catch {
        Write-Log "Cannot resolve dependency #$IssueNumber : $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}

<#
.SYNOPSIS
  Determine whether an issue is blocked by an open dependency. Manages the
  `blocked` label: adds it when a dependency is open, removes it when none are.
  Returns $true when blocked (a dependency is open).
#>
function Test-IssueBlocked {
    [CmdletBinding()]
    param([object]$Issue)
    $deps = Get-DependencyRefs -Body $Issue.body
    $labelNames = Get-IssueLabelNames -Issue $Issue
    if ($deps.Count -eq 0) {
        # No dependency declared — make sure a stale blocked label is dropped.
        if ($labelNames -contains 'blocked') {
            Set-IssueLabel -IssueNumber $Issue.number -Remove @('blocked')
        }
        return $false
    }
    foreach ($dep in $deps) {
        $st = Get-IssueState -IssueNumber $dep
        if ($st -eq 'OPEN') {
            Set-IssueLabel -IssueNumber $Issue.number -Add @('blocked')
            Write-Log "#$($Issue.number) blocked by open dependency #$dep" -Level 'DEBUG'
            return $true
        }
    }
    if ($labelNames -contains 'blocked') {
        Set-IssueLabel -IssueNumber $Issue.number -Remove @('blocked')
    }
    return $false
}

<#
.SYNOPSIS
  Safely read a property off a state object. Under StrictMode, accessing a
  missing property throws; older workspaces (pre revision loop) have no
  parent_ref/root_ref, so every read must be guarded.
#>
function Get-StateProp {
    [CmdletBinding()]
    param([object]$State, [string]$Name)
    if ($null -eq $State) { return $null }
    if ($State -is [System.Collections.IDictionary]) {
        return if ($State.Contains($Name)) { $State[$Name] } else { $null }
    }
    if ($State.PSObject.Properties.Name -contains $Name) { return $State.$Name }
    return $null
}

<#
.SYNOPSIS
  True when the state belongs to a revision child (root_ref set and != its own
  issue number), i.e. it must reuse the root's branch + open PR.
#>
function Test-IsRevisionChild {
    [CmdletBinding()]
    param([object]$State)
    $root = Get-StateProp -State $State -Name 'root_ref'
    if ($null -eq $root) { return $false }
    $own = Get-StateProp -State $State -Name 'issue_number'
    return ([int]$root -ne [int]$own)
}

function Get-CandidateIssue {
    [CmdletBinding()]
    param()
    # NOTE: real gh (>=2.40) rejects `--assignee none` (treats it as a literal login).
    # Use the search API so unassigned + labeled issues resolve correctly.
    # Dual-label poll (B2): claim tickets that carry EITHER `ready-for-agent` OR
    # `autonomous` (labels-as-board; both mean "pick me up next").
    $json = Invoke-Gh @('issue', 'list', '--repo', $Config['repo'],
        '--search', 'is:open no:assignee (label:"ready-for-agent" OR label:"autonomous")',
        '--json', 'number,title,url,body,labels,assignees')
    # @(...) so a single-row search result stays enumerable (ConvertFrom-Json
    # collapses a one-element JSON array to a scalar).
    $items = @($json | ConvertFrom-Json)
    if ($items.Count -eq 0) { return $null }
    # Dependency-aware selection: claim the LOWEST-numbered UNBLOCKED ticket.
    $unblocked = @()
    foreach ($item in @($items | Sort-Object { [int]$_.number })) {
        if (Test-IssueBlocked -Issue $item) { continue }
        $unblocked += $item
    }
    if ($unblocked.Count -eq 0) { return $null }
    return $unblocked[0]
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
            # `git clone --no-checkout` leaves an empty index, so `git checkout -b`
            # creates the branch without populating the working tree. Force a full
            # checkout so the dev agent sees the repo's files.
            git reset --hard HEAD 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git reset --hard after checkout -b failed" }
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
    return @{
        title  = $Issue.title
        body   = $Issue.body
        labels = Get-IssueLabelNames -Issue $Issue
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

$(Get-HandoffsForIssue -Issue $Issue)

## Repo configuration
- Harness: $($State.harness)
- Model override: $(if ($State.model) { $State.model } else { '<harness default>' })
- Build command: $($Config['build_command'])
- Test command: $($Config['test_command'])
$(if ($Config['test_runner']) {
@"
- Test runner (delegated): $($Config['test_runner'])
"@ } else { '' })

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

$(if ($Config['test_runner']) {
@"
## Test strategy (delegated)
A heavier test runner is configured: `$($Config['test_runner'])`. Do NOT rely on a
one-line test_command for verification. Delegate E2E / regression verification to
the AIOS sandbox / regression flow via the configured runner and report its result
as the tester_gate evidence.
"@ } else { '' })

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
  "summary": "short summary",
  "handoff": "markdown handoff for the NEXT agent in a chained-ticket sequence"
}
The `handoff` field is REQUIRED on success. It must be a concise markdown note
describing what this ticket changed, which files/tables/branches were touched,
what the next ticket in the chain needs to know (build prerequisites, new
interfaces/models, gotchas), and how to verify the change. The next agent reads
this verbatim, so write it for that reader.
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

<#
.SYNOPSIS
  Persist the dev agent's handoff note so the NEXT agent in a chained-ticket
  sequence can read what this ticket changed. Stored as
  <DataDir>/handoffs/issue-<N>.md (UTF-8). The next Build-DevPrompt injects any
  matching handoff for the ticket's dependencies. No-op when the agent supplied
  no handoff (e.g. needs-human / failed runs).
#>
function Save-Handoff {
    [CmdletBinding()]
    param([object]$AgentResult, [object]$State)
    if ($null -eq $AgentResult) { return }
    $handoff = if ($AgentResult.PSObject.Properties.Name -contains 'handoff') { [string]$AgentResult.handoff } else { '' }
    if ([string]::IsNullOrWhiteSpace($handoff)) { return }
    $handoffDir = Join-Path $script:DataDir 'handoffs'
    if (-not (Test-Path -LiteralPath $handoffDir)) { New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null }
    $issueRef = $State.issue_ref
    $target = Join-Path $handoffDir "$issueRef.md"
    [System.IO.File]::WriteAllText($target, $handoff.TrimEnd() + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Handoff saved for $issueRef → $target"
}

<#
.SYNOPSIS
  Load handoff notes for any dependency issues the current ticket declares
  (`Blocked by #N` / `Depends on #N`) so the chained-ticket agent sees what the
  upstream ticket changed. Returns a markdown block or '' when none exist.
#>
function Get-HandoffsForIssue {
    [CmdletBinding()]
    param([object]$Issue)
    if ($null -eq $Issue -or [string]::IsNullOrWhiteSpace($Issue.body)) { return '' }
    $deps = Get-DependencyRefs -Body $Issue.body
    if ($deps.Count -eq 0) { return '' }
    $handoffDir = Join-Path $script:DataDir 'handoffs'
    if (-not (Test-Path -LiteralPath $handoffDir)) { return '' }
    $blocks = @()
    foreach ($dep in $deps) {
        $f = Join-Path $handoffDir "issue-$dep.md"
        if (Test-Path -LiteralPath $f) {
            $blocks += "### Handoff from upstream ticket #$dep`n`n$((Get-Content -LiteralPath $f -Raw).TrimEnd())`n"
        }
    }
    if ($blocks.Count -eq 0) { return '' }
    return "## Upstream handoffs`n`n$($blocks -join "`n")"
}

# ============================================================
# Close-out (T6)
# ============================================================
<#
.SYNOPSIS
  Find an existing OPEN PR whose head branch matches $Branch. Used by the
  revision loop (Phase 1): a child ticket reuses the ROOT's already-open PR
  instead of opening a new one. Returns the PR object or $null.
#>
function Get-OpenPrForBranch {
    [CmdletBinding()]
    param([string]$Branch, [string]$Repo = '')
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    try {
        $json = Invoke-Gh @('pr', 'list', '--repo', $Repo, '--head', $Branch,
            '--state', 'open', '--json', 'number,url,title') | ConvertFrom-Json
        $items = @($json)
        if ($items.Count -eq 0) { return $null }
        return $items[0]
    } catch {
        Write-Log "Cannot list PRs for head ${Branch}: $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}

<#
.SYNOPSIS
  Append a comment to an existing PR (revision note on the reused root PR).
#>
function Add-PrComment {
    [CmdletBinding()]
    param([string]$PrNumber, [string]$Body, [string]$Repo = '')
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    $bodyFile = Join-Path $script:DataDir "pr-comment-$PrNumber.md"
    [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Gh @('pr', 'comment', "$PrNumber", '--repo', $Repo, '--body-file', $bodyFile) | Out-Null
    Remove-Item -LiteralPath $bodyFile -Force
}

function Close-OutIssue {
    [CmdletBinding()]
    param([object]$State, [object]$Issue, [string]$Workspace)

    $branch = $State.branch
    $issueRef = $State.issue_ref
    $repo = $State.repo ?? $Config['repo']
    # A child (revision) ticket reuses the ROOT's branch and PR — never a new PR.
    $isChild = Test-IsRevisionChild -State $State

    # Push branch (force-with-lease for a revision reusing the root branch)
    Push-Location $Workspace
    try {
        if ($isChild) {
            git push --force-with-lease origin "$branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git push --force-with-lease failed for branch $branch" }
        } else {
            git push -u origin "$branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git push failed for branch $branch" }
        }
    } finally { Pop-Location }
    Write-Log "Pushed branch $branch"

    # PR — reuse the root's open PR for a child; create a fresh PR otherwise.
    $prUrl = $null
    $prNum = $null
    if ($isChild) {
        $existing = Get-OpenPrForBranch -Branch $branch -Repo $repo
        if ($existing) {
            $prUrl = $existing.url
            $prNum = [string]$existing.number
            Write-Log "Revision close-out: reusing open PR #$prNum for branch $branch"
        }
    }
    if (-not $prUrl) {
        $prBody = "Fixes #$($State.issue_number)`n`nAutonomad v1 — developed autonomously. See the report for details."
        $prBodyFile = Join-Path $script:DataDir "pr-body-$issueRef.md"
        [System.IO.File]::WriteAllText($prBodyFile, $prBody, (New-Object System.Text.UTF8Encoding($false)))
        $prOut = Invoke-Gh @('pr', 'create', '--repo', $repo, '--title', "Autonomad: $($Issue.title)",
            '--body-file', $prBodyFile, '--head', $branch, '--base', $Config['base_branch']) | Out-String
        Remove-Item -LiteralPath $prBodyFile -Force
        $prUrl = ($prOut | Select-String -Pattern 'https://github.com/.*/pull/\d+' | Select-Object -First 1).Matches.Value
        if (-not $prUrl) { $prUrl = $prOut.Trim() }
        $m = [regex]::Match($prUrl, 'pull/(\d+)')
        if ($m.Success) { $prNum = $m.Groups[1].Value }
        Write-Log "PR created: $prUrl"
    }
    # Revision note on the reused root PR (the root's `Fixes #N` body stays intact).
    if ($isChild -and $prNum) {
        try {
            Add-PrComment -PrNumber $prNum -Body "Autonomad revision for #$($State.issue_number) — re-requesting review. See child ticket #$($State.issue_number) for the requested changes." -Repo $repo
            Write-Log "Revision note appended to PR #$prNum"
        } catch {
            Write-Log "Revision PR comment failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    # Label pending-review
    Set-IssueLabel -IssueNumber $State.issue_number -Repo $repo -Add @('pending-review') -Remove @('in-progress')

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

    # Phase 4 — finalizer close-out: close remaining checklist items + notify comment.
    Sync-IssueChecklist -IssueNumber $State.issue_number -State $State
    Add-GateComment -IssueNumber $State.issue_number -Gate 'github_sync' -Status 'pass' `
        -Fields @{ 'pr_url' = $prUrl; 'report' = "reports/$issueRef.html"; 'branch' = $branch } `
        -Summary "Autonomad v1.5 finished #$($State.issue_number). PR opened; checklist completed; pending human review." `
        -Repo $repo

    return $State
}

# ============================================================
# Halt (T7)
# ============================================================
function Halt-Issue {
    [CmdletBinding()]
    param([object]$State, [object]$Issue, [string]$Reason)
    Write-Log "HALT #$($State.issue_number): $Reason" -Level 'WARN'
    $repo = $State.repo ?? $Config['repo']
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
        Set-IssueLabel -IssueNumber $State.issue_number -Repo $repo -Add @('needs-human') -Remove @('in-progress', 'autonomous')
        # Structured gate comment (display-sync pattern) replaces the ad-hoc line.
        Add-GateComment -IssueNumber $State.issue_number -Gate ($State.current_step ?? 'halt') `
            -Status 'blocked' -Summary "Autonomad halted and needs a human. Reason: $Reason" -Repo $repo
        Sync-IssueChecklist -IssueNumber $State.issue_number -State $State
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
            # Fails closed: an unreadable state is a plan-level failure -> halt.
            # A state file WITHOUT schema_version is a FOREIGN artifact (e.g. an AIOS
            # orchestrator pipeline written into this DataDir) — not an Autonomad
            # claim, so skip it silently instead of warning on every poll.
            try {
                $raw = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop
                if ($raw -notmatch '"schema_version"\s*:') {
                    Write-Log "Resume scan: $($dir.Name) is not an Autonomad workspace (foreign pipeline-state) — skipping" -Level 'DEBUG'
                    continue
                }
            } catch { }
            Write-Log "Resume scan: unreadable pipeline-state in $($dir.Name): $($_.Exception.Message)" -Level 'WARN'
            continue
        }
        if ($state.status -eq 'needs-human') {
            Write-Log "Skipping $($dir.Name): needs-human" -Level 'DEBUG'
            continue
        }
        if ($state.status -in @('claimed', 'in_progress')) {
            # Confirm the issue is still open + still HELD by the bot (assigned AND
            # in-progress label present) BEFORE any TTL handling. A human may have
            # released the claim (removing in-progress / adding ready-for-agent)
            # even while the bot is still assigned — resuming or even touching the
            # workspace for a released claim would override that decision. Released
            # claims are reconciled locally by the self-heal pass instead.
            try {
                # Workspaces record their own target repo (a run may have overridden
                # repo.config, e.g. a HRSystem-Legacy targeted run). Fall back to config.
                $repo = [string]$state.repo
                if ([string]::IsNullOrWhiteSpace($repo)) { $repo = $Config['repo'] }
                $view = Invoke-Gh @('issue', 'view', "$($state.issue_number)", '--repo', $repo,
                    '--json', 'state,assignees,labels') | ConvertFrom-Json
                if ($view.state -ne 'OPEN') { Write-Log "Skipping $($dir.Name): issue not open"; continue }
                $labelNames = Get-IssueLabelNames -Issue $view
                if (-not (Test-IssueClaimedByBot -Issue $view)) { Write-Log "Skipping $($dir.Name): not assigned to bot"; continue }
                if ($labelNames -notcontains 'in-progress') { Write-Log "Skipping $($dir.Name): claim released (in-progress label removed)"; continue }
            } catch {
                Write-Log "Skipping $($dir.Name): cannot verify issue state: $($_.Exception.Message)" -Level 'WARN'
                continue
            }
            # TTL-stale handling comes AFTER the held-check, so only claims still
            # owned by the bot reach this point. Silently skipping a stale claim
            # would strand it (assignee + in-progress label forever) — so reset
            # and resume it THIS poll. attempts/max_retries still escalate to a
            # real halt inside Process-Issue when the work cannot complete.
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
                if (ConvertTo-Bool $Config['reconcile_stale']) {
                    Write-Log "TTL-stale $($dir.Name) ($([math]::Round($age))s > ${ttlSeconds}s) — resetting staleness for immediate resume (reconcile_stale on)" -Level 'WARN'
                    $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                    Write-PipelineState -Path $statePath -State $state | Out-Null
                } else {
                    Write-Log "TTL-stale $($dir.Name) ($([math]::Round($age))s > ${ttlSeconds}s) — halting with needs-human" -Level 'WARN'
                    try {
                        Halt-Issue -State $state -Reason "TTL-stale: in-progress for $([math]::Round($age))s (ttl=${ttlSeconds}s); Autonomad halted the stranded claim"
                    } catch {
                        Write-Log "TTL-stale halt failed for $($dir.Name): $($_.Exception.Message)" -Level 'ERROR'
                    }
                    continue
                }
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

    # --- revision parent/root resolution (Phase 0/1) ---
    # A child ticket (`Parent: #N` in the body) reuses the ROOT's branch and
    # open PR — never a new branch/PR per revision.
    $parentRef = Get-ParentRef -Body $Issue.body
    $rootRef = $null
    if ($null -ne $parentRef) {
        $resolveRepo = $Config['repo']
        if ($Resume -and $Resume.State.repo) { $resolveRepo = $Resume.State.repo }
        $rootRef = Resolve-RootRef -Issue $Issue -Repo $resolveRepo
        if ($null -ne $rootRef) {
            $branch = "$($Config['branch_prefix'])/issue-$rootRef"
            Write-Log "#$issueNum is a revision child of #$parentRef (root #$rootRef) — reusing branch $branch"
        }
    }

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
            -MaxRetries ([int]$Config['max_retries']) -IssueSnapshot (New-IssueSnapshot -Issue $Issue) `
            -ParentRef $parentRef -RootRef $rootRef
        $state.status = 'in_progress'
        $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Commit-PipelineState -Workspace $workspace -State $state -Message "gate 0: claim #$issueNum (branch_guard)"
        Write-Log "Gate 0 complete: branch_guard"
        # Phase 2 — canonical tracking comment (tracking_ref #N / root_ref / branch / PR URL).
        Add-TrackingComment -IssueNumber $issueNum -TrackingRef $issueNum -RootRef ($rootRef ?? $issueNum) -Branch $branch
    }

    $prompt = Build-DevPrompt -State $state -Issue $Issue -BrainPath $script:BrainRoot

    # --- run sandbox (dev agent) ---
    $result = Invoke-Sandbox -Config $Config -State $state -Workspace $workspace -Prompt $prompt `
        -DataDir $script:DataDir -EnvFile $EnvFile -BrainRoot $script:BrainRoot

    # --- watchdog kill: count as a failed attempt (retry or hard stop) ---
    if ($result.PSObject.Properties.Name -contains 'killed' -and $result.killed) {
        $state.attempts = [int]$state.attempts + 1
        $state.last_error = "sandbox watchdog killed run: $($result.kill_reason)"
        $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        $statePath = Join-Path $workspace 'pipeline-state.json'
        Write-PipelineState -Path $statePath -State $state | Out-Null
        Commit-PipelineState -Workspace $workspace -State $state -Message "attempt $($state.attempts) watchdog-killed"
        Write-Log "Watchdog killed sandbox for #$issueNum (attempt $($state.attempts)/$($Config['max_retries'])): $($result.kill_reason)"
        if ($state.attempts -ge [int]$Config['max_retries']) {
            Halt-Issue -State $state -Issue $Issue -Reason "N=$($Config['max_retries']) attempts (incl. watchdog kills): $($result.kill_reason)"
        } else {
            Write-Log "Retrying #$issueNum (attempt $($state.attempts))"
        }
        return
    }

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

    # --- live display sync (Phase 3): mirror dev-agent gate progress on the issue ---
    Sync-IssueChecklist -IssueNumber $issueNum -State $newState

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
        # Handoff (chained-ticket continuity): persist the agent's note for the
        # next ticket in the sequence before learning harvest.
        Save-Handoff -AgentResult $agentResult -State $newState
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
    $now = (Get-Date).ToUniversalTime()
    [System.IO.File]::WriteAllText($script:HeartbeatFile, $now.ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    # Structured tick-state heartbeat: the gated reconcile quiet-gate reads this
    # to distinguish an IDLE poll loop (quiet — reconcile may run) from ACTIVE
    # claim processing (not quiet — reconcile must wait).
    $state = [ordered]@{
        pid           = [int]$PID
        status        = [string]$script:TickStatus
        claim         = $script:TickClaim
        last_poll_utc = $now.ToString('o')
        last_work_utc = $(if ($script:LastWorkUtc) { $script:LastWorkUtc.ToString('o') } else { $null })
        updated_at    = $now.ToString('o')
    }
    [System.IO.File]::WriteAllText($script:TickStateFile, ($state | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
}

<#
.SYNOPSIS
  Parse a repo.config boolean flag (true/false/1/0/yes/no). Returns $true by
  default so an unset key keeps self-healing enabled.
#>
function ConvertTo-Bool {
    param([string]$Value)
    if ($Value -match '^(true|1|yes)$') { return $true }
    if ($Value -match '^(false|0|no)$') { return $false }
    return $true
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

# ============================================================
# Orphan reconciliation (stranded-claim safety)
# ============================================================
<#
.SYNOPSIS
  Release any issue that carries the bot's `in-progress` claim but has NO live
  workspace (e.g. the previous tick was killed mid-run / before workspace init).
  Returns them to the `autonomous` pool so nothing strands forever.
#>
function Release-OrphanedClaims {
    [CmdletBinding()]
    param()
    try {
        # All open issues assigned to the bot.
        $json = Invoke-Gh @('issue', 'list', '--repo', $Config['repo'],
            '--search', "is:open assignee:$($Config['bot_login'])",
            '--json', 'number,title,labels,assignees')
        $issues = @($json | ConvertFrom-Json)
    } catch {
        Write-Log "Orphan scan failed: $($_.Exception.Message)" -Level 'WARN'
        return
    }
    foreach ($iss in $issues) {
        $labelNames = Get-IssueLabelNames -Issue $iss
        # Only care about issues still in the work-in-progress state.
        if ($labelNames -notcontains 'in-progress') { continue }
        $workspace = Join-Path $script:WorkspacesDir "issue-$($iss.number)"
        $statePath = Join-Path $workspace 'pipeline-state.json'
        if (Test-Path -LiteralPath $statePath) {
            # Live workspace -> owned by an active or resumable run. Leave it.
            Write-Log "Orphan scan: #$($iss.number) has a live workspace — skipping" -Level 'DEBUG'
            continue
        }
        Write-Log "RELEASE orphaned claim #$($iss.number) (no workspace — previous run was interrupted)"
        try {
            Invoke-Gh @('issue', 'edit', "$($iss.number)", '--repo', $Config['repo'],
                '--remove-assignee', $Config['bot_login'],
                '--remove-label', 'in-progress',
                '--add-label', 'autonomous') | Out-Null
        } catch {
            Write-Log "Release orphan #$($iss.number) failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

<#
.SYNOPSIS
  Clean up orphaned sandbox containers left by a killed tick (name prefix
  autonomad-sandbox-*). Safe: only removes autonomad's own containers.
#>
function Cleanup-OrphanedSandboxes {
    [CmdletBinding()]
    param()
    try {
        $ids = & docker ps -a --filter "name=autonomad-sandbox-" --format '{{.ID}} {{.Names}}' 2>$null
        if ($LASTEXITCODE -ne 0) { return }
        foreach ($line in @($ids)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $id = ($line -split '\s+')[0]
            Write-Log "Removing orphaned sandbox container $id"
            & docker rm -f $id 2>&1 | Out-Null
        }
    } catch {
        Write-Log "Sandbox cleanup failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

# ============================================================
# Gated claim reconciliation (self-heal, issue #19)
# ============================================================
# Runs ONLY when Autonomad is QUIET (no live tick, no sandbox, nothing touched
# within activity_window) AND an ATTENTION condition exists (stale claim,
# needs-human, delivered-but-open orphan). Own claims only: it never touches a
# claim that is not recorded in a local workspace, never closes issues, and
# never merges PRs. Every action is appended to reconciliation.log (JSONL).
$script:ReconcileLog = Join-Path $script:DataDir 'reconciliation.log'

function Write-ReconcileLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Issue,
        [string]$Reason = '',
        [switch]$DryRun
    )
    $rec = [ordered]@{
        ts       = (Get-Date).ToUniversalTime().ToString('o')
        action   = $Action
        issue    = $Issue
        reason   = $Reason
        dry_run  = [bool]$DryRun
    }
    $line = $rec | ConvertTo-Json -Compress
    Add-Content -LiteralPath $script:ReconcileLog -Value $line -Encoding utf8
    Write-Log "RECONCILE [$Action] issue=$Issue $(if ($DryRun) { '(dry-run)' } else { '' })$Reason" -Level 'INFO'
}

<#
.SYNOPSIS
  True when Autonomad is not actively doing anything: no other tick process,
  no autonomad sandbox container, no workspace touched within activity_window.
#>
function Test-AutonomadQuiet {
    [CmdletBinding()]
    param()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $window = [int]$Config['activity_window']

    # 1) Another tick process running. Exclude THIS process and every ancestor
    #    (a shell that launched us may carry 'tick.ps1' in its own command line).
    #    v2: an IDLE tick (heartbeat says idle and it has not worked a claim
    #    within activity_window) does NOT block reconciliation — a healthy
    #    always-on loop polls forever and would otherwise suppress self-heal
    #    indefinitely. Only ACTIVE work (status=working, or a recent claim
    #    finish, or no heartbeat to prove idle) counts as activity.
    $skip = [System.Collections.Generic.HashSet[int]]::new()
    $null = $skip.Add([int]$PID)
    $cur = $PID
    try {
        for ($i = 0; $i -lt 8; $i++) {
            $me = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
            if ($null -eq $me -or $null -eq $me.ParentProcessId -or [int]$me.ParentProcessId -le 0) { break }
            $cur = [int]$me.ParentProcessId
            if ($skip.Contains($cur)) { break }
            $null = $skip.Add($cur)
        }
    } catch { }

    $tickState = $null
    try {
        if (Test-Path -LiteralPath $script:TickStateFile) {
            $tickState = Get-Content -LiteralPath $script:TickStateFile -Raw | ConvertFrom-Json
        }
    } catch { $tickState = $null }

    $liveTickPids = [System.Collections.Generic.List[int]]::new()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $pidN = [int]$p.ProcessId
            if ($skip.Contains($pidN)) { continue }
            if ($p.CommandLine -and $p.CommandLine -match 'tick\.ps1') {
                $liveTickPids.Add($pidN)
            }
        }
    } catch { }

    $tickBusy = $false
    if ($liveTickPids.Count -gt 0) {
        # Heartbeat present and claims idle? Trust it only if its pid is alive and
        # no claim has been worked within activity_window.
        if ($null -ne $tickState) {
            $hbPidAlive = $false
            try { $hbPidAlive = ($liveTickPids -contains [int]$tickState.pid) } catch { }
            $lastWork = $null
            try { $lastWork = [datetime]::Parse([string]$tickState.last_work_utc) } catch { }
            $workedRecently = ($null -ne $lastWork -and ((Get-Date).ToUniversalTime() - $lastWork).TotalSeconds -le $window)
            if (-not $hbPidAlive -or [string]$tickState.status -eq 'working' -or $workedRecently) {
                $tickBusy = $true
            }
        } else {
            # No heartbeat (older tick) -> fall back to treating the live tick as activity.
            $tickBusy = $true
        }
        if ($tickBusy) {
            $reasons.Add("live tick pid $($liveTickPids[0]) active")
        }
    }

    # 2) Autonomad sandbox containers.
    try {
        $ids = & docker ps --filter "name=autonomad-sandbox-" --format '{{.ID}}' 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($l in @($ids)) {
                if (-not [string]::IsNullOrWhiteSpace($l)) { $reasons.Add("sandbox container $l"); break }
            }
        }
    } catch { }

    # 3) Workspaces touched within activity_window.
    if (Test-Path -LiteralPath $script:WorkspacesDir) {
        $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$window)
        foreach ($d in (Get-ChildItem -LiteralPath $script:WorkspacesDir -Directory -ErrorAction SilentlyContinue)) {
            $sp = Join-Path $d.FullName 'pipeline-state.json'
            if (-not (Test-Path -LiteralPath $sp)) { continue }
            try {
                if ((Get-Item -LiteralPath $sp).LastWriteTimeUtc -gt $cutoff) {
                    $reasons.Add("workspace $($d.Name) touched recently")
                    break
                }
            } catch { }
        }
    }

    return [pscustomobject]@{ quiet = ($reasons.Count -eq 0); reasons = @($reasons) }
}

<#
.SYNOPSIS
  True when any local workspace needs attention: needs-human, or a
  claimed/in-progress workspace older than ttl. Delivered-but-open orphans are
  additionally detected per-claim inside Invoke-ReconcileClaims (needs GH).
#>
function Test-AttentionNeeded {
    [CmdletBinding()]
    param()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $ttlSeconds = [int]$Config['ttl']
    if (-not (Test-Path -LiteralPath $script:WorkspacesDir)) {
        return [pscustomobject]@{ attention = $false; reasons = @() }
    }
    foreach ($d in (Get-ChildItem -LiteralPath $script:WorkspacesDir -Directory -ErrorAction SilentlyContinue)) {
        $sp = Join-Path $d.FullName 'pipeline-state.json'
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        try {
            $state = Read-PipelineState -Path $sp -SchemaPath $script:SchemaPath
        } catch { continue }
        if ($state.status -eq 'needs-human') {
            $reasons.Add("$($d.Name): needs-human")
            continue
        }
        if ($state.status -in @('claimed', 'in_progress')) {
            try {
                $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.updated_at)).TotalSeconds
            } catch { continue }
            if ($age -gt $ttlSeconds) {
                $reasons.Add("$($d.Name): stale $([math]::Round($age))s")
            }
        }
    }
    return [pscustomobject]@{ attention = ($reasons.Count -gt 0); reasons = @($reasons) }
}

<#
.SYNOPSIS
  Fetch the PR (any state) for a head branch, so reconciliation can detect a
  merged PR even after it is closed. Returns the PR object or $null.
#>
function Get-PrRecord {
    [CmdletBinding()]
    param([string]$Branch, [string]$Repo = '')
    if ([string]::IsNullOrWhiteSpace($Branch)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Repo)) { $Repo = $Config['repo'] }
    try {
        $json = Invoke-Gh @('pr', 'list', '--repo', $Repo, '--head', $Branch,
            '--state', 'all', '--json', 'number,url,state,mergedAt')
        $items = @($json | ConvertFrom-Json)
        if ($items.Count -eq 0) { return $null }
        return $items[0]
    } catch {
        Write-Log "Reconcile: cannot list PRs for ${Branch}: $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}

<#
.SYNOPSIS
  The reconciliation pass. Iterates local workspaces, compares each against
  GitHub truth, and repairs only claims Autonomad itself owns. -DryRun logs
  the intended actions without mutating anything (state files or GitHub).
#>
function Invoke-ReconcileClaims {
    [CmdletBinding()]
    param([switch]$DryRun)

    $actions = [System.Collections.Generic.List[object]]::new()
    if (-not (ConvertTo-Bool $Config['reconcile_stale'])) {
        Write-Log 'Reconcile: reconcile_stale=false — pass skipped' -Level 'INFO'
        return ,@($actions)
    }
    if (-not (Test-Path -LiteralPath $script:WorkspacesDir)) {
        Write-Log 'Reconcile: no workspaces dir — nothing to reconcile' -Level 'INFO'
        return ,@($actions)
    }

    foreach ($d in (Get-ChildItem -LiteralPath $script:WorkspacesDir -Directory | Sort-Object Name)) {
        $sp = Join-Path $d.FullName 'pipeline-state.json'
        if (-not (Test-Path -LiteralPath $sp)) { continue }
        try {
            $state = Read-PipelineState -Path $sp -SchemaPath $script:SchemaPath
        } catch {
            # A state file WITHOUT schema_version is a FOREIGN artifact (e.g. an AIOS
            # orchestrator pipeline) — not an Autonomad claim; skip silently instead
            # of warning on every reconciliation pass.
            try {
                $raw = Get-Content -LiteralPath $sp -Raw -ErrorAction Stop
                if ($raw -notmatch '"schema_version"\s*:') {
                    Write-Log "Reconcile: $($d.Name) is not an Autonomad workspace (foreign pipeline-state) — skipping" -Level 'DEBUG'
                    continue
                }
            } catch { }
            Write-ReconcileLog -Action 'warn' -Issue $d.Name -Reason "unreadable state: $($_.Exception.Message)" -DryRun:$DryRun
            continue
        }
        # Older state files predate the reconcile_note schema property; ensure the
        # property exists before any reconciliation writes to it (StrictMode-safe).
        if ($null -eq $state.PSObject.Properties['reconcile_note']) {
            $state | Add-Member -NotePropertyName 'reconcile_note' -NotePropertyValue '' -Force
        }
        try { $issueNum = [int]$state.issue_number } catch { continue }
        if ($issueNum -le 0) { continue }
        $branch = [string]$state.branch
        # Workspaces record their own target repo (a run may have overridden
        # repo.config, e.g. a HRSystem-Legacy targeted run). Fall back to config.
        $repo = [string]$state.repo
        if ([string]::IsNullOrWhiteSpace($repo)) { $repo = $Config['repo'] }

        # GitHub truth for this claim.
        try {
            $view = Invoke-Gh @('issue', 'view', "$issueNum", '--repo', $repo,
                '--json', 'state,assignees,labels') | ConvertFrom-Json
        } catch {
            Write-ReconcileLog -Action 'warn' -Issue $d.Name -Reason "gh view failed: $($_.Exception.Message)" -DryRun:$DryRun
            continue
        }
        $labelNames = Get-IssueLabelNames -Issue $view
        $assignedToBot = Test-IssueClaimedByBot -Issue $view
        $held = $assignedToBot -and ($labelNames -contains 'in-progress')
        $pr = Get-PrRecord -Branch $branch -Repo $repo
        $prMerged = ($null -ne $pr -and -not [string]::IsNullOrWhiteSpace([string]$pr.mergedAt))

        # 1) needs-human: leave for the human while the ticket is open; auto-resolve
        #    when the ticket is closed (the halt reason is moot).
        if ($state.status -eq 'needs-human' -or $labelNames -contains 'needs-human') {
            if ($view.state -ne 'OPEN') {
                $actions.Add([pscustomobject]@{ action = 'resolve-halt'; issue = $issueNum; workspace = $d.Name; reason = "ticket closed while needs-human (merged=$prMerged)" })
                Write-ReconcileLog -Action 'resolve-halt' -Issue $d.Name -Reason "ticket closed while needs-human (merged=$prMerged)" -DryRun:$DryRun
                if (-not $DryRun) {
                    $state.status = 'resolved'
                    $state.reconcile_note = 'needs-human ticket closed; auto-resolved'
                    $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                    Write-PipelineState -Path $sp -State $state | Out-Null
                    try { Set-IssueLabel -IssueNumber $issueNum -Repo $repo -Remove @('needs-human', 'in-progress') } catch {
                        Write-Log "Reconcile: resolve-halt label cleanup failed for #$issueNum : $($_.Exception.Message)" -Level 'WARN'
                    }
                }
            } else {
                Write-Log "Reconcile: $($d.Name) needs-human (open) — leaving for human" -Level 'DEBUG'
            }
            continue
        }

        # 2) Issue closed -> close-out (record outcome; hygiene labels only).
        if ($view.state -ne 'OPEN') {
            $actions.Add([pscustomobject]@{ action = 'close-out'; issue = $issueNum; workspace = $d.Name; reason = "issue closed (merged=$prMerged)" })
            Write-ReconcileLog -Action 'close-out' -Issue $d.Name -Reason "issue closed (merged=$prMerged)" -DryRun:$DryRun
            if (-not $DryRun) {
                $state.status = 'closed-out'
                $state.reconcile_note = "issue closed; merged=$prMerged"
                $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                Write-PipelineState -Path $sp -State $state | Out-Null
                try { Set-IssueLabel -IssueNumber $issueNum -Repo $repo -Remove @('in-progress', 'needs-human', 'autonomous', 'ready-for-agent') } catch {
                    Write-Log "Reconcile: close-out label cleanup failed for #$issueNum : $($_.Exception.Message)" -Level 'WARN'
                }
            }
            continue
        }

        # 3) Bot no longer holds the claim (unassigned or in-progress removed by a
        #    human) -> release the local claim so a fresh poll can re-claim it.
        if (-not $held) {
            $actions.Add([pscustomobject]@{ action = 'release'; issue = $issueNum; workspace = $d.Name; reason = 'bot no longer holds the claim' })
            Write-ReconcileLog -Action 'release' -Issue $d.Name -Reason "bot no longer holds (assigned=$assignedToBot, in-progress=$($labelNames -contains 'in-progress'))" -DryRun:$DryRun
            if (-not $DryRun) {
                $state.status = 'released'
                $state.reconcile_note = 'claim released by reconciliation (bot no longer holds)'
                $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                Write-PipelineState -Path $sp -State $state | Out-Null
                try {
                    Invoke-Gh @('issue', 'edit', "$issueNum", '--repo', $repo,
                        '--remove-assignee', $Config['bot_login'],
                        '--remove-label', 'in-progress') | Out-Null
                } catch {
                    Write-ReconcileLog -Action 'warn' -Issue $d.Name -Reason "release GH cleanup failed: $($_.Exception.Message)" -DryRun:$DryRun
                }
            }
            continue
        }

        # 4) PR OPEN -> delivered but the workspace still says in_progress; sync it.
        #    A MERGED PR must not trigger this (a revision child reuses the root's
        #    branch, whose PR may already be merged — that is not 'delivered').
        if ($null -ne $pr -and -not $prMerged) {
            $actions.Add([pscustomobject]@{ action = 'mark-pending-review'; issue = $issueNum; workspace = $d.Name; reason = "PR #$($pr.number) open" })
            Write-ReconcileLog -Action 'mark-pending-review' -Issue $d.Name -Reason "PR #$($pr.number) open" -DryRun:$DryRun
            if (-not $DryRun) {
                $state.status = 'pending-review'
                $state.pr_url = [string]$pr.url
                $state.reconcile_note = 'PR open; synced pending-review'
                $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                Write-PipelineState -Path $sp -State $state | Out-Null
                try { Set-IssueLabel -IssueNumber $issueNum -Repo $repo -Add @('pending-review') -Remove @('in-progress') } catch {
                    Write-Log "Reconcile: pending-review sync failed for #$issueNum : $($_.Exception.Message)" -Level 'WARN'
                }
            }
            continue
        }

        # 5) Stale but owned with no PR -> reset staleness so the next poll resumes.
        $age = $null
        try { $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.updated_at)).TotalSeconds } catch { }
        if ($null -ne $age -and $age -gt [int]$Config['ttl']) {
            $actions.Add([pscustomobject]@{ action = 'resume'; issue = $issueNum; workspace = $d.Name; reason = "stale $([math]::Round($age))s but owned; staleness reset" })
            Write-ReconcileLog -Action 'resume' -Issue $d.Name -Reason "stale $([math]::Round($age))s but owned; staleness reset" -DryRun:$DryRun
            if (-not $DryRun) {
                $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
                $state.reconcile_note = 'staleness reset by reconciliation'
                Write-PipelineState -Path $sp -State $state | Out-Null
            }
            continue
        }

        # 6) Healthy fresh claim -> no action.
        Write-Log "Reconcile: $($d.Name) healthy — no action" -Level 'DEBUG'
    }
    return ,@($actions)
}

# ============================================================
# Graceful shutdown (release claims on Ctrl+C / SIGTERM)
# ============================================================
$script:ShutdownRequested = $false
# PowerShell-native signal handling: Ctrl+C / SIGTERM set the flag so the loop
# exits cleanly and Release-OrphanedClaims fires before exit.
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action {
    $script:ShutdownRequested = $true
}

# Init: idempotent labels
Ensure-Labels
# Wire git auth (m12): GIT_ASKPASS supplies the bot token at prompt time instead
# of embedding it in the clone URL (keeps it out of <workspace>/.git/config).
$script:AskPassPath = Write-GitAskPass
Write-Heartbeat

# Startup reconciliation: reclaim anything the previous (possibly killed) run left.
Release-OrphanedClaims
Cleanup-OrphanedSandboxes

# ---- gated reconciliation (self-heal) mode: one pass, then exit ----
# The supervisor schedules this with `-ReconcileOnce`. The pass only runs when
# Autonomad is QUIET (no live tick/sandbox/recent activity) AND an ATTENTION
# condition exists. Otherwise it exits without touching anything.
if ($ReconcileOnce) {
    Write-Log "ReconcileOnce mode — gated claim reconciliation"
    $quiet = Test-AutonomadQuiet
    if (-not $quiet.quiet) {
        Write-Log "Reconcile skipped: Autonomad activity present ($($quiet.reasons -join '; '))"
        exit 0
    }
    $attention = Test-AttentionNeeded
    if (-not $attention.attention) {
        Write-Log "Reconcile skipped: no attention conditions (all claims healthy)"
        exit 0
    }
    Write-Log "Reconcile gate PASSED (quiet + attention: $($attention.reasons -join '; '))"
    $actions = Invoke-ReconcileClaims -DryRun:$ReconcileDryRun
    Write-Log "Reconcile done: $($actions.Count) action(s)"
    exit 0
}

$tickCount = 0
$lastWorkAt = (Get-Date).ToUniversalTime()

while ($true) {
    $tickCount++
    Write-Heartbeat

    if ($script:ShutdownRequested) {
        Write-Log "Shutdown requested — releasing claims and exiting."
        Release-OrphanedClaims
        Cleanup-OrphanedSandboxes
        exit 0
    }

    if ($MaxTicks -gt 0 -and $tickCount -gt $MaxTicks) {
        Write-Log "MaxTicks ($MaxTicks) reached — exiting."
        exit 0
    }

    # 1) Resume any in-progress issue owned by the bot first (crash recovery, Q16).
    $resumable = Find-ResumableIssue
    if ($resumable) {
        try {
            $resumeRepo = $resumable.State.repo ?? $Config['repo']
            $issueView = Invoke-Gh @('issue', 'view', "$($resumable.State.issue_number)", '--repo', $resumeRepo,
                '--json', 'number,title,url,body,labels,assignees') | ConvertFrom-Json
            $script:TickStatus = 'working'
            $script:TickClaim = $resumable.State.issue_ref
            $script:LastWorkUtc = (Get-Date).ToUniversalTime()
            Write-Heartbeat
            Process-Issue -Issue $issueView -Resume $resumable
        } catch {
            Write-Log "Resume processing failed: $($_.Exception.Message)" -Level 'ERROR'
        }
        $script:TickStatus = 'idle'
        $script:TickClaim = $null
        $script:LastWorkUtc = (Get-Date).ToUniversalTime()
        Write-Heartbeat
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
        $script:TickStatus = 'working'
        $script:TickClaim = "issue-$($candidate.number)"
        $script:LastWorkUtc = (Get-Date).ToUniversalTime()
        Write-Heartbeat
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
        $script:TickStatus = 'idle'
        $script:TickClaim = $null
        $script:LastWorkUtc = (Get-Date).ToUniversalTime()
        Write-Heartbeat
    } else {
        Write-Log "Could not claim #$($candidate.number) (race or labels changed)."
    }

    if ($Once) { exit 0 }
}
