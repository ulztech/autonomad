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
    [string]$Repo = '',          # runtime override for repo.config repo (owner/name)
    [string]$BaseBranch = '',    # runtime override for repo.config base_branch
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
Import-EnvFile -EnvFilePath $EnvFile | Out-Null

# --- runtime repo/base_branch overrides (win over repo.config) ---
if ($Repo) {
    if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "repo must be owner/name (got '$Repo')"
    }
    $Config['repo'] = $Repo
}
if ($BaseBranch) {
    $Config['base_branch'] = $BaseBranch
}
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
    param([int]$IssueNumber, [string[]]$Add = @(), [string[]]$Remove = @())
    if ($Add.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Config['repo'], '--add-label', ($Add -join ',')) | Out-Null
    }
    if ($Remove.Count -gt 0) {
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Config['repo'], '--remove-label', ($Remove -join ',')) | Out-Null
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
    param([int]$IssueNumber, [string]$Body)
    $bodyFile = Join-Path $script:DataDir "comment-$IssueNumber.md"
    [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Gh @('issue', 'comment', "$IssueNumber", '--repo', $Config['repo'], '--body-file', $bodyFile) | Out-Null
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
    try {
        $view = Invoke-Gh @('issue', 'view', "$IssueNumber", '--repo', $Config['repo'],
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
        Invoke-Gh @('issue', 'edit', "$IssueNumber", '--repo', $Config['repo'], '--body-file', $bodyFile) | Out-Null
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
        [string]$Summary = ''
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
    Add-IssueComment -IssueNumber $IssueNumber -Body ($lines -join "`n")
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
        [string]$PrUrl = ''
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
        Add-IssueComment -IssueNumber $IssueNumber -Body ($lines -join "`n")
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
    # Match the dependency marker (`Depends on #N` / `Blocked by #N`), capturing the
    # first issue number — inline (`Blocked by #316`) or the first bullet under a
    # "## Blocked by" heading (`- #316 — title`).
    $marker = [regex]::Match($Body, '(?i)(?:depends\s+on|blocked\s+by)\s*:?\s*-\s*#(\d+)')
    if (-not $marker.Success) {
        $marker = [regex]::Match($Body, '(?i)(?:depends\s+on|blocked\s+by)\s*:?\s*#(\d+)')
    }
    if ($marker.Success) {
        $refs += [int]$marker.Groups[1].Value
        # Capture additional bullets on subsequent lines of a list:
        #   - #5 — first dep
        #   - #6 — second dep
        $rest = $Body.Substring($marker.Index + $marker.Length)
        foreach ($m in [regex]::Matches($rest, '(?m)^\s*-\s*#(\d+)')) {
            $refs += [int]$m.Groups[1].Value
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
    # Parent may be written as `Parent: #N` or as a URL under a "## Parent" heading:
    #   ## Parent
    #   https://github.com/ulztech/HRSystem-Legacy/issues/313
    #   - https://github.com/ulztech/HRSystem-Legacy/issues/313
    # Match the number from either form (a URL's trailing /issues/<N> is captured).
    foreach ($m in [regex]::Matches($Body, '(?i)parent\s*[:：]?\s*(?:-\s*)?(?:https?://[^\s]+/issues/|#)(\d+)')) {
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
        [hashtable]$Seen = @{}
    )
    if ($null -eq $Issue) { return $null }
    $parent = Get-ParentRef -Body $Issue.body
    if ($null -eq $parent) { return [int]$Issue.number }
    if ($Seen.ContainsKey($Issue.number.ToString())) { return [int]$Issue.number }
    $Seen[$Issue.number.ToString()] = $true
    try {
        $view = Invoke-Gh @('issue', 'view', "$parent", '--repo', $Config['repo'],
            '--json', 'number,body') | ConvertFrom-Json
        return Resolve-RootRef -Issue $view -Seen $Seen
    } catch {
        Write-Log "Cannot resolve root parent for #$($Issue.number): $($_.Exception.Message)" -Level 'WARN'
        return [int]$Issue.number
    }
}

<#
.SYNOPSIS
  Resolve the CHAIN root of a sequential ticket chain (e.g. #316 blocked by
  nothing -> #317 blocked by #316 -> ...). Walks `Blocked by` / `Depends on`
  links up to the head of the chain — the ticket that has NO dependencies. The
  chain root owns the shared branch + PR that every child reuses. Cycle-safe.
  Falls back to the current number when a dependency cannot be fetched.
#>
function Resolve-ChainRootRef {
    [CmdletBinding()]
    param(
        [object]$Issue,
        [hashtable]$Seen = @{}
    )
    if ($null -eq $Issue) { return $null }
    $deps = Get-DependencyRefs -Body $Issue.body
    if ($deps.Count -eq 0) { return [int]$Issue.number }
    if ($Seen.ContainsKey($Issue.number.ToString())) { return [int]$Issue.number }
    $Seen[$Issue.number.ToString()] = $true
    $dep = ($deps | Sort-Object)[0]
    try {
        $view = Invoke-Gh @('issue', 'view', "$dep", '--repo', $Config['repo'],
            '--json', 'number,body') | ConvertFrom-Json
        return Resolve-ChainRootRef -Issue $view -Seen $Seen
    } catch {
        Write-Log "Cannot resolve chain root for #$($Issue.number): $($_.Exception.Message)" -Level 'WARN'
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
            # A dependency that is DONE but awaiting human review (pending-review)
            # no longer blocks: its work is complete and downstream tickets can
            # proceed on the shared chain branch. Only actively-open deps block.
            # A needs-human dep is NOT complete — it still blocks.
            $depLabels = @()
            try {
                $depView = Invoke-Gh @('issue', 'view', "$dep", '--repo', $Config['repo'],
                    '--json', 'labels') | ConvertFrom-Json
                $depLabels = Get-IssueLabelNames -Issue $depView
            } catch { }
            if ($depLabels -contains 'pending-review') {
                Write-Log "#$($Issue.number): dep #$dep is pending-review — not blocking" -Level 'DEBUG'
                continue
            }
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
  Find open issues that declare #IssueNumber as a dependency ("Blocked by #N" /
  "Depends on #N") and remove their `blocked` label. Called when an issue moves
  to pending-review so its chain children are unblocked for the next tick.
#>
function Unblock-Dependents {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$IssueNumber)
    try {
        $search = 'is:open label:"blocked"'
        $json = Invoke-Gh @('issue', 'list', '--repo', $Config['repo'],
            '--search', $search,
            '--json', 'number,body,labels') | ConvertFrom-Json
        foreach ($item in @($json)) {
            $deps = Get-DependencyRefs -Body $item.body
            if ($deps -contains $IssueNumber) {
                Set-IssueLabel -IssueNumber $item.number -Remove @('blocked')
                Write-Log "Unblocked #$($item.number) (dependency #$IssueNumber is now pending-review)"
            }
        }
    } catch {
        Write-Log "Unblock-Dependents failed for #$IssueNumber : $($_.Exception.Message)" -Level 'WARN'
    }
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
    # Single-flight guard (Q3): never claim a new ticket while ANY other OPEN
    # issue carries the bot's `in-progress` claim. This is the "one in-progress at
    # a time" invariant — protects against stale-label races and the chain being
    # jumped ahead of while a sibling is still mid-flight.
    $inProgress = @()
    try {
        $inProgress = @((Invoke-Gh @('issue', 'list', '--repo', $Config['repo'],
            '--search', 'is:open label:"in-progress"',
            '--json', 'number,labels,assignees') | ConvertFrom-Json))
    } catch {
        Write-Log "Single-flight probe failed (proceeding): $($_.Exception.Message)" -Level 'DEBUG'
    }
    foreach ($ip in $inProgress) {
        if ($null -eq $ip -or $null -eq $ip.number) { continue }
        if ($ip.number -ne $items[0].number -and (Test-IssueClaimedByBot -Issue $ip)) {
            Write-Log "Single-flight: #$($ip.number) still in-progress — holding new claims" -Level 'DEBUG'
            return $null
        }
    }
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
        --remove-label 'ready-for-agent' `
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
        Add-AutonomadGitignore -Workspace $Workspace
        return
    }
    if (-not (Test-Path -LiteralPath $Workspace)) { New-Item -ItemType Directory -Path $Workspace -Force | Out-Null }
    Write-Log "Cloning $($Config['repo']) into $Workspace"
    Push-Location (Split-Path -Parent $Workspace)
    try {
        git clone --no-checkout (Get-RepoCloneUrl) $Workspace 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Workspace" }
    } finally { Pop-Location }
    Add-AutonomadGitignore -Workspace $Workspace
}

<#
.SYNOPSIS
  Append Autonomad-internal paths to the workspace .gitignore so the dev agent's
  commits and the repo PR never ship pipeline-state.json / .autonomad/ artifacts.
  These are Autonomad runtime state, not product code.
#>
function Add-AutonomadGitignore {
    [CmdletBinding()]
    param([string]$Workspace)
    # Use .git/info/exclude (repo-local, never committed, survives branch switches)
    # rather than a working-tree .gitignore — an untracked .gitignore would block
    # git checkout when switching to a remote branch that already has one.
    $gitDir = Join-Path $Workspace '.git'
    $excludeFile = Join-Path $gitDir 'info' 'exclude'
    if (-not (Test-Path -LiteralPath (Join-Path $gitDir 'info'))) {
        New-Item -ItemType Directory -Path (Join-Path $gitDir 'info') -Force | Out-Null
    }
    $lines = @(
        '',
        '# --- Autonomad runtime artifacts (never shipped in PRs) ---',
        '.autonomad/',
        'pipeline-state.json'
    )
    $existing = if (Test-Path -LiteralPath $excludeFile) { Get-Content -LiteralPath $excludeFile -Raw } else { '' }
    foreach ($l in $lines) {
        if ($existing -match [regex]::Escape($l.Trim())) { continue }
        Add-Content -LiteralPath $excludeFile -Value $l
    }
}

function Checkout-IssueBranch {
    [CmdletBinding()]
    param([string]$Workspace, [string]$Branch)
    Push-Location $Workspace
    try {
        $branches = git branch -a 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'git branch -a failed' }
        $branchExistsLocal = ($branches | Select-String -SimpleMatch "  $Branch") -ne $null -or
                             ($branches | Select-String -SimpleMatch "* $Branch") -ne $null
        $branchExistsRemote = ($branches | Select-String -SimpleMatch "origin/$Branch") -ne $null
        if ($branchExistsLocal) {
            git checkout "$Branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        } elseif ($branchExistsRemote) {
            # Remote branch exists (e.g. a chain root's shared branch, or a resumed
            # run's pushed branch). Create the local tracking branch from it so the
            # dev agent works on the exact same branch the PR points at.
            git checkout -b "$Branch" "origin/$Branch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git checkout -b $Branch origin/$Branch failed" }
            Add-AutonomadGitignore -Workspace $Workspace
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

    # Prior-context injection: pull previously-captured learnings for this repo so
    # the run starts warm instead of re-reading files. Filtered by repo so each
    # target repo only sees its own knowledge.
    $priorLearnings = @()
    try {
        $repoFilter = $State.repo
        # Keep only the knowledge bullets (learn.ps1 emits an info-stream header line too).
        $priorLearnings = @(& (Join-Path $PSScriptRoot 'learn.ps1') -DataDir $script:DataDir -Mode query -Source $repoFilter 2>$null |
            Where-Object { $_ -match '^-\s+\[' })
    } catch {
        Write-Log "Learnings query failed (continuing cold): $($_.Exception.Message)" -Level 'WARN'
    }
    $priorText = if ($priorLearnings.Count -gt 0) {
        "Prior repo context (from the learning store — verified by earlier runs; trust it and skip re-reading those files):`n" + (($priorLearnings | ForEach-Object { $_.Trim() }) -join "`n")
    } else {
        'No prior learnings for this repo yet.'
    }

    return @"
# Autonomad dev task — $(if ($Issue) { $Issue.title })

You are the Autonomad dev agent for issue **#$($State.issue_number)** in **$($State.repo)**.

## Task
Develop the issue described below. Load the repo-native marketplace skills and consult the
AIOS brain (read-only) where helpful. Follow the pipeline-state gates strictly: complete each
gate in order, run the build and test commands green BEFORE advancing, and commit
pipeline-state.json after every gate.

## Prior context (from learning store)
$priorText

## Shared learning store (LIVE — read + append)
The tick loop mounts the shared learning dir at /learnings (read-write). It contains:
- repo-context-<repo>.md — cumulative prior context for THIS repo; read it during
  research to avoid re-reading files you have already mapped.
- session files (issue-<N>.jsonl) — append one JSON line per finding you want to
  persist: {"knowledge": "...", "source": "<repo>", "confidence": 0.9}
At the END of the session the tick loop ingests your session file into learning.db
(deduped) and future runs start warm. Also list findings in result.json.learnings.
Never put secrets or PII in learnings.

## Issue
Title: $(if ($Issue) { $Issue.title } else { $State.issue_ref })
Body:
$(if ($Issue) { $Issue.body } else { '' })

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
  "learnings": [ { "knowledge": "...", "source": "issue-N", "confidence": 0.9 } ]
}
`learnings` is optional but encouraged: capture repo context facts you discovered
during research (migration/seed homes, naming conventions, charset decisions,
build/test quirks) so future runs start warm instead of re-reading files. Set
`source` to the repo (e.g. ulztech/HRSystem-Legacy) for reusable context — the
tick loop persists them (deduped) and injects prior learnings into the next prompt.
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
  Persist the dev agent's research learnings into the learning store so future
  runs start warm. Sources (both optional):
   1. result.json.learnings (fallback) — agent-reported findings.
   2. <DataDir>/learnings/issue-<N>.jsonl (primary) — live-append session file
      the agent wrote during the run. Each line is one JSON object.
  Called after every dev run, before halt/retry/success handling, so findings are
  captured even on failure.
#>
function Persist-Learnings {
    [CmdletBinding()]
    param([object]$AgentResult, [string]$Workspace, [string]$IssueRef, [string]$IssueNumber)
    $recorded = 0

    # Source 1: live session file (shared learning store mount).
    $learningsDir = Join-Path $script:DataDir 'learnings'
    $sessionFile = Join-Path $learningsDir "issue-$IssueNumber.jsonl"
    if (Test-Path -LiteralPath $sessionFile) {
        foreach ($line in Get-Content -LiteralPath $sessionFile) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $item = $line | ConvertFrom-Json
                $knowledge = [string]$item.knowledge
                if ([string]::IsNullOrWhiteSpace($knowledge)) { continue }
                $conf = 0.9
                if ($null -ne $item.confidence) { $conf = [math]::Round([double]$item.confidence, 2) }
                $source = if ([string]::IsNullOrWhiteSpace([string]$item.source)) { "issue-$IssueNumber" } else { [string]$item.source }
                & (Join-Path $PSScriptRoot 'learn.ps1') -DataDir $script:DataDir -Mode knowledge `
                    -Knowledge $knowledge -Source $source -Confidence $conf 2>&1 | ForEach-Object { Write-Log "[learn] $_" }
                $recorded++
            } catch {
                Write-Log "Skipping malformed learnings line: $($_.Exception.Message)" -Level 'WARN'
            }
        }
        # Ingested once — archive it so it is not re-processed.
        $archiveDir = Join-Path $learningsDir 'archive'
        if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
        Move-Item -LiteralPath $sessionFile -Destination (Join-Path $archiveDir (Split-Path $sessionFile -Leaf)) -Force
    }

    # Source 2: result.json.learnings (fallback).
    if ($AgentResult) {
        $learnings = @($AgentResult.learnings)
        foreach ($item in $learnings) {
            $knowledge = [string]$item.knowledge
            if ([string]::IsNullOrWhiteSpace($knowledge)) { continue }
            $conf = 0.9
            if ($null -ne $item.confidence) { $conf = [math]::Round([double]$item.confidence, 2) }
            $source = if ([string]::IsNullOrWhiteSpace([string]$item.source)) { "issue-$IssueNumber" } else { [string]$item.source }
            & (Join-Path $PSScriptRoot 'learn.ps1') -DataDir $script:DataDir -Mode knowledge `
                -Knowledge $knowledge -Source $source -Confidence $conf 2>&1 | ForEach-Object { Write-Log "[learn] $_" }
            $recorded++
        }
    }

    Write-Log "Persisted $recorded learning(s) from $IssueRef"
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
    param([string]$Branch)
    try {
        $json = Invoke-Gh @('pr', 'list', '--repo', $Config['repo'], '--head', $Branch,
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
    param([string]$PrNumber, [string]$Body)
    $bodyFile = Join-Path $script:DataDir "pr-comment-$PrNumber.md"
    [System.IO.File]::WriteAllText($bodyFile, $Body, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Gh @('pr', 'comment', "$PrNumber", '--repo', $Config['repo'], '--body-file', $bodyFile) | Out-Null
    Remove-Item -LiteralPath $bodyFile -Force
}

function Close-OutIssue {
    [CmdletBinding()]
    param([object]$State, [object]$Issue, [string]$Workspace)

    $branch = $State.branch
    $issueRef = $State.issue_ref
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

    # PR — reuse an existing open PR on this branch (root/child/chain OR a prior
    # close-out that already opened it, e.g. done-state resume), else create fresh.
    $prUrl = $null
    $prNum = $null
    $existing = Get-OpenPrForBranch -Branch $branch
    if ($existing) {
        $prUrl = $existing.url
        $prNum = [string]$existing.number
        Write-Log "Close-out: reusing open PR #$prNum for branch $branch"
    }
    if (-not $prUrl) {
        $prBody = "Fixes #$($State.issue_number)`n`nAutonomad v1 — developed autonomously. See the report for details."
        $prBodyFile = Join-Path $script:DataDir "pr-body-$issueRef.md"
        [System.IO.File]::WriteAllText($prBodyFile, $prBody, (New-Object System.Text.UTF8Encoding($false)))
        $prOut = Invoke-Gh @('pr', 'create', '--repo', $Config['repo'], '--title', "Autonomad: $($Issue.title)",
            '--body-file', $prBodyFile, '--head', $branch, '--base', $Config['base_branch']) | Out-String
        Remove-Item -LiteralPath $prBodyFile -Force
        $prUrl = ($prOut | Select-String -Pattern 'https://github.com/.*/pull/\d+' | Select-Object -First 1).Matches.Value
        if (-not $prUrl) { $prUrl = $prOut.Trim() }
        $m = [regex]::Match($prUrl, 'pull/(\d+)')
        if ($m.Success) { $prNum = $m.Groups[1].Value }
        Write-Log "PR created: $prUrl"
    }
    # Note on the reused root PR (the root's `Fixes #N` body stays intact). Covers
    # BOTH revision children (Parent: #N) and sequential chain children (Blocked by
    # #N) — each pushes to the shared root branch so reviewers see cumulative work.
    if ($isChild -and $prNum) {
        try {
            $rootRef = Get-StateProp -State $State -Name 'root_ref'
            Add-PrComment -PrNumber $prNum -Body "Autonomad added #$($State.issue_number) to this PR (root #$rootRef) — re-requesting review. The branch now includes the work from tickets sharing branch $($State.branch)."
            Write-Log "Chain note appended to PR #$prNum for #$($State.issue_number)"
        } catch {
            Write-Log "Chain PR comment failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    # Label pending-review + leave the queue: drop ready-for-agent so a closed-out
    # issue never re-polls, and unassign the bot (its work is done).
    Set-IssueLabel -IssueNumber $State.issue_number -Add @('pending-review') -Remove @('in-progress', 'ready-for-agent')
    try {
        Invoke-Gh @('issue', 'edit', "$($State.issue_number)", '--repo', $Config['repo'],
            '--remove-assignee', $Config['bot_login']) | Out-Null
    } catch {
        Write-Log "Unassign on close-out failed for #$($State.issue_number): $($_.Exception.Message)" -Level 'WARN'
    }
    # The completed issue's work is done — clear the `blocked` label on any open
    # issue that declared this one as a dependency (chain children can now proceed).
    Unblock-Dependents -IssueNumber $State.issue_number

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
        -Summary "Autonomad v1.5 finished #$($State.issue_number). PR opened; checklist completed; pending human review."

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
        Set-IssueLabel -IssueNumber $State.issue_number -Add @('needs-human') -Remove @('in-progress', 'autonomous', 'ready-for-agent')
        # Structured gate comment (display-sync pattern) replaces the ad-hoc line.
        Add-GateComment -IssueNumber $State.issue_number -Gate ($State.current_step ?? 'halt') `
            -Status 'blocked' -Summary "Autonomad halted and needs a human. Reason: $Reason"
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
            # Fails closed: an unreadable state is a plan-level failure -> halt
            Write-Log "Resume scan: unreadable pipeline-state in $($dir.Name): $($_.Exception.Message)" -Level 'WARN'
            continue
        }
        if ($state.status -eq 'needs-human') {
            Write-Log "Skipping $($dir.Name): needs-human" -Level 'DEBUG'
            continue
        }
        # `done` = the dev agent finished ALL gates inside the sandbox but the tick
        # was killed before close-out (push + PR). It MUST be resumed for close-out
        # (no sandbox) — otherwise the PR never opens and the issue strands with the
        # bot's in-progress claim.
        $isResumableDone = ($state.status -eq 'done')
        if ($state.status -in @('claimed', 'in_progress', 'done')) {
            # TTL-stale -> HALT with needs-human + comment (m7). Silently skipping
            # would strand the claim: the issue keeps the bot's assignee and the
            # in-progress label forever, so no human or bot can pick it up.
            # A `done` state skips the TTL check: the work is finished, so staleness
            # is meaningless — only close-out (push + PR) remains.
            if (-not $isResumableDone) {
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

    # --- revision parent/root resolution (Phase 0/1) ---
    # A child ticket (`Parent: #N` in the body) reuses the ROOT's branch and
    # open PR — never a new branch/PR per revision.
    # A CHAIN child (`Blocked by #N` in a sequential chain, e.g. #317 blocked by
    # #316) reuses the CHAIN ROOT's branch + open PR: the whole chain ships as one
    # PR so reviewers see the cumulative work. Chain-root resolution takes
    # precedence over the revision-parent resolution for these tickets.
    $parentRef = Get-ParentRef -Body $Issue.body
    $rootRef = $null
    $chainDeps = Get-DependencyRefs -Body $Issue.body
    $isChainChild = $false
    if ($chainDeps.Count -gt 0) {
        $chainRoot = Resolve-ChainRootRef -Issue $Issue
        if ($null -ne $chainRoot -and $chainRoot -ne $issueNum) {
            $rootRef = $chainRoot
            $branch = "$($Config['branch_prefix'])/issue-$chainRoot"
            $isChainChild = $true
            Write-Log "#$issueNum is a chain child of root #$chainRoot (blocked by $($chainDeps -join ',')) — reusing branch $branch"
        }
    }
    if (-not $isChainChild -and $null -ne $parentRef) {
        $rootRef = Resolve-RootRef -Issue $Issue
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

    # --- done-state fast-path: work finished, only close-out remains ---
    # The dev agent completed ALL gates in the sandbox (pipeline-state.status = done)
    # but the previous tick was killed before close-out. Skip re-provisioning a
    # sandbox — push the branch and open/reuse the PR directly.
    if ($state.status -eq 'done' -or (Test-PipelineComplete -State $state)) {
        Write-Log "Resuming completed #$issueNum (all gates done) — close-out only, no sandbox."
        $newState = Close-OutIssue -State $state -Issue $Issue -Workspace $workspace
        Write-PipelineState -Path (Join-Path $workspace 'pipeline-state.json') -State $newState | Out-Null
        Commit-PipelineState -Workspace $workspace -State $newState -Message "close-out: PR created"
        & (Join-Path $PSScriptRoot 'learn.ps1') -State $newState -Workspace $workspace -DataDir $script:DataDir -Mode closeout
        if ($LASTEXITCODE -ne 0) { Write-Log "learn.ps1 (closeout) failed (exit $LASTEXITCODE)" -Level 'WARN' }
        Write-Log "DONE #$issueNum — PR $($newState.pr_url) pending human review."
        return
    }

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

    # --- persist research learnings into the learning store (capture even on halt/failure) ---
    Persist-Learnings -AgentResult $agentResult -Workspace $workspace -IssueRef $issueRef -IssueNumber $issueNum

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
        Write-Log "Poll script-stack: $($_.ScriptStackTrace -split "`n" | Select-Object -First 6)" -Level 'DEBUG'
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
            Write-Log "Issue proc stack: $($_.ScriptStackTrace -split "`n" | Select-Object -First 6)" -Level 'DEBUG'
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
