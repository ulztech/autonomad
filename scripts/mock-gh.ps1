# Autonomad v1 — scripts/mock-gh.ps1
#
# Mock `gh` CLI for the DryRun E2E (T9). Implements exactly the gh subcommands
# the tick loop uses, backed by a JSON state file so tests can assert behavior:
#   gh label create
#   gh issue list | view | edit | comment
#   gh pr create
#   gh api user
#
# State lives at $env:MOCK_GH_STATE (a .json path). Events are appended to a
# parallel `events.json` so the E2E can assert the autonomy boundary
# (no merge, no approved label ever applied by the bot).
#
# Usage (as a GH_BIN):  pwsh -File scripts/mock-gh.ps1 <subcommand> [args...]

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StateFile = [System.Environment]::GetEnvironmentVariable('MOCK_GH_STATE')
if (-not $script:StateFile) { throw 'mock-gh: MOCK_GH_STATE env var required' }
$script:EventsFile = Join-Path (Split-Path -Parent $script:StateFile) 'events.json'

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        return [pscustomobject]@{ labels = @{}; issues = @{}; next_pr = 1 }
    }
    return Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
}

function Save-State([object]$State) {
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:StateFile -Encoding utf8
}

function Add-Event([string]$Type, [hashtable]$Data = @{}) {
    $evt = @{ type = $Type; ts = (Get-Date).ToUniversalTime().ToString('o') } + $Data
    Add-Content -LiteralPath $script:EventsFile -Value ($evt | ConvertTo-Json -Compress)
}

function Get-FlagValue([string[]]$ArgList, [string]$Flag) {
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        if ($ArgList[$i] -eq $Flag -and ($i + 1) -lt $ArgList.Count) { return $ArgList[$i + 1] }
    }
    return $null
}

function Get-BoolFlag([string[]]$ArgList, [string]$Flag) {
    return ($ArgList -contains $Flag)
}

$state = Get-State
$cmd = $Args[0]
$rest = @($Args[1..($Args.Count - 1)])

switch ($cmd) {
    'label' {
        if ($rest[0] -ne 'create') { throw "mock-gh: unsupported label subcommand: $($rest[0])" }
        $name = $rest[1]
        $repo = Get-FlagValue $rest '--repo'
        if (-not $state.labels.PSObject.Properties[$name]) {
            $state.labels | Add-Member -NotePropertyName $name -NotePropertyValue @{ name = $name; color = (Get-FlagValue $rest '--color'); repo = $repo }
            Save-State $state
            Write-Output "created label $name"
            Add-Event 'label_create' @{ label = $name; repo = $repo }
        } else {
            Write-Output "Label '$name' already exists"
            exit 1   # matches real gh behavior; callers treat as idempotent OK
        }
    }
    'issue' {
        $sub = $rest[0]
        $repo = Get-FlagValue $rest '--repo'
        switch ($sub) {
            'list' {
                $label = Get-FlagValue $rest '--label'
                $assignee = Get-FlagValue $rest '--assignee'
                $limit = [int](Get-FlagValue $rest '--limit')
                $search = Get-FlagValue $rest '--search'
                $items = @()
                foreach ($p in $state.issues.PSObject.Properties) {
                    $iss = $p.Value
                    if ($iss.state -ne 'OPEN') { continue }
                    if ($label -and ($iss.labels -notcontains $label)) { continue }
                    if ($assignee -eq 'none' -and $iss.assignees.Count -gt 0) { continue }
                    # Minimal `--search` support (tick polls with the search API):
                    #   is:open            — open only (already applied above)
                    #   no:assignee        — unassigned
                    #   assignee:<login>   — assigned to <login>
                    #   label:"X" / label:X — carries label X
                    if ($search) {
                        if ($search -match '\bno:assignee\b' -and $iss.assignees.Count -gt 0) { continue }
                        $m = [regex]::Match($search, 'assignee:([A-Za-z0-9_.-]+)')
                        if ($m.Success -and ($iss.assignees -notcontains $m.Groups[1].Value)) { continue }
                        $wantedLabels = @([regex]::Matches($search, 'label:"([^"]+)"|label:([A-Za-z0-9_.-]+)') | ForEach-Object {
                            if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                        })
                        if ($wantedLabels.Count -gt 0) {
                            $isOr = ($search -match '\bOR\b')
                            if ($isOr) {
                                # OR semantics: issue must carry at least one of the labels.
                                $hasAny = $false
                                foreach ($w in $wantedLabels) { if ($iss.labels -contains $w) { $hasAny = $true } }
                                if (-not $hasAny) { continue }
                            } else {
                                $hasAll = $true
                                foreach ($w in $wantedLabels) { if ($iss.labels -notcontains $w) { $hasAll = $false } }
                                if (-not $hasAll) { continue }
                            }
                        }
                    }
                    $items += $iss
                    if ($limit -gt 0 -and $items.Count -ge $limit) { break }
                }
                # Real `gh issue list --json` always emits a JSON array, even for
                # one row. Force array serialization to keep tick parsing identical.
                if ($items.Count -eq 0) {
                    Write-Output '[]'
                } elseif ($items.Count -eq 1) {
                    Write-Output ("[" + ($items[0] | ConvertTo-Json -Compress -Depth 6) + "]")
                } else {
                    $items | ConvertTo-Json -Compress -Depth 6
                }
            }
            'view' {
                $num = [int]$rest[1]
                $iss = $state.issues.PSObject.Properties[$num.ToString()].Value
                if (-not $iss) { throw "mock-gh: issue $num not found" }
                $iss | ConvertTo-Json -Depth 6
            }
            'edit' {
                $num = [int]$rest[1]
                $key = $num.ToString()
                if (-not $state.issues.PSObject.Properties[$key]) {
                    throw "mock-gh: issue $num not found"
                }
                $iss = $state.issues.PSObject.Properties[$key].Value
                # --add-assignee
                $assignee = Get-FlagValue $rest '--add-assignee'
                if ($assignee) {
                    $iss.assignees = @($iss.assignees) + @($assignee)
                    Add-Event 'issue_assign' @{ issue = $num; assignee = $assignee }
                }
                # --remove-label (comma-separated)
                $remLabels = Get-FlagValue $rest '--remove-label'
                if ($remLabels) {
                    foreach ($l in ($remLabels -split ',')) {
                        $iss.labels = @($iss.labels | Where-Object { $_ -ne $l })
                    }
                }
                # --add-label
                $addLabels = Get-FlagValue $rest '--add-label'
                if ($addLabels) {
                    foreach ($l in ($addLabels -split ',')) {
                        if ($iss.labels -notcontains $l) { $iss.labels = @($iss.labels) + @($l) }
                        Add-Event 'issue_label_add' @{ issue = $num; label = $l }
                    }
                }
                # --body-file (checklist sync reads/writes the issue body)
                $bodyFile = Get-FlagValue $rest '--body-file'
                if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) {
                    $iss.body = (Get-Content -LiteralPath $bodyFile -Raw).TrimEnd("`r", "`n")
                    Add-Event 'issue_body_update' @{ issue = $num }
                }
                Save-State $state
                Write-Output "edited issue #$num"
            }
            'comment' {
                $num = [int]$rest[1]
                $bodyFile = Get-FlagValue $rest '--body-file'
                $body = if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) { Get-Content -LiteralPath $bodyFile -Raw } else { '' }
                Add-Event 'issue_comment' @{ issue = $num; body = $body.Trim() }
                Write-Output "commented on issue #$num"
            }
            default { throw "mock-gh: unsupported issue subcommand: $sub" }
        }
    }
    'pr' {
        if ($rest[0] -eq 'list') {
            $repo = Get-FlagValue $rest '--repo'
            $head = Get-FlagValue $rest '--head'
            $stateOpen = Get-FlagValue $rest '--state'
            $items = @()
            if ($state.prs) {
                foreach ($p in @($state.prs.PSObject.Properties | ForEach-Object { $_.Value })) {
                    if ($head -and $p.head -ne $head) { continue }
                    if ($stateOpen -and $p.state -ne 'OPEN') { continue }
                    $items += $p
                }
            }
            if ($items.Count -eq 0) {
                Write-Output '[]'
            } elseif ($items.Count -eq 1) {
                Write-Output ("[" + ($items[0] | ConvertTo-Json -Compress -Depth 6) + "]")
            } else {
                $items | ConvertTo-Json -Compress -Depth 6
            }
            exit 0
        }
        if ($rest[0] -eq 'comment') {
            $prNum = [int]$rest[1]
            $repo = Get-FlagValue $rest '--repo'
            $bodyFile = Get-FlagValue $rest '--body-file'
            $body = if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) { Get-Content -LiteralPath $bodyFile -Raw } else { '' }
            Add-Event 'pr_comment' @{ pr = $prNum; body = $body.Trim() }
            Write-Output "commented on PR #$prNum"
            exit 0
        }
        if ($rest[0] -ne 'create') { throw "mock-gh: unsupported pr subcommand: $($rest[0])" }
        $repo = Get-FlagValue $rest '--repo'
        $head = Get-FlagValue $rest '--head'
        $bodyFile = Get-FlagValue $rest '--body-file'
        $body = if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) { Get-Content -LiteralPath $bodyFile -Raw } else { '' }
        $prNum = [int]$state.next_pr
        $state.next_pr = $prNum + 1
        $url = "https://github.com/$repo/pull/$prNum"
        if (-not $state.PSObject.Properties['prs']) {
            $state | Add-Member -NotePropertyName 'prs' -NotePropertyValue ([pscustomobject]@{})
        }
        $newPr = [pscustomobject]@{ number = $prNum; head = $head; state = 'OPEN'; url = $url }
        $state.prs | Add-Member -NotePropertyName "pr$prNum" -NotePropertyValue $newPr -Force
        Add-Event 'pr_create' @{ repo = $repo; head = $head; body = $body.Trim(); pr = $prNum; url = $url }
        Save-State $state
        Write-Output $url
    }
    'api' {
        if ($rest[0] -ne 'user') { throw "mock-gh: unsupported api: $($rest[0])" }
        Write-Output 'mock-bot'
    }
    default {
        throw "mock-gh: unsupported command: $cmd"
    }
}

# Success paths must always exit 0 so the tick loop's $LASTEXITCODE checks work.
exit 0
