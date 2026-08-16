# Autonomad supervisor (issue #19) — always-on watcher
#
# Runs as a SEPARATE headless process (started by the /autonomad skill or
# manually). Responsibilities:
#   1. Watch Docker (hysteresis: 3 consecutive failed checks before declaring
#      docker down; recovers on the first successful check).
#   2. Spawn + supervise the tick loop while docker is up; restart it with
#      exponential-ish backoff and a restart cap per window.
#   3. Schedule the GATED claim reconciliation (`tick.ps1 -ReconcileOnce`) —
#      which self-gates on quiet + attention, so the supervisor never needs to
#      re-implement the trigger logic.
#   4. Write supervisor-state.json every cycle (read by the monitor).
#
# Usage:
#   pwsh -NoProfile -WindowStyle Hidden -File src/supervisor.ps1 [-DataDir x] [-RepoRoot y]
#   Ctrl+C / SIGTERM stops the tick child and exits gracefully.

[CmdletBinding()]
param(
    [string]$DataDir = '',
    [string]$RepoRoot = '',
    [int]$PollSeconds = 15,
    [int]$ReconcileInterval = 0,     # 0 = use repo.config reconcile_interval
    [int]$MaxRestarts = 5,
    [int]$RestartWindowMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent $PSScriptRoot }
if (-not $DataDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $DataDir = if ($envData) { $envData } else { $script:RepoRoot }
}
$script:DataDir = $DataDir
$script:LogsDir = Join-Path $DataDir 'logs'
foreach ($d in @($DataDir, $script:LogsDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

. (Join-Path $script:RepoRoot 'src\Config.ps1')
$script:ConfigPath = Join-Path $script:RepoRoot 'repo.config'
$Config = Read-RepoConfig -ConfigPath $script:ConfigPath

$script:StateFile = Join-Path $DataDir 'supervisor-state.json'
$script:LogFile = Join-Path $script:LogsDir 'supervisor.log'
$script:BrainRoot = [System.Environment]::GetEnvironmentVariable('AIOS_BRAIN_PATH')
$script:ReconcileInterval = if ($ReconcileInterval -gt 0) { $ReconcileInterval } else { [int]$Config['reconcile_interval'] }
$script:PollSeconds = [math]::Max(5, $PollSeconds)
$script:MaxRestarts = $MaxRestarts
$script:RestartWindowMs = $RestartWindowMinutes * 60000

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

function Get-SupervisorState {
    $state = [ordered]@{
        pid                   = $PID
        started_at            = $script:StartedAt
        updated_at            = (Get-Date).ToUniversalTime().ToString('o')
        repo                  = $Config['repo']
        harness               = $Config['harness']
        data_dir              = $script:DataDir
        reconcile_log         = (Join-Path $script:DataDir 'reconciliation.log')
        docker_up             = $script:DockerUp
        docker_checks_down    = $script:DownStreak
        tick_pid              = $null
        tick_started_at       = $null
        tick_status           = 'not-started'
        restarts_in_window    = $script:Restarts
        last_tick_exit_at     = $null
        last_reconcile_at     = $null
        last_reconcile_result = ''
        gh_auth               = $null
        last_error            = $null
    }
    if ($null -ne $script:Tick) {
        $state.tick_pid = $script:Tick.pid
        $state.tick_started_at = $script:Tick.startedAt
        $state.tick_status = if ($script:TickStopped) { 'stopped' } else { 'running' }
    }
    if ($null -ne $script:LastTickExit) { $state.last_tick_exit_at = $script:LastTickExit.ToString('o') }
    if ($null -ne $script:LastReconcile) { $state.last_reconcile_at = $script:LastReconcile.ToString('o') }
    if (-not [string]::IsNullOrWhiteSpace($script:ReconcileResult)) { $state.last_reconcile_result = $script:ReconcileResult }
    if ($null -ne $script:GhAuth) { $state.gh_auth = $script:GhAuth }
    if ($null -ne $script:LastError) { $state.last_error = $script:LastError }
    return $state
}

function Write-SupervisorState {
    try {
        $json = Get-SupervisorState | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($script:StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Log "State write failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

function Test-DockerUp {
    try {
        & docker info 1> $null 2> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-TickAlive {
    if ($null -eq $script:Tick) { return $false }
    try {
        $p = Get-Process -Id $script:Tick.pid -ErrorAction Stop
        return $null -ne $p
    } catch {
        return $false
    }
}

function Start-TickLoop {
    $tickScript = Join-Path $script:RepoRoot 'src\tick.ps1'
    if (-not (Test-Path -LiteralPath $tickScript)) {
        Write-Log "tick.ps1 not found at $tickScript — cannot start tick loop" -Level 'ERROR'
        return $null
    }
    $out = Join-Path $script:LogsDir 'supervisor-tick-out.log'
    $err = Join-Path $script:LogsDir 'supervisor-tick-err.log'
    $args = @('-NoProfile', '-File', $tickScript, '-DataDir', $script:DataDir)
    if (-not [string]::IsNullOrWhiteSpace($script:BrainRoot)) {
        $args += @('-BrainRoot', $script:BrainRoot)
    }
    try {
        $p = Start-Process -FilePath 'pwsh' -ArgumentList $args -WindowStyle Hidden `
            -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        Write-Log "Tick loop started pid=$($p.Id)"
        return [pscustomobject]@{ pid = $p.Id; startedAt = (Get-Date).ToUniversalTime() }
    } catch {
        Write-Log "Failed to start tick loop: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Stop-TickLoop {
    if ($null -eq $script:Tick) { return }
    try {
        $p = Get-Process -Id $script:Tick.pid -ErrorAction Stop
        if ($null -ne $p) {
            Write-Log "Stopping tick loop pid=$($script:Tick.pid)"
            Stop-Process -Id $script:Tick.pid -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    $script:Tick = $null
    $script:TickStopped = $true
}

function Invoke-ReconcileOnce {
    $tickScript = Join-Path $script:RepoRoot 'src\tick.ps1'
    if (-not (Test-Path -LiteralPath $tickScript)) { return 'missing tick.ps1' }
    $args = @('-NoProfile', '-File', $tickScript, '-DataDir', $script:DataDir, '-ReconcileOnce')
    if (-not [string]::IsNullOrWhiteSpace($script:BrainRoot)) {
        $args += @('-BrainRoot', $script:BrainRoot)
    }
    try {
        $out = & pwsh @args 2>&1 | Out-String
        # Summarize the tail so state stays small.
        $tail = ($out -split "`r?`n" | Where-Object { $_ -match 'RECONCILE|Reconcile' } | Select-Object -Last 3) -join ' | '
        if (-not $tail) { $tail = ($out -split "`r?`n" | Select-Object -Last 1) }
        return $tail.Trim()
    } catch {
        Write-Log "ReconcileOnce failed: $($_.Exception.Message)" -Level 'WARN'
        return "error: $($_.Exception.Message)"
    }
}

function Test-GhAuth {
    try {
        & gh auth status 1> $null 2> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---- init ----
$script:StartedAt = (Get-Date).ToUniversalTime().ToString('o')
$script:DockerUp = $false
$script:DownStreak = 0
$script:Tick = $null
$script:TickStopped = $false
$script:Restarts = 0
$script:LastTickExit = $null
$script:LastReconcile = $null
$script:ReconcileResult = ''
$script:GhAuth = Test-GhAuth
$script:LastError = $null

$script:StopRequested = $false
$null = Register-ObjectEvent -InputObject ([System.Console]) -EventName CancelKeyPress -Action { $script:StopRequested = $true }

Write-Log "Autonomad supervisor starting (repo=$($Config['repo']), data=$DataDir, poll=${PollSeconds}s, reconcile=$($script:ReconcileInterval)s)"
Write-Log "Brain root: $(if ($script:BrainRoot) { $script:BrainRoot } else { '<unset>' })"
Write-Log "gh auth: $script:GhAuth"

# ---- main loop ----
while (-not $script:StopRequested) {
    $dockerOk = Test-DockerUp
    if ($dockerOk) {
        if (-not $script:DockerUp) { Write-Log 'docker UP' }
        $script:DockerUp = $true
        $script:DownStreak = 0
    } else {
        $script:DownStreak++
        if ($script:DockerUp -and $script:DownStreak -ge 3) {
            Write-Log 'docker DOWN (3 consecutive failed checks)'
            $script:DockerUp = $false
        }
    }

    try {
        if ($script:DockerUp) {
            # Tick loop management.
            if ($script:Tick -and (Test-TickAlive)) {
                # Alive: reset the restart budget once it survives a full window.
                if (($null -ne $script:Tick.startedAt) -and
                    (((Get-Date).ToUniversalTime() - $script:Tick.startedAt).TotalMilliseconds -gt $script:RestartWindowMs)) {
                    $script:Restarts = 0
                }
            } else {
                if ($null -ne $script:Tick) {
                    $script:LastTickExit = Get-Date
                    $script:Restarts++
                    Write-Log "Tick loop exited; restarts=$($script:Restarts)/$($script:MaxRestarts) in window"
                }
                if ($script:Restarts -gt $script:MaxRestarts) {
                    Write-Log "Restart cap hit ($($script:MaxRestarts) in $($script:RestartWindowMs/60000) min) — waiting for a fresh window" -Level 'WARN'
                    $script:Tick = $null
                    $script:TickStopped = $true
                    $script:LastError = "restart cap: $($script:Restarts) restarts in window"
                    Write-SupervisorState
                    Start-Sleep -Seconds $script:RestartWindowMs
                    $script:Restarts = 0
                    $script:LastError = $null
                    continue
                }
                $script:Tick = Start-TickLoop
                $script:TickStopped = ($null -eq $script:Tick)
                if ($null -eq $script:Tick) { $script:LastError = 'tick spawn failed' }
            }
        } else {
            # Docker down: stop the tick loop so it cannot run half-dead.
            if ($null -ne $script:Tick) {
                Stop-TickLoop
                Write-Log 'Tick loop stopped (docker down)'
            }
            $script:TickStopped = $null -eq $script:Tick
        }

        # Gated reconciliation on a schedule (self-gates on quiet + attention).
        if ($null -eq $script:LastReconcile -or
            ((Get-Date).ToUniversalTime() - $script:LastReconcile).TotalSeconds -ge $script:ReconcileInterval) {
            $script:LastReconcile = Get-Date
            $script:ReconcileResult = Invoke-ReconcileOnce
            Write-Log "Reconcile pass done: $($script:ReconcileResult)"
        }

        # gh auth health (cheap enough once per cycle; failures tolerated).
        $script:GhAuth = Test-GhAuth

        Write-SupervisorState
    } catch {
        $script:LastError = $_.Exception.Message
        Write-Log "Supervisor cycle error: $($_.Exception.Message)" -Level 'ERROR'
        Write-SupervisorState
    }

    Start-Sleep -Seconds $script:PollSeconds
}

# graceful shutdown
if ($null -ne $script:Tick) { Stop-TickLoop }
$script:LastError = 'supervisor stopped'
Write-SupervisorState
Write-Log 'Autonomad supervisor stopped.'
