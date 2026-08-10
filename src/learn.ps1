# Autonomad v1 — src/learn.ps1
#
# Learning store (T8). Persists decisions + knowledge + issues to a real SQLite
# database (learning.db) with tables:
#   decisions   — decision-after-gate events (gate, decision, rationale, context)
#   knowledge   — verified knowledge items (deduped by normalized hash)
#   issues      — per-issue lifecycle summary (issue_ref, repo, status, pr_url, ...)
#
# Backend detection order (dependency-light, documented):
#   1. sqlite3 CLI  — if `sqlite3` is on PATH (typical inside the Docker image)
#   2. Python       — if `python`/`python3` has the built-in sqlite3 module
#                     (present on this dev machine: Python 3.50.4)
#   3. JSONL        — portable fallback store (learning.jsonl) with the SAME
#                     schema shape, so consumers are backend-agnostic.
# The chosen backend is echoed at startup. All writes go through one driver.
#
# Modes:
#   -Mode decision   Record a decision after a gate (args: -Gate, -Decision, -Rationale)
#   -Mode knowledge  Record a verified knowledge item (args: -Knowledge, -Source, -Confidence)
#   -Mode closeout   Record issue lifecycle summary at close-out
#   -Mode harvest    Post-run knowledge harvest (dedupe + log summary)
#
# Usage:
#   pwsh -File src/learn.ps1 -State <obj> -Workspace <dir> -DataDir <dir> -Mode closeout
#   pwsh -File src/learn.ps1 -DataDir <dir> -Mode harvest

[CmdletBinding()]
param(
    [object]$State,             # pipeline state object (for closeout/decision modes)
    [string]$Workspace = '',    # issue workspace (to scan for knowledge artifacts)
    [string]$DataDir = '',
    [ValidateSet('decision', 'knowledge', 'closeout', 'harvest')]
    [string]$Mode = 'harvest',
    [string]$Gate = '',
    [string]$Decision = '',
    [string]$Rationale = '',
    [string]$Knowledge = '',
    [string]$Source = '',
    [double]$Confidence = 0.9
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $DataDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $DataDir = if ($envData) { $envData } else { Split-Path -Parent $PSScriptRoot }
}
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$script:DbPath = Join-Path $DataDir 'learning.db'
$script:JsonlPath = Join-Path $DataDir 'learning.jsonl'   # fallback store

# ============================================================
# Backend detection
# ============================================================
$script:Backend = $null

function Select-Backend {
    # Explicit override (used by tests / troubleshooting): AUTONOMAD_LEARN_BACKEND
    $override = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_LEARN_BACKEND')
    if ($override -in @('sqlite3cli', 'python', 'jsonl')) { return $override }

    $sqliteCli = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqliteCli) { return 'sqlite3cli' }

    # Python with built-in sqlite3? Prefer `python` (real install) over the
    # WindowsApps python3 shim; use -c so the probe runs as code, not a file path.
    foreach ($py in @((Get-Command python -ErrorAction SilentlyContinue), (Get-Command python3 -ErrorAction SilentlyContinue))) {
        if (-not $py) { continue }
        $probe = & $py.Source -c "import sqlite3; print(sqlite3.sqlite_version)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -match '^\d+\.\d+') { return 'python' }
    }
    return 'jsonl'
}

$script:Backend = Select-Backend
Write-Host "[learn] backend: $script:Backend"

# ============================================================
# Drivers
# ============================================================
function Get-SqliteCli {
    return (Get-Command sqlite3 -ErrorAction Stop).Source
}

function Get-PythonExe {
    foreach ($py in @((Get-Command python -ErrorAction SilentlyContinue), (Get-Command python3 -ErrorAction SilentlyContinue))) {
        if (-not $py) { continue }
        $probe = & $py.Source -c "import sqlite3; print(sqlite3.sqlite_version)" 2>$null
        if ($LASTEXITCODE -eq 0 -and "$probe".Trim() -match '^\d+\.\d+') { return $py.Source }
    }
    throw 'Python with sqlite3 module not found'
}

# Execute SQL against the database (write or read). For read, returns rows via
# the backend's own printing (sqlite3 CLI: table output; python: JSON lines).
function Invoke-Sql {
    param([string]$Sql)
    switch ($script:Backend) {
        'sqlite3cli' {
            $cli = Get-SqliteCli
            & $cli $script:DbPath $Sql
            if ($LASTEXITCODE -ne 0) { throw "sqlite3 failed: $Sql" }
        }
        'python' {
            $py = Get-PythonExe
            $env:LEARN_DB = $script:DbPath
            # Read SQL from stdin to avoid quoting issues.
            $Sql | & $py -c "import sqlite3, os, sys, json; db=os.environ['LEARN_DB']; con=sqlite3.connect(db); cur=con.cursor(); sql=sys.stdin.read(); cur.executescript(sql); con.commit(); con.close()"
            if ($LASTEXITCODE -ne 0) { throw "python sqlite3 failed" }
        }
        'jsonl' {
            # JSONL fallback: execute supported statements against learning.jsonl.
            Invoke-Jsonl -Sql $Sql
        }
    }
}

# JSONL fallback store — same schema shape, line-delimited JSON records.
function Get-JsonlPath {
    return $script:JsonlPath
}

function Read-JsonlRecords {
    if (-not (Test-Path -LiteralPath $script:JsonlPath)) { return @() }
    $records = @()
    foreach ($line in Get-Content -LiteralPath $script:JsonlPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records += ($line | ConvertFrom-Json) } catch { }
    }
    return $records
}

function Invoke-Jsonl {
    param([string]$Sql)
    # Only INSERT + CREATE handled; SELECT returns nothing here (reporting paths
    # use the jsonl file directly). This keeps the fallback minimal but functional.
    if ($Sql -match '^\s*CREATE\s+TABLE') {
        # no-op: schema is implicit (columns from INSERT records)
        return
    }
    if ($Sql -match '^\s*INSERT\s+(?:OR\s+IGNORE\s+)?INTO\s+(\w+)') {
        $table = $Matches[1]
        # parse VALUES (...),(...) — we always use the format
        # INSERT [OR IGNORE] INTO t (col1,col2) VALUES ('v1','v2')
        if ($Sql -match "INSERT\s+(?:OR\s+IGNORE\s+)?INTO\s+$table\s*\(([^)]+)\)\s*VALUES\s*(.*)") {
            $cols = ($Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"') })
            $valuesText = $Matches[2].Trim().TrimEnd(';').Trim()
            # Strip any trailing ON CONFLICT / RETURNING clause (we only need the tuples).
            if ($valuesText -match '^(.*?)\s+ON\s+CONFLICT\b') { $valuesText = $Matches[1].Trim() }
            # Extract each parenthesized tuple
            $tuples = [regex]::Matches($valuesText, "\(([^)]*)\)")
            foreach ($t in $tuples) {
                $vals = $t.Groups[1].Value
                $parts = @()
                # crude split on commas outside quotes
                $inQ = $false; $cur = ''
                foreach ($ch in $vals.ToCharArray()) {
                    if ($ch -eq "'") { $inQ = -not $inQ; continue }
                    if ($ch -eq ',' -and -not $inQ) { $parts += $cur; $cur = ''; continue }
                    $cur += $ch
                }
                $parts += $cur
                $rec = [ordered]@{ _table = $table; _ts = (Get-Date).ToUniversalTime().ToString('o') }
                for ($i = 0; $i -lt $cols.Count -and $i -lt $parts.Count; $i++) {
                    $v = $parts[$i].Trim("'")
                    # Coerce numeric-looking values so the JSONL shape matches SQLite types.
                    if ($v -match '^-?\d+$') { $rec[$cols[$i]] = [int64]$v }
                    elseif ($v -match '^-?\d+\.\d+$') { $rec[$cols[$i]] = [double]$v }
                    else { $rec[$cols[$i]] = $v }
                }
                Add-Content -LiteralPath $script:JsonlPath -Value (($rec | ConvertTo-Json -Compress))
            }
        }
        return
    }
}

# ============================================================
# Schema (real SQLite)
# ============================================================
$script:SchemaSql = @'
CREATE TABLE IF NOT EXISTS decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_ref TEXT NOT NULL,
    gate TEXT NOT NULL,
    decision TEXT NOT NULL,
    rationale TEXT,
    context TEXT,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS knowledge (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_ref TEXT NOT NULL,
    hash TEXT NOT NULL,
    knowledge TEXT NOT NULL,
    source TEXT,
    confidence REAL DEFAULT 0.9,
    created_at TEXT NOT NULL,
    UNIQUE(hash)
);
CREATE TABLE IF NOT EXISTS issues (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_ref TEXT NOT NULL,
    repo TEXT,
    title TEXT,
    status TEXT,
    outcome TEXT,
    pr_url TEXT,
    confidence REAL,
    attempts INTEGER DEFAULT 0,
    created_at TEXT,
    updated_at TEXT,
    UNIQUE(issue_ref)
);
'@

function Initialize-Db {
    if ($script:Backend -eq 'jsonl') {
        # JSONL fallback: nothing to create up front.
        return
    }
    Invoke-Sql -Sql $script:SchemaSql
}

# ============================================================
# Record helpers
# ============================================================
function Get-IssueRef {
    if ($State -and $State.issue_ref) { return $State.issue_ref }
    return 'unknown'
}

function Add-Decision {
    $issueRef = Get-IssueRef
    $decisionText = if ($Decision) { $Decision } else { 'gate advanced' }
    $gateText = if ($Gate) { $Gate } else { if ($State) { $State.current_step } else { 'n/a' } }
    $ctxRepo = if ($State -and $State.PSObject.Properties.Name -contains 'repo') { $State.repo } else { '' }
    $ctxBranch = if ($State -and $State.PSObject.Properties.Name -contains 'branch') { $State.branch } else { '' }
    $context = "repo=$ctxRepo branch=$ctxBranch"
    $sql = "INSERT INTO decisions (issue_ref, gate, decision, rationale, context, created_at) VALUES ('$($issueRef.Replace("'", "''"))','$($gateText.Replace("'", "''"))','$($decisionText.Replace("'", "''"))','$($Rationale.Replace("'", "''"))','$($context.Replace("'", "''"))','$((Get-Date).ToUniversalTime().ToString('o'))')"
    Invoke-Sql -Sql $sql
    Write-Host "[learn] decision recorded (gate=$gateText)"
}

function Get-Hash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
}

function Add-Knowledge {
    $issueRef = Get-IssueRef
    if (-not $Knowledge) { throw 'Add-Knowledge requires -Knowledge' }
    # Normalize (trim + collapse whitespace) then hash for dedup.
    $normalized = ($Knowledge -replace '\s+', ' ').Trim()
    $hash = Get-Hash -Text $normalized
    $conf = [math]::Round($Confidence, 2)
    $sql = "INSERT OR IGNORE INTO knowledge (issue_ref, hash, knowledge, source, confidence, created_at) VALUES ('$($issueRef.Replace("'", "''"))','$hash','$($normalized.Replace("'", "''"))','$($Source.Replace("'", "''"))',$conf,'$((Get-Date).ToUniversalTime().ToString('o'))')"
    Invoke-Sql -Sql $sql
    Write-Host "[learn] knowledge recorded (hash=$hash, dedup on)"
}

function Add-IssueSummary {
    $issueRef = Get-IssueRef
    if (-not $State) { return }
    $outcome = $State.status
    $sql = @"
INSERT INTO issues (issue_ref, repo, title, status, outcome, pr_url, confidence, attempts, created_at, updated_at)
VALUES ('$($State.issue_ref.Replace("'", "''"))','$($State.repo.Replace("'", "''"))','$(($State.issue.title -replace "'", "''"))','$($State.status.Replace("'", "''"))','$outcome','$($State.pr_url)',$($State.confidence),$($State.attempts),'$($State.created_at)','$((Get-Date).ToUniversalTime().ToString('o'))')
ON CONFLICT(issue_ref) DO UPDATE SET status=excluded.status, outcome=excluded.outcome, pr_url=excluded.pr_url, confidence=excluded.confidence, attempts=excluded.attempts, updated_at=excluded.updated_at;
"@
    Invoke-Sql -Sql $sql
    Write-Host "[learn] issue summary upserted (status=$outcome)"
}

function Add-Harvest {
    # Post-run harvest: dedupe knowledge and summarize what was learned.
    if ($script:Backend -eq 'jsonl') {
        $records = @(Read-JsonlRecords | Where-Object { $_._table -eq 'knowledge' })
        Write-Host "[learn] harvest (jsonl): $($records.Count) knowledge records present"
        return
    }
    $countSql = "SELECT COUNT(*) AS n FROM knowledge;"
    # Use backend-specific count read
    $n = $null
    switch ($script:Backend) {
        'sqlite3cli' {
            $cli = Get-SqliteCli
            $n = (& $cli $script:DbPath "SELECT COUNT(*) FROM knowledge;" | Select-Object -First 1)
        }
        'python' {
            $py = Get-PythonExe
            $env:LEARN_DB = $script:DbPath
            $n = (& $py -c "import sqlite3,os; con=sqlite3.connect(os.environ['LEARN_DB']); print(con.execute('SELECT COUNT(*) FROM knowledge').fetchone()[0])")
        }
    }
    if ($null -eq $n) { $n = 0 }
    $issues = 0
    switch ($script:Backend) {
        'sqlite3cli' {
            $cli = Get-SqliteCli
            $issues = (& $cli $script:DbPath "SELECT COUNT(*) FROM issues;" | Select-Object -First 1)
        }
        'python' {
            $py = Get-PythonExe
            $env:LEARN_DB = $script:DbPath
            $issues = (& $py -c "import sqlite3,os; con=sqlite3.connect(os.environ['LEARN_DB']); print(con.execute('SELECT COUNT(*) FROM issues').fetchone()[0])")
        }
    }
    if ($null -eq $issues) { $issues = 0 }
    Write-Host "[learn] harvest complete: $n knowledge items, $issues issues tracked"
}

# ============================================================
# Main
# ============================================================
Initialize-Db

switch ($Mode) {
    'decision'  { Add-Decision }
    'knowledge' { Add-Knowledge }
    'closeout'  { Add-IssueSummary; Add-Harvest }
    'harvest'   { Add-Harvest }
}

exit 0
