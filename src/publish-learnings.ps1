# Autonomad v1 — src/publish-learnings.ps1
#
# Manual learnings publish (Phase 4). Aggregates UNPUBLISHED knowledge from
# learning.db into a dated markdown file under the learnings dir:
#
#   <learnings_dir>/YYYY-MM-DD.md      (default: <DataDir>/learnings)
#
# Cursor model:
#   - A cursor file (`.publish-cursor`) in the learnings dir records the last
#     published date (YYYY-MM-DD).
#   - Items with a created/updated date STRICTLY AFTER the cursor are published.
#   - No new items -> no file is written (cursor stays).
#   - After a successful publish, the cursor advances to today (the publish date).
#
# Memory model (settled): the AIOS brain is read-only; autonomad-data is the
# second memory where dated learning artifacts land. Publish is MANUAL only —
# no schedule, no GitHub push for now.
#
# Usage:
#   pwsh -File src/publish-learnings.ps1 [-DataDir <dir>] [-ConfigPath <repo.config>] [-LearningsDir <dir>]
#
# Exit codes: 0 = published (or nothing new), 1 = error.

[CmdletBinding()]
param(
    [string]$DataDir = '',
    [string]$ConfigPath = '',
    [string]$LearningsDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'repo.config' }

# --- learnings dir resolution: -LearningsDir > env AUTONOMAD_LEARNINGS_DIR > repo.config learnings_dir > <DataDir>/learnings ---
if (-not $LearningsDir) {
    $envDir = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_LEARNINGS_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envDir)) { $LearningsDir = $envDir }
}
if (-not $LearningsDir) {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            . (Join-Path $PSScriptRoot 'Config.ps1')
            $cfg = Read-RepoConfig -ConfigPath $ConfigPath
            if ($cfg.Contains('learnings_dir') -and -not [string]::IsNullOrWhiteSpace($cfg['learnings_dir'])) {
                $LearningsDir = $cfg['learnings_dir']
            }
        } catch {
            Write-Warning "publish-learnings: repo.config read failed ($($_.Exception.Message)) — falling back to DataDir/learnings"
        }
    }
}
if (-not $LearningsDir) {
    if (-not $DataDir) {
        $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
        $DataDir = if ($envData) { $envData } else { $RepoRoot }
    }
    $LearningsDir = Join-Path $DataDir 'learnings'
}
if (-not (Test-Path -LiteralPath $LearningsDir)) { New-Item -ItemType Directory -Path $LearningsDir -Force | Out-Null }

# --- database resolution ---
if (-not $DataDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $DataDir = if ($envData) { $envData } else { $RepoRoot }
}
$script:DbPath = Join-Path $DataDir 'learning.db'
if (-not (Test-Path -LiteralPath $script:DbPath)) {
    Write-Host "[publish] no learning.db at $($script:DbPath) — nothing to publish"
    exit 0
}

# --- backend detection (mirror learn.ps1: sqlite3 CLI first, then python) ---
$script:Backend = $null
$override = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_LEARN_BACKEND')
if ($override -in @('sqlite3cli', 'python')) { $script:Backend = $override }

function Select-Backend {
    if ($script:Backend) { return $script:Backend }
    $sqliteCli = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqliteCli) { return 'sqlite3cli' }
    foreach ($py in @((Get-Command python -ErrorAction SilentlyContinue), (Get-Command python3 -ErrorAction SilentlyContinue))) {
        if (-not $py) { continue }
        $probe = & $py.Source -c "import sqlite3; print(sqlite3.sqlite_version)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -match '^\d+\.\d+') { return 'python' }
    }
    throw 'publish-learnings requires sqlite3 CLI or python (with sqlite3) to read learning.db'
}
$script:Backend = Select-Backend

function Get-PythonExe {
    foreach ($py in @((Get-Command python -ErrorAction SilentlyContinue), (Get-Command python3 -ErrorAction SilentlyContinue))) {
        if (-not $py) { continue }
        $probe = & $py.Source -c "import sqlite3; print(sqlite3.sqlite_version)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -match '^\d+\.\d+') { return $py.Source }
    }
    throw 'python with sqlite3 module not found'
}

<#
.SYNOPSIS
  Run a SELECT and return rows as an array of PSCustomObjects.
#>
function Invoke-Query {
    [CmdletBinding()]
    param([string]$Sql)
    if ($script:Backend -eq 'python') {
        $py = Get-PythonExe
        $env:LEARN_DB = $script:DbPath
        # Read SQL from stdin to avoid quoting issues (matches learn.ps1 Invoke-Sql).
        $out = $Sql | & $py -c "import sqlite3, os, sys, json; con=sqlite3.connect(os.environ['LEARN_DB']); con.row_factory=sqlite3.Row; cur=con.cursor(); cur.execute(sys.stdin.read()); rows=[dict(r) for r in cur.fetchall()]; print(json.dumps(rows))" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "python query failed: $Sql" }
        if ([string]::IsNullOrWhiteSpace(($out -join ''))) { return @() }
        return @(($out -join "`n") | ConvertFrom-Json)
    }
    # sqlite3 CLI: -json emits a JSON array.
    $cli = (Get-Command sqlite3 -ErrorAction Stop).Source
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "learn-query-$([guid]::NewGuid().ToString('N')).json"
    try {
        & $cli -json $script:DbPath $Sql 1> $tmp
        if ($LASTEXITCODE -ne 0) { throw "sqlite3 query failed: $Sql" }
        if (-not (Test-Path -LiteralPath $tmp)) { return @() }
        $raw = Get-Content -LiteralPath $tmp -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- cursor ---
$script:CursorFile = Join-Path $LearningsDir '.publish-cursor'
$cursor = ''
if (Test-Path -LiteralPath $script:CursorFile) {
    $cursor = (Get-Content -LiteralPath $script:CursorFile -Raw).Trim()
}
$today = (Get-Date).ToString('yyyy-MM-dd')

Write-Host "[publish] backend=$script:Backend db=$($script:DbPath) learnings_dir=$LearningsDir cursor='$cursor'"

# --- gather new items (created/updated strictly after cursor) ---
$filterClause = if ($cursor) { "WHERE date(created_at) > '$cursor'" } else { '' }
$knowledge = @(Invoke-Query -Sql "SELECT issue_ref, knowledge, source, confidence, created_at FROM knowledge $filterClause ORDER BY created_at;")
$decisions = @(Invoke-Query -Sql "SELECT issue_ref, gate, decision, rationale, created_at FROM decisions $filterClause ORDER BY created_at;")
$issuesFilter = if ($cursor) { "WHERE date(updated_at) > '$cursor'" } else { '' }
$issues = @(Invoke-Query -Sql "SELECT issue_ref, repo, title, status, pr_url, revision_count, updated_at FROM issues $issuesFilter ORDER BY updated_at;")
$revFilter = if ($cursor) { "WHERE date(created_at) > '$cursor'" } else { '' }
$revisions = @(Invoke-Query -Sql "SELECT child_ref, root_ref, request, created_at FROM revisions $revFilter ORDER BY created_at;")

$total = $knowledge.Count + $decisions.Count + $issues.Count + $revisions.Count
if ($total -eq 0) {
    Write-Host "[publish] no new items since cursor '$cursor' — no file written."
    exit 0
}

# --- render the dated markdown file ---
$lines = @(
    "# Autonomad Learnings — $today",
    '',
    '> Published manually via `src/publish-learnings.ps1`. Newest items from learning.db since the last publish.'
    if ($cursor) { "> Cursor before this publish: $cursor" }
    '',
    "Total items: $total"
)
if ($revisions.Count -gt 0) {
    $lines += '', '## Revisions', ''
    foreach ($r in $revisions) {
        $lines += "- **$($r.child_ref)** → root **$($r.root_ref)** — $($r.request)"
        $lines += "  - recorded: $($r.created_at)"
        $lines += ''
    }
}
if ($knowledge.Count -gt 0) {
    $lines += '', '## Knowledge', ''
    foreach ($k in $knowledge) {
        $src = if ($k.source) { " (source: $($k.source))" } else { '' }
        $lines += "- **[$($k.issue_ref)]** $($k.knowledge)$src"
        $lines += "  - confidence: $($k.confidence) · recorded: $($k.created_at)"
        $lines += ''
    }
}
if ($decisions.Count -gt 0) {
    $lines += '', '## Decisions', ''
    foreach ($d in $decisions) {
        $lines += "- **[$($d.issue_ref) · $($d.gate)]** $($d.decision)"
        if ($d.rationale) { $lines += "  - rationale: $($d.rationale)" }
        $lines += "  - recorded: $($d.created_at)"
        $lines += ''
    }
}
if ($issues.Count -gt 0) {
    $lines += '', '## Issues', ''
    foreach ($i in $issues) {
        $rev = if ($null -ne $i.revision_count -and $i.revision_count -gt 0) { " · revisions: $($i.revision_count)" } else { '' }
        $pr = if ($i.pr_url) { " · $($i.pr_url)" } else { '' }
        $lines += "- **[$($i.issue_ref)]** $($i.title) — *$($i.status)*$rev$pr"
        $lines += "  - updated: $($i.updated_at)"
        $lines += ''
    }
}

$outFile = Join-Path $LearningsDir "$today.md"
[System.IO.File]::WriteAllText($outFile, ($lines -join "`n").TrimEnd() + "`n", (New-Object System.Text.UTF8Encoding($false)))

# Advance the cursor to today (publish date).
[System.IO.File]::WriteAllText($script:CursorFile, $today + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[publish] wrote $outFile ($total item(s)); cursor advanced to $today"
exit 0
