<#
.SYNOPSIS
    Autonomad Monitor — live operational dashboard for Autonomad's runtime state.

.DESCRIPTION
    A zero-dependency monitoring utility that shows what Autonomad is doing right now:
    per-session (per-issue) status, pipeline gate progress, agent activities, and a
    live "is it running" strip (tick process, sandbox containers, last tick time).

    Serve mode (default):      pwsh -File src/monitor.ps1 [-DataDir ...] [-Port 8686]
                               Starts a local HTTP server on http://127.0.0.1:<port>.
                               The page polls /api/state every <Refresh> seconds
                               (default 5) and pauses when the tab is hidden.
    Snapshot mode (-Once):     pwsh -File src/monitor.ps1 -Once
                               Writes monitor.html + monitor.json (self-contained,
                               meta-refresh) for offline viewing / sharing.

    Read-only utility: never writes to the pipeline, never touches tick.ps1 gates.

.EXAMPLE
    pwsh -File src/monitor.ps1 -DataDir C:\GitRepos\autonomad-data -Open

.EXAMPLE
    pwsh -File src/monitor.ps1 -Once -Out C:\Temp\autonomad-monitor.html
#>
[CmdletBinding()]
param(
    [string]$DataDir = 'C:\GitRepos\autonomad-data',
    [string]$OutFile = '',
    [switch]$Once,
    [int]$Port = 8686,
    [int]$Refresh = 5,
    [int]$LogLines = 150,
    [switch]$Open,
    [switch]$NoOpen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# Constants
# ---------------------------------------------------------------
$script:GateOrder = @(
    'branch_guard', 'implementation', 'tester_gate', 'review_gate',
    'security_gate', 'verifier_gate', 'commit_push', 'artifact_report',
    'github_sync', 'human_approval'
)
$script:TtlDefault = 3600   # matches repo.config ttl; overridden when config readable

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
function Get-Prop {
    param([object]$Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Read-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-Gates {
    param([object]$State)
    $gates = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $State) { return @($gates) }
    $gatesObj = Get-Prop $State 'gates'
    if ($null -ne $gatesObj) {
        foreach ($name in $script:GateOrder) {
            $val = Get-Prop $gatesObj $name
            if ($null -ne $val) { $gates.Add([pscustomobject]@{ name = $name; state = "$val" }) }
        }
        $known = @($gates | ForEach-Object { $_.name })
        foreach ($p in $gatesObj.PSObject.Properties) {
            if ($p.Name -notin $known) {
                $gates.Add([pscustomobject]@{ name = $p.Name; state = "$($p.Value)" })
            }
        }
    } else {
        $done = @(Get-Prop $State 'completed')
        foreach ($name in $script:GateOrder) {
            $s = if ($done -contains $name) { 'completed' } else { 'pending' }
            $gates.Add([pscustomobject]@{ name = $name; state = $s })
        }
    }
    return @($gates)
}

function Get-RelAge {
    param([string]$UpdatedAt, [DateTime]$NowUtc)
    if ([string]::IsNullOrWhiteSpace($UpdatedAt)) { return $null }
    try {
        $dt = [datetime]::Parse($UpdatedAt).ToUniversalTime()
        return [math]::Max(0, [int](($NowUtc - $dt).TotalSeconds))
    } catch {
        return $null
    }
}

function Get-TtlSeconds {
    $cfg = 'C:\GitRepos\autonomad\repo.config'
    if (Test-Path -LiteralPath $cfg) {
        foreach ($line in (Get-Content -LiteralPath $cfg)) {
            $line = $line.Trim()
            if ($line -match '^ttl\s*=\s*(\d+)') { return [int]$Matches[1] }
        }
    }
    return $script:TtlDefault
}

function Get-Verdict {
    param([object]$State, [object]$Result, $AgeSec, [int]$Ttl)
    $rawStatus = ''
    $step = ''
    if ($null -ne $State) {
        $rawStatus = [string](Get-Prop $State 'status')
        $step = [string](Get-Prop $State 'current_step')
    }
    $stale = ($null -ne $AgeSec -and ($rawStatus -in @('claimed', 'in_progress') -or $step -in @('claimed', 'in_progress'))) -and $AgeSec -gt $Ttl

    if ($rawStatus -eq 'needs-human' -or $step -eq 'halted') {
        return [pscustomobject]@{ status = 'needs-human'; label = 'Needs Human'; level = 'crit'; stale = $stale }
    }
    if ($rawStatus -in @('claimed', 'in_progress') -or $step -in @('claimed', 'in_progress')) {
        $lv = if ($stale) { 'warn' } else { 'active' }
        return [pscustomobject]@{ status = 'in_progress'; label = 'In Progress'; level = $lv; stale = $stale }
    }
    $allDone = $false
    $gates = Get-Gates $State
    if ($gates.Count -gt 0) {
        $allDone = (($gates | Where-Object { $_.state -ne 'completed' }).Count) -eq 0
    }
    if ($null -ne $Result -and (Get-Prop $Result 'outcome') -eq 'success') {
        return [pscustomobject]@{ status = 'pending-review'; label = 'Pending Review'; level = 'active'; stale = $false }
    }
    if ($allDone -or $step -in @('human_approval', 'github_sync', 'artifact_report', 'commit_push')) {
        return [pscustomobject]@{ status = 'pending-review'; label = 'Pending Review'; level = 'active'; stale = $false }
    }
    return [pscustomobject]@{ status = 'unknown'; label = 'Unknown'; level = 'muted'; stale = $false }
}

function Get-LiveSignals {
    param([string]$DataDir)
    $nowUtc = (Get-Date).ToUniversalTime()

    # tick process running?
    $tickRunning = $false; $tickPid = $null
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine -match 'tick\.ps1') {
                $tickRunning = $true; $tickPid = $p.ProcessId; break
            }
        }
    } catch { }

    # sandbox containers
    $ctns = [System.Collections.Generic.List[object]]::new()
    try {
        $out = & docker ps -a --filter "name=autonomad-sandbox-" --format '{{.ID}}|{{.Names}}|{{.Status}}' 2>$null
        foreach ($l in @($out)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            $p = $l -split '\|'
            $ctns.Add([pscustomobject]@{ id = $p[0]; name = $p[1]; status = $p[2] })
        }
    } catch { }

    # sandbox image present?
    $imgPresent = $false
    try {
        $null = & docker image inspect autonomad:v1 2>$null
        $imgPresent = ($LASTEXITCODE -eq 0)
    } catch { $imgPresent = $false }

    # last tick
    $lastTick = $null; $lastTickAge = $null
    $tsPath = Join-Path $DataDir 'last_tick.ts'
    if (Test-Path -LiteralPath $tsPath) {
        $lastTick = (Get-Content -LiteralPath $tsPath -Raw).Trim()
        $lastTickAge = Get-RelAge -UpdatedAt $lastTick -NowUtc $nowUtc
    }

    return [pscustomobject]@{
        tick_running  = $tickRunning
        tick_pid      = $tickPid
        sandbox_ctns  = @($ctns)
        image_present = $imgPresent
        last_tick     = $lastTick
        last_tick_age = $lastTickAge
    }
}

function Get-LogTail {
    param([string]$DataDir, [int]$Lines)
    $candidates = @(
        (Join-Path $DataDir 'logs\tick.log'),
        'C:\GitRepos\autonomad\logs\tick.log'
    )
    $logFile = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending | Select-Object -First 1
    if (-not $logFile) { return [pscustomobject]@{ file = $null; lines = @() } }
    $all = Get-Content -LiteralPath $logFile -Tail $Lines -ErrorAction SilentlyContinue
    return [pscustomobject]@{ file = $logFile; lines = @($all) }
}

# ---------------------------------------------------------------
# Supervisor + self-heal collectors (issue #19)
# ---------------------------------------------------------------
function Get-SupervisorState {
    param([string]$DataDir, [DateTime]$NowUtc)
    $sup = Read-Json -Path (Join-Path $DataDir 'supervisor-state.json')
    if ($null -eq $sup) { return $null }
    $alive = $false
    try {
        $p = Get-Process -Id ([int]$sup.pid) -ErrorAction Stop
        $alive = ($null -ne $p)
    } catch { $alive = $false }
    $age = Get-RelAge -UpdatedAt ([string]$sup.updated_at) -NowUtc $NowUtc
    $reconcileAge = Get-RelAge -UpdatedAt ([string](Get-Prop $sup 'last_reconcile_at')) -NowUtc $NowUtc
    return [pscustomobject]@{
        pid                  = Get-Prop $sup 'pid'
        started_at           = Get-Prop $sup 'started_at'
        updated_at           = Get-Prop $sup 'updated_at'
        age_sec              = $age
        alive                = $alive
        repo                 = Get-Prop $sup 'repo'
        harness              = Get-Prop $sup 'harness'
        docker_up            = Get-Prop $sup 'docker_up'
        docker_checks_down   = Get-Prop $sup 'docker_checks_down'
        tick_pid             = Get-Prop $sup 'tick_pid'
        tick_status          = Get-Prop $sup 'tick_status'
        restarts             = Get-Prop $sup 'restarts_in_window'
        last_tick_exit_at    = Get-Prop $sup 'last_tick_exit_at'
        last_reconcile_at    = Get-Prop $sup 'last_reconcile_at'
        last_reconcile_age_sec = $reconcileAge
        last_reconcile_result = Get-Prop $sup 'last_reconcile_result'
        gh_auth              = Get-Prop $sup 'gh_auth'
        last_error           = Get-Prop $sup 'last_error'
    }
}

function Get-HealEvents {
    param([string]$DataDir, [int]$Max = 30)
    $log = Join-Path $DataDir 'reconciliation.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    $lines = Get-Content -LiteralPath $log -Tail $Max -ErrorAction SilentlyContinue
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $lines) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        $events.Add([pscustomobject]@{
            ts      = [string]$o.ts
            action  = [string]$o.action
            issue   = [string]$o.issue
            reason  = [string]$o.reason
            dry_run = [bool]$o.dry_run
        })
    }
    return @($events)
}

# gh claim queue, cached for 60s (the monitor polls every few seconds).
$script:QueueCache = $null
$script:QueueCacheAt = $null
$script:QueueError = $null

function Get-ClaimQueue {
    param([string]$Repo)
    if ([string]::IsNullOrWhiteSpace($Repo)) { return $null }
    $now = (Get-Date).ToUniversalTime()
    if ($null -ne $script:QueueCacheAt -and ($now - $script:QueueCacheAt).TotalSeconds -lt 60) {
        return $script:QueueCache
    }
    try {
        $json = & gh issue list --repo $Repo `
            --search 'is:open no:assignee (label:"ready-for-agent" OR label:"autonomous")' `
            --json 'number,title' 2>$null
        if ($LASTEXITCODE -ne 0) {
            $script:QueueError = 'gh issue list failed'
            $script:QueueCache = $null
        } else {
            $items = @($json | ConvertFrom-Json)
            $script:QueueCache = @($items | ForEach-Object {
                [pscustomobject]@{ number = [int]$_.number; title = [string]$_.title }
            })
            $script:QueueError = $null
        }
    } catch {
        $script:QueueError = $_.Exception.Message
        $script:QueueCache = $null
    }
    $script:QueueCacheAt = $now
    return $script:QueueCache
}

function Get-Session {
    param([System.IO.DirectoryInfo]$Dir, [int]$Ttl, [DateTime]$NowUtc)
    $id = $Dir.Name
    $num = $null
    if ($id -match '^issue-(\d+)$') { $num = [int]$Matches[1] }

    $statePath = Join-Path $Dir.FullName 'pipeline-state.json'
    $state = $null; $parseError = $null
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    $result = Read-Json -Path (Join-Path $Dir.FullName '.autonomad\result.json')

    $repo = [string](Get-Prop $state 'repo')
    $issueObj = Get-Prop $state 'issue'
    $title = [string](Get-Prop $issueObj 'title')
    if (-not $title) { $title = if ($num) { "(no issue payload in state)" } else { $id } }
    $issueUrl = [string](Get-Prop $issueObj 'url')
    if (-not $issueUrl -and $num -and $repo) { $issueUrl = "https://github.com/$repo/issues/$num" }
    $prUrl = [string](Get-Prop $state 'pr_url')
    if (-not $prUrl) { $prUrl = $null }

    $reportPath = $null
    if ($num) {
        $rp = Join-Path $DataDir "reports\issue-$num.html"
        if (Test-Path -LiteralPath $rp) { $reportPath = $rp }
    }

    $updatedAt = [string](Get-Prop $state 'updated_at')
    $ageSec = Get-RelAge -UpdatedAt $updatedAt -NowUtc $NowUtc
    $verdict = Get-Verdict -State $state -Result $result -AgeSec $ageSec -Ttl $Ttl

    $confidence = Get-Prop $state 'confidence'
    if ($null -eq $confidence -and $null -ne $result) { $confidence = Get-Prop $result 'confidence' }

    $resultSummary = $null
    if ($null -ne $result) {
        $resultSummary = [pscustomobject]@{
            outcome    = [string](Get-Prop $result 'outcome')
            confidence = Get-Prop $result 'confidence'
            fatal_flaw = Get-Prop $result 'fatal_flaw'
            summary    = [string](Get-Prop $result 'summary')
        }
    }

    return [pscustomobject]@{
        id            = $id
        issue_number  = $num
        title         = $title
        repo          = $repo
        issue_url     = $issueUrl
        pr_url        = $prUrl
        report_path   = $reportPath
        status        = $verdict.status
        status_label  = $verdict.label
        level         = $verdict.level
        stale         = $verdict.stale
        current_step  = [string](Get-Prop $state 'current_step')
        next_gate     = [string](Get-Prop $state 'next_gate')
        gates         = Get-Gates $state
        attempts      = Get-Prop $state 'attempts'
        max_retries   = Get-Prop $state 'max_retries'
        confidence    = $confidence
        model         = [string](Get-Prop $state 'model')
        harness       = [string](Get-Prop $state 'harness')
        halt_reason   = [string](Get-Prop $state 'halt_reason')
        updated_at    = $updatedAt
        age_sec       = $ageSec
        parse_error   = $parseError
        result        = $resultSummary
        agent_logs    = @(Get-Prop $state 'agent_logs')
        raw           = ($state | ConvertTo-Json -Depth 8 -Compress)
    }
}

function Collect-State {
    param([string]$DataDir, [int]$Refresh, [int]$LogLines)
    $nowUtc = (Get-Date).ToUniversalTime()
    $ttl = Get-TtlSeconds
    $live = Get-LiveSignals -DataDir $DataDir
    $logTail = Get-LogTail -DataDir $DataDir -Lines $LogLines
    $supervisor = Get-SupervisorState -DataDir $DataDir -NowUtc $nowUtc
    $healEvents = Get-HealEvents -DataDir $DataDir
    $queueRepo = $null
    if ($null -ne $supervisor) { $queueRepo = [string]$supervisor.repo }
    $queue = Get-ClaimQueue -Repo $queueRepo
    $queueError = $script:QueueError

    $sessions = [System.Collections.Generic.List[object]]::new()
    $wsDir = Join-Path $DataDir 'workspaces'
    if (Test-Path -LiteralPath $wsDir) {
        foreach ($d in (Get-ChildItem -LiteralPath $wsDir -Directory | Sort-Object Name)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'pipeline-state.json')) {
                $sessions.Add((Get-Session -Dir $d -Ttl $ttl -NowUtc $nowUtc))
            }
        }
    }

    # overall verdict: crit > warn(stale) > warn(supervisor down) > running > active > idle
    $crit = @($sessions | Where-Object { $_.level -eq 'crit' })
    $warn = @($sessions | Where-Object { $_.level -eq 'warn' })
    $actv = @($sessions | Where-Object { $_.level -eq 'active' })
    $supDown = ($null -ne $supervisor -and -not $supervisor.alive)
    if ($crit.Count -gt 0) {
        $overall = [pscustomobject]@{ status = 'ATTENTION'; level = 'crit'; icon = '🔴' }
    } elseif ($warn.Count -gt 0) {
        $overall = [pscustomobject]@{ status = 'STALE'; level = 'warn'; icon = '🟡' }
    } elseif ($supDown) {
        $overall = [pscustomobject]@{ status = 'SUPERVISOR DOWN'; level = 'warn'; icon = '🛡' }
    } elseif ($live.tick_running) {
        $overall = [pscustomobject]@{ status = 'RUNNING'; level = 'ok'; icon = '●' }
    } elseif ($actv.Count -gt 0) {
        $overall = [pscustomobject]@{ status = 'ACTIVE'; level = 'active'; icon = '◉' }
    } else {
        $overall = [pscustomobject]@{ status = 'IDLE'; level = 'muted'; icon = '○' }
    }

    return [pscustomobject]@{
        generated_at = $nowUtc.ToString('o')
        refresh      = $Refresh
        data_dir     = $DataDir
        ttl          = $ttl
        overall      = $overall
        live         = $live
        supervisor   = $supervisor
        heal_events  = $healEvents
        queue        = $queue
        queue_error  = $queueError
        sessions     = @($sessions)
        log_tail     = $logTail
    }
}

# ---------------------------------------------------------------
# HTML template (single-quoted here-string: no interpolation)
# ---------------------------------------------------------------
$script:Template = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="__REFRESH__">
<title>Autonomad Monitor</title>
<style>
  :root{
    --bg:#0d1117; --panel:#161b22; --panel2:#1c2129; --border:#30363d;
    --text:#e6edf3; --dim:#8b949e; --muted:#6e7681;
    --ok:#3fb950; --warn:#d29922; --crit:#f85149; --active:#58a6ff; --muted2:#484f58;
  }
  *{box-sizing:border-box; margin:0; padding:0;}
  body{background:var(--bg); color:var(--text); font:14px/1.45 "Segoe UI",system-ui,sans-serif; padding:0 16px 24px;}
  a{color:var(--active); text-decoration:none;} a:hover{text-decoration:underline;}
  .topbar{position:sticky; top:0; z-index:50; background:rgba(13,17,23,.96); backdrop-filter:blur(4px);
    border-bottom:1px solid var(--border); padding:10px 0; display:flex; align-items:center; gap:14px; flex-wrap:wrap;}
  .brand{font-size:16px; font-weight:700; letter-spacing:.3px;}
  .brand .live-dot{display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:8px; vertical-align:1px;}
  .pill{font-weight:700; padding:4px 12px; border-radius:999px; font-size:13px; letter-spacing:.4px;}
  .pill.ok{background:rgba(63,185,80,.16); color:var(--ok); border:1px solid var(--ok);}
  .pill.warn{background:rgba(210,153,34,.16); color:var(--warn); border:1px solid var(--warn);}
  .pill.crit{background:rgba(248,81,73,.16); color:var(--crit); border:1px solid var(--crit);}
  .pill.active{background:rgba(88,166,255,.14); color:var(--active); border:1px solid var(--active);}
  .pill.muted{background:rgba(110,118,129,.14); color:var(--dim); border:1px solid var(--border);}
  .subdots{display:flex; gap:10px; font-size:12px; color:var(--dim); flex-wrap:wrap;}
  .subdots .dot{display:inline-flex; align-items:center; gap:4px;}
  .controls{margin-left:auto; display:flex; gap:8px; align-items:center; flex-wrap:wrap;}
  .controls button{background:var(--panel2); color:var(--text); border:1px solid var(--border); border-radius:6px;
    padding:4px 10px; cursor:pointer; font-size:12px;}
  .controls button:hover{border-color:var(--active);}
  .controls input, .controls select{background:var(--panel2); color:var(--text); border:1px solid var(--border);
    border-radius:6px; padding:4px 8px; font-size:12px;}
  #last-refresh{color:var(--muted); font-size:12px;}
  .tiles{display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin:14px 0;}
  .tile{background:var(--panel); border:1px solid var(--border); border-radius:8px; padding:12px 14px;}
  .tile .k{font-size:11px; text-transform:uppercase; letter-spacing:.6px; color:var(--dim);}
  .tile .v{font-size:24px; font-weight:700; margin-top:4px;}
  .tile .v small{font-size:12px; font-weight:400; color:var(--dim);}
  .tile.small .v{font-size:15px;}
  .tile.ok .v{color:var(--ok);} .tile.warn .v{color:var(--warn);} .tile.crit .v{color:var(--crit);}
  .tile.active .v{color:var(--active);} .tile.muted .v{color:var(--dim);}
  .section-title{font-size:12px; text-transform:uppercase; letter-spacing:.8px; color:var(--dim); margin:18px 0 8px;}
  .card{background:var(--panel); border:1px solid var(--border); border-radius:8px; margin-bottom:10px; overflow:hidden;}
  .card.level-crit{border-left:4px solid var(--crit);}
  .card.level-warn{border-left:4px solid var(--warn);}
  .card.level-active{border-left:4px solid var(--active);}
  .card.level-ok{border-left:4px solid var(--ok);}
  .card.level-muted{border-left:4px solid var(--muted2);}
  .card-head{display:flex; align-items:center; gap:10px; padding:10px 14px; cursor:pointer; flex-wrap:wrap;}
  .card-head:hover{background:var(--panel2);}
  .badge{font-size:11px; font-weight:700; padding:2px 9px; border-radius:999px; white-space:nowrap;}
  .badge.crit{background:rgba(248,81,73,.16); color:var(--crit);}
  .badge.warn{background:rgba(210,153,34,.16); color:var(--warn);}
  .badge.active{background:rgba(88,166,255,.14); color:var(--active);}
  .badge.ok{background:rgba(63,185,80,.14); color:var(--ok);}
  .badge.muted{background:rgba(110,118,129,.14); color:var(--dim);}
  .num{font-weight:700; color:var(--active); white-space:nowrap;}
  .title{flex:1; min-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
  .repo{font-size:11px; color:var(--muted); white-space:nowrap;}
  .chev{color:var(--muted); transition:transform .15s;}
  .chev.open{transform:rotate(90deg);}
  .card-body{padding:0 14px 12px; display:none;}
  .card-body.show{display:block;}
  .gates{display:flex; gap:3px; margin:10px 0 8px;}
  .gate-seg{flex:1; height:8px; border-radius:2px; background:var(--muted2); min-width:8px;}
  .gate-seg.completed{background:var(--ok);}
  .gate-seg.in_progress{background:var(--warn);}
  .gate-seg.failed{background:var(--crit);}
  .chips{display:flex; gap:8px; flex-wrap:wrap; font-size:12px; color:var(--dim);}
  .chip{background:var(--panel2); border:1px solid var(--border); border-radius:6px; padding:2px 8px;}
  .chip.stale{color:var(--warn); border-color:var(--warn);}
  .actions{display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;}
  .actions a,.actions span.lnk{font-size:12px; border:1px solid var(--border); border-radius:6px; padding:3px 10px;
    background:var(--panel2); color:var(--active);}
  .halt{border:1px solid var(--crit); background:rgba(248,81,73,.08); color:var(--crit);
    border-radius:6px; padding:6px 10px; margin-top:10px; font-size:12px;}
  .activities{border-top:1px dashed var(--border); margin-top:10px; padding-top:10px;}
  .tl{list-style:none;}
  .tl li{display:flex; gap:10px; align-items:flex-start; padding:4px 0; font-size:12px; border-bottom:1px solid rgba(48,54,61,.4);}
  .tl .t-dot{width:8px; height:8px; border-radius:50%; margin-top:4px; flex:none;}
  .tl .t-dot.pass{background:var(--ok);} .tl .t-dot.fail{background:var(--crit);} .tl .t-dot.info{background:var(--active);} .tl .t-dot.other{background:var(--muted2);}
  .tl .t-main{flex:1;}
  .tl .t-gate{font-weight:700; color:var(--active);}
  .tl .t-agent{color:var(--dim);}
  .tl .t-note{color:var(--dim); white-space:pre-wrap; word-break:break-word;}
  .tl .t-ts{color:var(--muted); white-space:nowrap; font-size:11px;}
  .result-box{border:1px solid var(--ok); background:rgba(63,185,80,.06); border-radius:6px; padding:8px 10px; margin-top:10px; font-size:12px; color:var(--dim);}
  .result-box b{color:var(--ok);}
  .err-box{border:1px solid var(--crit); background:rgba(248,81,73,.06); border-radius:6px; padding:8px 10px; margin-top:10px; font-size:12px; color:var(--crit);}
  .rawbox{margin-top:10px;}
  .rawbox summary{color:var(--muted); cursor:pointer; font-size:12px;}
  .rawbox pre{background:#0a0e14; border:1px solid var(--border); border-radius:6px; padding:8px; font-size:11px;
    max-height:260px; overflow:auto; color:var(--dim); white-space:pre-wrap; word-break:break-all; margin-top:6px;}
  .logs{background:#0a0e14; border:1px solid var(--border); border-radius:8px; padding:10px; font-family:Consolas,monospace; font-size:11.5px;}
  .log-line{white-space:pre-wrap; word-break:break-word; color:var(--dim);}
  .log-line.err{color:var(--crit);} .log-line.warn{color:var(--warn);}
  .log-ctl{display:flex; gap:8px; align-items:center; margin-bottom:8px; font-size:12px; color:var(--dim);}
  .log-ctl input{background:var(--panel2); border:1px solid var(--border); border-radius:6px; color:var(--text); padding:3px 8px; font-size:12px;}
  .empty{border:1px dashed var(--border); border-radius:8px; padding:22px; text-align:center; color:var(--dim); font-size:13px;}
  .footer{margin-top:20px; padding-top:10px; border-top:1px solid var(--border); color:var(--muted); font-size:11.5px; display:flex; gap:16px; flex-wrap:wrap;}
  @keyframes pulse{0%,100%{opacity:1;} 50%{opacity:.25;}}
  .pulse{animation:pulse 1.6s ease-in-out infinite;}
</style>
</head>
<body>
<div class="topbar">
  <div class="brand"><span class="live-dot" id="live-dot"></span>Autonomad Monitor <span style="color:var(--muted);font-weight:400;font-size:12px;">v1</span></div>
  <div class="pill" id="overall-pill">…</div>
  <div class="subdots" id="subdots"></div>
  <div class="controls">
    <span id="last-refresh"></span>
    <button id="btn-pause" title="Pause auto-refresh">⏸</button>
    <button id="btn-refresh" title="Refresh now">↻</button>
    <select id="status-filter">
      <option value="all">All statuses</option>
      <option value="crit">Needs Human</option>
      <option value="warn">Stale / Warning</option>
      <option value="active">Active</option>
      <option value="ok">Done</option>
      <option value="muted">Unknown</option>
    </select>
    <input id="search" type="search" placeholder="search issue…" style="width:150px;">
  </div>
</div>

<div class="tiles" id="tiles"></div>

<div class="section-title">Autonomad Health</div>
<div id="health-panel"></div>

<div class="section-title">Auto-Heal <span id="heal-count" style="text-transform:none; letter-spacing:0;"></span></div>
<div id="heal-panel"></div>

<div class="section-title">Claim Queue <span id="queue-meta" style="text-transform:none; letter-spacing:0;"></span></div>
<div id="queue-panel"></div>

<div class="section-title">Sessions</div>
<div id="cards"></div>

<div class="section-title">Live Logs <span id="logfile" style="text-transform:none; letter-spacing:0;"></span></div>
<div class="logs">
  <div class="log-ctl">
    <input id="log-filter" type="search" placeholder="filter log…" style="width:200px;">
    <label><input type="checkbox" id="log-autoscroll" checked> auto-scroll</label>
  </div>
  <div id="log-lines"></div>
</div>

<div class="footer">
  <span>Data: <span id="f-data"></span></span>
  <span>Refresh: <span id="f-refresh"></span>s</span>
  <span>TTL: <span id="f-ttl"></span>s</span>
  <span>Generated: <span id="f-generated"></span></span>
  <span id="f-mode"></span>
</div>

<script>
const INITIAL_STATE = __INITIAL_STATE__;
let state = INITIAL_STATE;
let expanded = new Set();
let paused = false;
const LEVELS = { crit:['🔴','Needs Human'], warn:['🟡','Stale'], active:['🔵','Active'], ok:['✅','Done'], muted:['⚪','Unknown'] };

const $ = s => document.querySelector(s);
function esc(s){ return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function fmtAge(sec){
  if (sec === null || sec === undefined) return '—';
  if (sec < 60) return sec + 's';
  if (sec < 3600) return Math.floor(sec/60) + 'm';
  if (sec < 86400) return Math.floor(sec/3600) + 'h';
  return Math.floor(sec/86400) + 'd';
}
function fmtTs(iso){
  if (!iso) return '';
  try { return new Date(iso).toLocaleString(); } catch(e){ return iso; }
}
function severityOrder(s){ return {crit:0, warn:1, active:2, ok:3, muted:4}[s.level] ?? 5; }

async function fetchState(){
  const r = await fetch('/api/state', {cache:'no-store'});
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function tick(){
  if (paused) return;
  if (document.hidden) return;               // pause when tab hidden (Page Visibility)
  try {
    state = await fetchState();
    render();
  } catch(e){ /* keep last good render */ }
}

function render(){
  // header
  const ov = state.overall;
  const pill = $('#overall-pill');
  pill.className = 'pill ' + ov.level;
  pill.textContent = ov.icon + ' ' + ov.status;
  const dot = $('#live-dot');
  dot.style.background = state.live.tick_running ? 'var(--ok)' : 'var(--muted2)';
  dot.classList.toggle('pulse', state.live.tick_running);

  const lv = state.live;
  const sub = $('#subdots');
  const tickTxt = lv.tick_running ? (lv.tick_pid ? 'tick PID ' + lv.tick_pid : 'tick running') : 'tick idle';
  const staleTick = lv.last_tick_age !== null && lv.last_tick_age > state.ttl;
  const sup = state.supervisor;
  const supTxt = sup
    ? (sup.alive ? (sup.tick_status === 'running' ? 'supervisor+tick up' : 'supervisor up') : 'SUPERVISOR DOWN ⚠')
    : 'supervisor off';
  const recTxt = sup && sup.last_reconcile_at ? 'reconcile ' + fmtAge(sup.last_reconcile_age_sec) + ' ago' : 'reconcile never';
  sub.innerHTML =
    '<span class="dot">⟳ ' + esc(tickTxt) + '</span>' +
    '<span class="dot">🛡 ' + esc(supTxt) + '</span>' +
    '<span class="dot">🔧 ' + esc(recTxt) + '</span>' +
    '<span class="dot">🐳 sandbox: ' + (lv.sandbox_ctns.length ? lv.sandbox_ctns.length + ' ctn' : 'none') + '</span>' +
    '<span class="dot">📦 image: ' + (lv.image_present ? 'present' : 'missing') + '</span>' +
    '<span class="dot">⏱ last tick: ' + (lv.last_tick ? fmtAge(lv.last_tick_age) + ' ago' + (staleTick ? ' ⚠' : '') : 'never') + '</span>';
  $('#last-refresh').textContent = 'updated ' + new Date().toLocaleTimeString();
  $('#btn-pause').textContent = paused ? '▶' : '⏸';

  // tiles
  const S = state.sessions;
  const cnt = l => S.filter(s => s.level === l).length;
  const tiles = $('#tiles');
  const t = (k,v,cls,extra) => '<div class="tile ' + cls + '"><div class="k">' + k + '</div><div class="v">' + v + (extra||'') + '</div></div>';
  tiles.innerHTML =
    t('Overall', ov.icon + ' ' + ov.status, ov.level) +
    t('Active', cnt('active'), cnt('active') ? 'active':'muted') +
    t('Stale', cnt('warn'), cnt('warn') ? 'warn':'muted') +
    t('Halted', cnt('crit'), cnt('crit') ? 'crit':'muted') +
    t('Done', cnt('ok'), cnt('ok') ? 'ok':'muted') +
    t('Last tick', lv.last_tick ? fmtAge(lv.last_tick_age) + ' ago' : 'never', staleTick ? 'warn':'muted', '<small> ttl ' + state.ttl + 's</small>') +
    t('Sandbox', lv.sandbox_ctns.length ? lv.sandbox_ctns.length + ' ctn' : 'none', lv.sandbox_ctns.length ? 'active':'muted') +
    t('Workspaces', S.length, 'muted');

  // cards
  const statusFilter = $('#status-filter').value;
  const q = $('#search').value.toLowerCase();
  const sorted = S.slice().sort((a,b) => severityOrder(a) - severityOrder(b) || (b.age_sec ?? 0) - (a.age_sec ?? 0));
  const shown = sorted.filter(s => (statusFilter === 'all' || s.level === statusFilter) &&
    (!q || String(s.issue_number || '').includes(q) || String(s.title||'').toLowerCase().includes(q)));
  $('#cards').innerHTML = shown.length ? shown.map(cardHtml).join('') :
    '<div class="empty">' + (S.length ? 'No sessions match the current filters.' : 'No workspaces found yet — Autonomad has not claimed any issues.' ) + '</div>';

  // logs
  const filter = $('#log-filter').value.toLowerCase();
  const lines = (state.log_tail.lines || []).filter(l => !filter || String(l).toLowerCase().includes(filter));
  const auto = $('#log-autoscroll').checked;
  const logEl = $('#log-lines');
  logEl.innerHTML = lines.map(l => {
    const c = /ERROR/i.test(l) ? 'err' : (/WARN/i.test(l) ? 'warn' : '');
    return '<div class="log-line ' + c + '">' + esc(l) + '</div>';
  }).join('') || '<div class="log-line" style="color:var(--muted)">(empty log)</div>';
  if (auto) logEl.parentElement.scrollTop = logEl.parentElement.scrollHeight;
  $('#logfile').textContent = state.log_tail.file || '';

  // footer
  $('#f-data').textContent = state.data_dir;
  $('#f-refresh').textContent = state.refresh;
  $('#f-ttl').textContent = state.ttl;
  $('#f-generated').textContent = new Date(state.generated_at).toLocaleString();

  // health / self-heal / queue panels
  renderHealth();
  renderHeal();
  renderQueue();
}

function renderHealth(){
  const panel = $('#health-panel');
  const sup = state.supervisor;
  if (!sup) {
    panel.innerHTML = '<div class="empty">Supervisor not started — invoke <b>/autonomad</b> to auto-start it, or run ' +
      '<code>pwsh -NoProfile -WindowStyle Hidden -File C:\GitRepos\autonomad\src\supervisor.ps1</code>.</div>';
    $('#heal-count').textContent = '';
    $('#queue-meta').textContent = '';
    return;
  }
  const t = (k,v,cls,extra) => '<div class="tile small ' + cls + '"><div class="k">' + k + '</div><div class="v">' + v + (extra||'') + '</div></div>';
  const supUp = sup.alive;
  const dockerOk = !!sup.docker_up;
  const tickOk = sup.tick_status === 'running' || (sup.tick_pid && sup.alive);
  const ghOk = !!sup.gh_auth;
  panel.innerHTML =
    t('Supervisor', supUp ? 'up' : 'DOWN', supUp ? 'ok' : 'crit', '<small> pid ' + esc(sup.pid ?? '—') + '</small>') +
    t('Tick loop', tickOk ? 'running' : (sup.tick_status || 'stopped'), tickOk ? 'ok' : 'warn', sup.tick_pid ? '<small> pid ' + esc(sup.tick_pid) + '</small>' : '') +
    t('Docker', dockerOk ? 'up' : 'down', dockerOk ? 'ok' : 'crit') +
    t('gh auth', ghOk ? 'ok' : 'fail', ghOk ? 'ok' : 'crit') +
    t('Last reconcile', sup.last_reconcile_at ? fmtAge(sup.last_reconcile_age_sec) + ' ago' : 'never', sup.last_reconcile_at ? 'active' : 'muted') +
    t('Heal events', state.heal_events.length, state.heal_events.length ? 'active' : 'muted');
  if (sup.last_error) panel.innerHTML += '<div class="halt" style="margin-top:8px;">⚠ ' + esc(sup.last_error) + '</div>';
  if (sup.last_reconcile_result) panel.innerHTML += '<div class="chips" style="margin-top:8px;"><span class="chip">' + esc(sup.last_reconcile_result) + '</span></div>';
}

function renderHeal(){
  const panel = $('#heal-panel');
  const ev = state.heal_events || [];
  $('#heal-count').textContent = ev.length ? '(' + ev.length + ' recent)' : '';
  if (!ev.length) {
    panel.innerHTML = '<div class="empty">No reconciliation events yet — the gated self-heal has not needed to act.</div>';
    return;
  }
  const clsOf = a => ({resume:'pass', 'mark-pending-review':'pass', release:'info', 'close-out':'info', 'resolve-halt':'pass', warn:'fail'})[a] || 'other';
  panel.innerHTML = '<div class="card"><ul class="tl" style="padding:8px 14px;">' + ev.map(e =>
    '<li><span class="t-dot ' + clsOf(e.action) + '"></span>' +
    '<span class="t-main"><span class="t-gate">' + esc(e.action) + (e.dry_run ? ' (dry-run)' : '') + '</span> ' +
    '<span class="t-agent">' + esc(e.issue) + '</span>' +
    '<div class="t-note">' + esc(e.reason || '') + '</div></span>' +
    '<span class="t-ts">' + fmtTs(e.ts) + '</span></li>'
  ).join('') + '</ul></div>';
}

function renderQueue(){
  const panel = $('#queue-panel');
  const q = state.queue;
  $('#queue-meta').textContent = q ? '(' + q.length + ' claimable)' : (state.queue_error ? '(' + esc(state.queue_error) + ')' : '');
  if (!q || !q.length) {
    panel.innerHTML = '<div class="empty">' +
      (q ? 'No claimable issues (no unassigned ready-for-agent / autonomous tickets).' :
        (state.queue_error ? 'Claim queue unavailable: ' + esc(state.queue_error) :
          'No supervisor state — queue repo unknown.')) + '</div>';
    return;
  }
  panel.innerHTML = '<div class="card"><ul class="tl" style="padding:8px 14px;">' + q.map(i =>
    '<li><span class="t-dot info"></span>' +
    '<span class="t-main"><span class="t-gate">#' + i.number + '</span> <span class="t-note" style="display:inline">' + esc(i.title) + '</span></span></li>'
  ).join('') + '</ul></div>';
}

function gateSegs(gates){
  if (!gates || !gates.length) return '';
  return '<div class="gates">' + gates.map(g =>
    '<span class="gate-seg ' + esc(g.state) + '" title="' + esc(g.name) + ': ' + esc(g.state) + '"></span>'
  ).join('') + '</div>';
}

function cardHtml(s){
  const IC = LEVELS[s.level] || LEVELS.muted;
  const exp = expanded.has(s.id);
  const chips = [];
  if (s.attempts !== null && s.attempts !== undefined) chips.push('attempts ' + esc(s.attempts) + '/' + esc(s.max_retries ?? '?'));
  if (s.confidence !== null && s.confidence !== undefined) chips.push('confidence ' + Math.round(s.confidence * 100) + '%');
  if (s.model) chips.push('model ' + esc(s.model));
  if (s.harness) chips.push(esc(s.harness));
  if (s.current_step) chips.push('step ' + esc(s.current_step) + (s.next_gate ? ' → ' + esc(s.next_gate) : ''));
  chips.push('updated ' + fmtAge(s.age_sec) + ' ago');
  const staleChip = s.stale ? '<span class="chip stale">⚠ stale (&gt; ttl)</span>' : '';
  const halt = s.halt_reason ? '<div class="halt">⛔ ' + esc(s.halt_reason) + '</div>' : '';
  const res = s.result ? '<div class="result-box"><b>' + esc(s.result.outcome) + '</b>' +
    (s.result.confidence !== null && s.result.confidence !== undefined ? ' · ' + Math.round(s.result.confidence*100) + '% confidence' : '') +
    (s.result.summary ? ' · ' + esc(s.result.summary) : '') + '</div>' : '';
  const perr = s.parse_error ? '<div class="err-box">unreadable pipeline-state: ' + esc(s.parse_error) + '</div>' : '';
  const acts = s.agent_logs && s.agent_logs.length ? s.agent_logs.map(l =>
    '<li><span class="t-dot ' + (/^pass/i.test(l.status||'') ? 'pass' : (/^fail/i.test(l.status||'') ? 'fail' : (l.status ? 'info':'other'))) + '"></span>' +
    '<span class="t-main"><span class="t-gate">' + esc(l.gate || '') + '</span>' +
    (l.agent ? ' <span class="t-agent">' + esc(l.agent) + '</span>' : '') +
    '<div class="t-note">' + esc(l.note || '') + '</div></span>' +
    '<span class="t-ts">' + fmtTs(l.ts) + '</span></li>'
  ).join('') : '<div style="color:var(--muted);font-size:12px;">No agent activity recorded yet.</div>';
  const actions = [];
  if (s.issue_url) actions.push('<a href="' + esc(s.issue_url) + '" target="_blank">issue</a>');
  if (s.pr_url) actions.push('<a href="' + esc(s.pr_url) + '" target="_blank">PR</a>');
  if (s.report_path) actions.push('<a href="file:///' + esc(s.report_path.replace(/\\/g,'/')) + '" target="_blank">report</a>');
  return '<div class="card level-' + esc(s.level) + '">' +
    '<div class="card-head" onclick="toggleCard(\'' + esc(s.id) + '\')">' +
      '<span class="badge ' + esc(s.level) + '">' + IC[0] + ' ' + esc(s.status_label) + '</span>' +
      '<span class="num">' + (s.issue_number ? '#' + s.issue_number : esc(s.id)) + '</span>' +
      '<span class="title" title="' + esc(s.title) + '">' + esc(s.title) + '</span>' +
      (s.repo ? '<span class="repo">' + esc(s.repo) + '</span>' : '') +
      '<span class="chev ' + (exp ? 'open' : '') + '">▸</span>' +
    '</div>' +
    '<div class="card-body' + (exp ? ' show' : '') + '">' +
      gateSegs(s.gates) +
      '<div class="chips">' + chips.join('') + staleChip + '</div>' +
      (actions.length ? '<div class="actions">' + actions.join('') + '</div>' : '') +
      halt + res + perr +
      '<div class="activities"><div class="section-title" style="margin-top:4px;">Activities</div><ul class="tl">' + acts + '</ul></div>' +
      (s.raw ? '<details class="rawbox"><summary>raw pipeline-state</summary><pre>' + esc(s.raw) + '</pre></details>' : '') +
    '</div></div>';
}

function toggleCard(id){
  if (expanded.has(id)) expanded.delete(id); else expanded.add(id);
  render();
}

// wire controls
$('#btn-pause').onclick = () => { paused = !paused; $('#btn-pause').textContent = paused ? '▶' : '⏸'; };
$('#btn-refresh').onclick = async () => { try { state = await fetchState(); render(); } catch(e){} };
$('#status-filter').onchange = render;
$('#search').oninput = render;
$('#log-filter').oninput = render;
$('#log-autoscroll').onchange = render;
document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });

// initial paint + polling
render();
if (location.protocol !== 'file:') {
  setInterval(tick, Math.max(2, state.refresh || 5) * 1000);
}
</script>
</body>
</html>
'@

# ---------------------------------------------------------------
# Render / emit
# ---------------------------------------------------------------
function New-Page {
    param($State, [string]$OutPath)
    $json = $State | ConvertTo-Json -Depth 12 -Compress
    $json = $json.Replace('</', '<\/')   # safe inside <script>
    $html = $script:Template.
        Replace('__INITIAL_STATE__', $json).
        Replace('__REFRESH__', "$($State.refresh)")
    Set-Content -LiteralPath $OutPath -Value $html -Encoding utf8
    $jsonPath = [System.IO.Path]::ChangeExtension($OutPath, '.json')
    Set-Content -LiteralPath $jsonPath -Value $json -Encoding utf8
    return $jsonPath
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $DataDir)) {
    Write-Error "DataDir not found: $DataDir"
    exit 2
}

if ($Once) {
    if (-not $OutFile) { $OutFile = Join-Path $DataDir 'monitor.html' }
    $state = Collect-State -DataDir $DataDir -Refresh $Refresh -LogLines $LogLines
    $jsonPath = New-Page -State $state -OutPath $OutFile
    Write-Host "Autonomad Monitor snapshot written:"
    Write-Host "  HTML : $OutFile"
    Write-Host "  JSON : $jsonPath"
    Write-Host "  Status: $($state.overall.status) | sessions: $($state.sessions.Count)"
    exit 0
}

# ---- serve mode ----
$state = Collect-State -DataDir $DataDir -Refresh $Refresh -LogLines $LogLines
$pageHtml = $null
{ $json = $state | ConvertTo-Json -Depth 12 -Compress; $json = $json.Replace('</', '<\/'); $pageHtml = $script:Template.Replace('__INITIAL_STATE__', $json).Replace('__REFRESH__', "$Refresh") } | Out-Null

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    # port busy — walk up to +10
    $ok = $false
    for ($i = 1; $i -le 10; $i++) {
        $p = $Port + $i
        $l2 = [System.Net.HttpListener]::new()
        $l2.Prefixes.Add("http://127.0.0.1:$p/")
        try { $l2.Start(); $listener = $l2; $Port = $p; $ok = $true; break } catch { }
    }
    if (-not $ok) { Write-Error "Could not bind any port from $Port to $($Port+10). Is another monitor running?"; exit 3 }
}

$url = "http://127.0.0.1:$Port/"
Write-Host "Autonomad Monitor: $url (refresh ${Refresh}s, live)"
Write-Host "  Ctrl+C to stop. Read-only — never touches the pipeline."
if ($Open -or -not $NoOpen) {
    try { Start-Process $url } catch { }
}

$script:StopRequested = $false
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action { $script:StopRequested = $true }

function Send-Response {
    param($Context, [string]$Body, [string]$ContentType)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

while (-not $script:StopRequested) {
    try {
        $ctx = $listener.GetContext()
    } catch {
        if ($script:StopRequested) { break }
        Start-Sleep -Milliseconds 200
        continue
    }
    $path = $ctx.Request.Url.AbsolutePath
    try {
        if ($path -eq '/api/state') {
            $fresh = Collect-State -DataDir $DataDir -Refresh $Refresh -LogLines $LogLines
            $json = $fresh | ConvertTo-Json -Depth 12 -Compress
            Send-Response -Context $ctx -Body $json -ContentType 'application/json; charset=utf-8'
        } elseif ($path -eq '/' -or $path -eq '/index.html') {
            $fresh = Collect-State -DataDir $DataDir -Refresh $Refresh -LogLines $LogLines
            $j = $fresh | ConvertTo-Json -Depth 12 -Compress; $j = $j.Replace('</', '<\/')
            $html = $script:Template.Replace('__INITIAL_STATE__', $j).Replace('__REFRESH__', "$Refresh")
            Send-Response -Context $ctx -Body $html -ContentType 'text/html; charset=utf-8'
        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.OutputStream.Close()
        }
    } catch {
        try { $ctx.Response.StatusCode = 500; $ctx.Response.OutputStream.Close() } catch { }
    }
}

$listener.Stop()
Write-Host "`nMonitor stopped."
