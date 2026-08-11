# Autonomad v1 — src/Pipeline.ps1
#
# Per-issue pipeline-state.json helpers: create, read (schema-validated, fails
# closed), advance gates, write. Shared by tick.ps1, learn.ps1, report.ps1.
#
# Dot-source this file:  . "$PSScriptRoot/Pipeline.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The ten gates, in dependency order. Matches pipeline-state.schema.json.
$script:AllGates = @(
    'branch_guard', 'implementation', 'tester_gate', 'review_gate',
    'security_gate', 'verifier_gate', 'commit_push', 'artifact_report',
    'github_sync', 'human_approval'
)

<#
.SYNOPSIS
  Path to the pipeline-state.schema.json (repo root per PLAN.md layout).
#>
function Get-PipelineSchemaPath {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot 'pipeline-state.schema.json')
}

<#
.SYNOPSIS
  Create a gate-0 pipeline state for a freshly claimed issue.
#>
function New-PipelineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$IssueNumber,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$Owner,
        [string]$Harness = '',
        [string]$Model = '',
        [int]$MaxRetries = 2,
        [hashtable]$IssueSnapshot = @{},
        [object]$ParentRef = $null,     # issue number of the revision parent (#N from `Parent: #N`)
        [object]$RootRef = $null        # issue number of the root ticket in the revision chain
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $gates = [ordered]@{}
    foreach ($g in $script:AllGates) { $gates[$g] = 'pending' }
    $gates['branch_guard'] = 'completed'  # gate 0 = branch + state committed

    $state = [ordered]@{
        schema_version = 1
        pipeline_id    = "autonomad-issue-$IssueNumber"
        issue_ref      = "issue-$IssueNumber"
        issue_number   = $IssueNumber
        repo           = $Repo
        project        = ($Repo -split '/')[-1]
        branch         = $Branch
        owner          = $Owner
        harness        = $Harness
        model          = $Model
        parent_ref     = $ParentRef
        root_ref       = $RootRef
        current_step   = 'claimed'
        next_gate      = 'implementation'
        gates          = $gates
        completed      = @('branch_guard')
        pending        = @($script:AllGates | Where-Object { $_ -ne 'branch_guard' })
        attempts       = 0
        max_retries    = $MaxRetries
        confidence     = 0.0
        status         = 'claimed'
        halt_reason    = $null
        last_error     = $null
        pr_url         = $null
        created_at     = $now
        updated_at     = $now
        timestamps     = @{ branch_guard = $now }
        issue          = $IssueSnapshot
    }
    return $state
}

<#
.SYNOPSIS
  Read + validate pipeline-state.json. FAILS CLOSED: missing/empty/invalid
  state throws (plan-level failure) so callers must halt.
#>
function Read-PipelineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SchemaPath = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Fails-closed: pipeline-state.json missing at $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Fails-closed: pipeline-state.json is empty at $Path"
    }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch {
        throw "Fails-closed: pipeline-state.json is not valid JSON at $Path : $($_.Exception.Message)"
    }
    # Schema validation when a schema file exists.
    if (-not [string]::IsNullOrWhiteSpace($SchemaPath) -and (Test-Path -LiteralPath $SchemaPath)) {
        $schema = Get-Content -LiteralPath $SchemaPath -Raw
        $valid = $true
        try {
            # Test-Json -Schema is available on PowerShell 7.4+. Fall back to structural checks.
            if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
                $params = @{ Json = $raw }
                if ($PSVersionTable.PSVersion -ge [version]'7.4.0') { $params['Schema'] = $schema }
                $valid = Test-Json @params
            }
        } catch { $valid = $false }
        if (-not $valid) {
            throw "Fails-closed: pipeline-state.json failed schema validation at $Path"
        }
    }
    return $obj
}

<#
.SYNOPSIS
  Serialize a pipeline state object to disk (UTF-8, no BOM).
#>
function Write-PipelineState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $State | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $json
}

<#
.SYNOPSIS
  Mark a gate completed and advance next_gate. Updates timestamps + completed/pending.
  Normalizes the state to an ordered hashtable so all mutations serialize reliably
  (Add-Member on hashtables would otherwise shadow existing keys).
#>
function Complete-Gate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Gate,
        [string]$NewStatus = 'in_progress'
    )
    if ($Gate -notin $script:AllGates) { throw "Unknown gate: $Gate" }

    # Normalize PSCustomObject (from JSON) or hashtable to a mutable ordered hashtable.
    $s = [ordered]@{}
    if ($State -is [System.Collections.IDictionary]) {
        foreach ($k in $State.Keys) { $s[$k] = $State[$k] }
    } else {
        foreach ($p in $State.PSObject.Properties) { $s[$p.Name] = $p.Value }
    }
    # Ensure nested structures are mutable hashtables too.
    $s['gates'] = @{}; foreach ($g in $script:AllGates) { $s['gates'][$g] = $State.gates.$g }
    $s['completed'] = @($s['completed'])
    $s['pending'] = @($s['pending'])
    if (-not $s.Contains('timestamps')) { $s['timestamps'] = @{} }
    elseif ($s['timestamps'] -isnot [System.Collections.IDictionary]) {
        $ts = @{}; foreach ($p in $s['timestamps'].PSObject.Properties) { $ts[$p.Name] = $p.Value }
        $s['timestamps'] = $ts
    }

    if ($s['gates'][$Gate] -eq 'completed') {
        Write-Verbose "Gate $Gate already completed; no-op."
        return $s
    }
    $s['gates'][$Gate] = 'completed'
    if ($Gate -notin @($s['completed'])) { $s['completed'] = @($s['completed']) + $Gate }
    $s['pending'] = @($script:AllGates | Where-Object { $s['gates'][$_] -ne 'completed' })
    # Advance current_step / next_gate to the next pending gate.
    $next = $null
    foreach ($g in $script:AllGates) {
        if ($s['gates'][$g] -ne 'completed') { $next = $g; break }
    }
    $s['current_step'] = $Gate
    $s['next_gate'] = $next
    $s['timestamps'][$Gate] = (Get-Date).ToUniversalTime().ToString('o')
    $s['updated_at'] = (Get-Date).ToUniversalTime().ToString('o')
    return $s
}

<#
.SYNOPSIS
  Return true when the pipeline has no pending gates left (all completed).
#>
function Test-PipelineComplete {
    param([object]$State)
    return (@($State.pending | Where-Object { $_ -ne '' }).Count -eq 0)
}
