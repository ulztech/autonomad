# Autonomad v1 — scripts/mock-dev-agent.ps1
#
# Mock dev agent for dry-run E2E (T9). Simulates what the real dev agent inside
# the sandbox does: writes a pipeline-state.json + result.json into the workspace.
#
# Outcome is selected via AUTONOMAD_MOCK_OUTCOME env var:
#   success      — complete all gates, write result.outcome=success (close-out path)
#   halt-conf    — status=needs-human, confidence 0.5 (confidence<90% halt)
#   halt-fatal   — status=needs-human, fatal_flaw=true (fatal flaw halt)
#   halt-escalate— status=needs-human, plan_escalation=true (escalation halt)
#   fail         — status=in_progress, attempts incremented, result.outcome=failed (retry/hard-stop)
#   missing      — writes NOTHING (tests fails-closed missing-state path)
# Default: success.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][object]$State,
    [hashtable]$Config = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src' 'Pipeline.ps1')

$outcome = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_MOCK_OUTCOME')
if ([string]::IsNullOrWhiteSpace($outcome)) { $outcome = 'success' }

Write-Host "[mock-dev-agent] outcome=$outcome workspace=$Workspace"

$statePath = Join-Path $Workspace 'pipeline-state.json'
$autoDir = Join-Path $Workspace '.autonomad'
if (-not (Test-Path -LiteralPath $autoDir)) { New-Item -ItemType Directory -Path $autoDir -Force | Out-Null }
$resultPath = Join-Path $autoDir 'result.json'

if ($outcome -eq 'missing') {
    Write-Host "[mock-dev-agent] outcome=missing — removing pipeline-state.json (fails closed)"
    # Gate 0 always committed a state; the dev run failing to leave a valid state
    # is what the tick must detect. Delete it to simulate the absence.
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
    exit 0
}

# Start from the state the tick provided (may be gate-0 or a resume state).
$newState = $State
if ($null -eq $newState) {
    $newState = New-PipelineState -IssueNumber 0 -Repo 'mock/mock' -Branch 'mock/issue-0' -Owner 'mock-bot'
}

switch ($outcome) {
    'success' {
        # Advance every gate to completed.
        foreach ($g in @('implementation', 'tester_gate', 'review_gate', 'security_gate', 'verifier_gate', 'commit_push', 'artifact_report', 'github_sync', 'human_approval')) {
            $newState = Complete-Gate -State $newState -Gate $g
        }
        $newState.status = 'done'
        $newState.confidence = 1.0
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            outcome = 'success'
            confidence = 1.0
            fatal_flaw = $false
            plan_escalation = $false
            summary = 'mock success: all gates green'
        } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    'halt-conf' {
        $newState.status = 'needs-human'
        $newState.halt_reason = 'plan confidence 50% < 90% (mock)'
        $newState.confidence = 0.5
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            outcome = 'needs-human'
            confidence = 0.5
            fatal_flaw = $false
            plan_escalation = $false
            summary = 'mock halt: low confidence'
        } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    'halt-fatal' {
        $newState.status = 'needs-human'
        $newState.halt_reason = 'fatal flaw discovered (mock)'
        $newState.confidence = 0.95
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            outcome = 'needs-human'
            confidence = 0.95
            fatal_flaw = $true
            plan_escalation = $false
            summary = 'mock halt: fatal flaw'
        } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    'halt-escalate' {
        $newState.status = 'needs-human'
        $newState.halt_reason = 'plan escalation (mock)'
        $newState.confidence = 0.95
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            outcome = 'needs-human'
            confidence = 0.95
            fatal_flaw = $false
            plan_escalation = $true
            summary = 'mock halt: escalation'
        } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    'fail' {
        # The TICK owns attempt counting (max_retries hard stop). The mock just
        # reports a failed outcome; it must NOT bump attempts itself.
        $newState.status = 'in_progress'
        $newState.last_error = 'mock failure'
        $newState.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-PipelineState -Path $statePath -State $newState | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            outcome = 'failed'
            confidence = 1.0
            fatal_flaw = $false
            plan_escalation = $false
            summary = 'mock dev failure'
        } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    default {
        throw "AUTONOMAD_MOCK_OUTCOME '$outcome' not recognized"
    }
}

Write-Host "[mock-dev-agent] wrote pipeline-state.json + result.json"
exit 0
