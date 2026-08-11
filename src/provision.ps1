# Autonomad v1 — src/provision.ps1
#
# Sandbox provisioning (T3): builds and runs one isolated dev container per
# claimed issue.
#
#   - AIOS brain mounted READ-ONLY at CORRECTED paths:
#       <brain>/graphify-out  -> /brain/graphify-out
#       <brain>/context       -> /brain/context
#       <brain>/references    -> /brain/references
#       <brain>/decisions     -> /brain/decisions
#       <brain>/.github/skills -> /brain/skills     (CORRECTED: under .github/)
#       <brain>/.github/agents -> /brain/agents     (CORRECTED: under .github/)
#   - marketplace wired via skills.paths (env OPENCODE_SKILLS_PATH + /brain/skills)
#   - .env injected via --env-file
#   - workspace (issue branch) mounted read-write at /workspace
#
# Supports AUTONOMAD_SANDBOX_MODE:
#   docker  (default) — run the real container via docker run
#   mock    — invoke a mock dev-agent script (no docker) for dry-run E2E
#
# Dot-source this file:  . "$PSScriptRoot/provision.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Build the list of docker -v mounts for the AIOS brain (read-only, corrected paths).
  Returns string[] of "source:target:ro" mount specs.
#>
function Get-BrainMounts {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [hashtable]$Config
    )
    $requested = ConvertFrom-BrainPaths $Config['brain_paths']
    $resolved = Resolve-BrainPaths -BrainRoot $BrainRoot -Requested $requested
    $mounts = @()
    foreach ($name in $resolved.Keys) {
        $src = $resolved[$name]
        $mounts += "${src}:/brain/${name}:ro"
    }
    return $mounts
}

<#
.SYNOPSIS
  Build a docker run command (as string[]) for one issue's dev sandbox.
#>
function New-SandboxCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [string]$BrainRoot,
        [string]$EnvFile,
        [string]$DataDir = '',
        [string]$Image = '',
        [string]$Adapter = '',
        [string]$ContainerName = ''
    )
    if ([string]::IsNullOrWhiteSpace($Image)) {
        $Image = [System.Environment]::GetEnvironmentVariable('SANDBOX_IMAGE')
    }
    if ([string]::IsNullOrWhiteSpace($Image)) { $Image = 'autonomad:v1' }

    if ([string]::IsNullOrWhiteSpace($Adapter)) {
        $Adapter = $Config['harness']  # adapter name from repo.config
    }
    # Adapters live at /opt/autonomad/adapters/<harness>.sh inside the image.
    $adapterPath = "/opt/autonomad/adapters/$Adapter.sh"

    # Named container (NOT --rm) so the watchdog can `docker logs` it live and a
    # human can tail the agent's progress from another terminal. Cleaned up in
    # Invoke-Sandbox via `docker rm -f`.
    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        $ContainerName = "autonomad-sandbox-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }
    $cmd = @('docker', 'run', '-d', '--name', $ContainerName)
    # Workspace (issue branch) read-write.
    $cmd += @('-v', "${Workspace}:/workspace")
    # Shared learning store (autonomad-data/learnings) read-write so the dev agent
    # can READ prior repo context and APPEND per-session learnings live. The tick
    # loop ingests the session files into learning.db after the run.
    if (-not [string]::IsNullOrWhiteSpace($DataDir)) {
        $learningsHost = Join-Path $DataDir 'learnings'
        if (-not (Test-Path -LiteralPath $learningsHost)) {
            New-Item -ItemType Directory -Path $learningsHost -Force | Out-Null
        }
        $cmd += @('-v', "${learningsHost}:/learnings")
        $cmd += @('-e', 'AUTONOMAD_LEARNINGS=/learnings')
    }
    # AIOS brain read-only at corrected paths.
    $brainMounts = Get-BrainMounts -BrainRoot $BrainRoot -Config $Config
    foreach ($m in $brainMounts) { $cmd += @('-v', $m) }
    # Adapters + marketplace come from the host working tree, NOT the baked image
    # copies, so code changes take effect without an image rebuild (A1: agents are
    # registered at runtime inside the adapter). The repo root is derived from the
    # tick script location; fall back to env SANDBOX_SRC when not under a repo.
    $hostSrc = Split-Path -Parent $PSScriptRoot   # <repo>/src -> <repo>
    $hasHostSrc = (Test-Path -LiteralPath (Join-Path $hostSrc 'adapters')) -and (Test-Path -LiteralPath (Join-Path $hostSrc 'marketplace'))
    if ($hasHostSrc) {
        $cmd += @('-v', "$hostSrc/adapters:/opt/autonomad/adapters")
        $cmd += @('-v', "$hostSrc/marketplace:/opt/autonomad/marketplace")
    } elseif (-not [string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable('SANDBOX_SRC'))) {
        $hostSrc = [System.Environment]::GetEnvironmentVariable('SANDBOX_SRC')
        $cmd += @('-v', "$hostSrc/adapters:/opt/autonomad/adapters")
        $cmd += @('-v', "$hostSrc/marketplace:/opt/autonomad/marketplace")
    } else {
        Write-Warning "New-SandboxCommand: host adapters/marketplace not found under $hostSrc — sandbox will use baked image copies."
    }
    # .env injected (model keys, GH_TOKEN for the sandbox).
    if (-not [string]::IsNullOrWhiteSpace($EnvFile) -and (Test-Path -LiteralPath $EnvFile)) {
        $cmd += @('--env-file', $EnvFile)
    }
    # Git identity for the dev agent's commits (the dev agent commits pipeline
    # state + work directly inside the sandbox; without author identity every
    # `git commit` fails with "Author identity unknown").
    $gitName = if ($Config.Contains('bot_login') -and -not [string]::IsNullOrWhiteSpace($Config['bot_login'])) { $Config['bot_login'] } else { 'autonomad-bot' }
    $gitEmail = "$gitName@users.noreply.github.com"
    $cmd += @('-e', "GIT_AUTHOR_NAME=$gitName", '-e', "GIT_AUTHOR_EMAIL=$gitEmail")
    $cmd += @('-e', "GIT_COMMITTER_NAME=$gitName", '-e', "GIT_COMMITTER_EMAIL=$gitEmail")
    # Marketplace wiring via skills.paths.
    $cmd += @('-e', 'OPENCODE_SKILLS_PATH=/opt/autonomad/marketplace')
    $cmd += @('-e', 'AIOS_BRAIN=/brain')
    # Sandbox knows which gates to honor.
    $cmd += @('-e', "AUTONOMAD_REPO=$($Config['repo'])")
    # Model override (repo.config Q14) reaches the harness adapter as an env var.
    # Adapter mapping (documented in each adapters/*.sh):
    #   opencode -> OPENCODE_MODEL   (consumed by adapters/opencode.sh run-agent)
    #   claude   -> CLAUDE_MODEL     (consumed by claude.sh when implemented)
    #   copilot  -> COPILOT_MODEL    (consumed by copilot.sh when implemented)
    # `-e` is emitted after `--env-file` so repo.config wins over .env.
    if ($Config.Contains('model') -and -not [string]::IsNullOrWhiteSpace($Config['model'])) {
        $modelEnv = switch ($Adapter) {
            'claude'   { 'CLAUDE_MODEL' }
            'copilot'  { 'COPILOT_MODEL' }
            default    { 'OPENCODE_MODEL' }
        }
        $cmd += @('-e', "$modelEnv=$($Config['model'])")
    }
    # Workdir + command: run the harness adapter headless.
    # IMPORTANT: the image ENTRYPOINT launches the tick loop, so the sandbox must
    # override it (`--entrypoint <adapter>`) or the dev agent never runs.
    $cmd += @('-w', '/workspace')
    $cmd += @('--entrypoint', $adapterPath)
    $cmd += @($Image)
    $cmd += @('run-agent', "/workspace/.autonomad/prompt.md")
    return $cmd
}

# ============================================================
# Real-time agent status (Fix 8)
# ============================================================
<#
.SYNOPSIS
  Poll the LIVE agent status for one sandbox and render a one-line status that
  CHANGES ONLY when the ticket gate or the agent's todo list changes. Sources:
    - todo table in the container's opencode.db (status/content per todo)
    - pipeline-state.json (current/next gate)
  Prints a fresh line per change (never per-poll), and writes the same line to
  <workspace>/.autonomad/status so it can be tailed externally. Returns a status
  hash so callers know whether anything changed.
#>
function Get-AgentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$State,
        [int]$ElapsedSeconds
    )
    $statusFile = Join-Path $Workspace '.autonomad' 'status'

    # --- ticket gate (pipeline-state) ---
    $gateLabel = '?'
    $gateProgress = ''
    $doneCount = 0
    $total = 0
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $ps = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($ps.next_gate) {
                $gateLabel = $ps.next_gate
                $doneCount = @($ps.completed | Where-Object { $_ -ne '' }).Count
                $total = $doneCount + @($ps.pending | Where-Object { $_ -ne '' }).Count
                if ($total -gt 0) { $gateProgress = " $doneCount/$total" }
            }
        } catch { }
    }

    # --- todo list (container opencode.db) ---
    $todoText = ''
    $todoCount = '0/0'
    $todoDone = 0
    $todoJson = $null
    try {
        $todoJson = & docker exec $ContainerName sqlite3 -json /root/.local/share/opencode/opencode.db `
            "SELECT status,position,content FROM todo WHERE session_id=(SELECT id FROM session ORDER BY time_created DESC LIMIT 1) ORDER BY position" 2>$null
    } catch { $todoJson = $null }
    if ($todoJson) {
        try {
            $todos = @($todoJson | ConvertFrom-Json)
            $total = [Math]::Max($total, $todos.Count)
            $todoDone = @($todos | Where-Object { $_.status -eq 'completed' }).Count
            $todoCount = "$todoDone/$($todos.Count)"
            $active = $todos | Where-Object { $_.status -eq 'in_progress' } | Select-Object -First 1
            if ($active -and $active.content) {
                $short = [string]$active.content
                if ($short.Length -gt 45) { $short = $short.Substring(0, 42) + '...' }
                $todoText = " `"$short`""
            }
        } catch { }
    }

    # --- render ---
    $issueRef = $State.issue_ref
    $mins = [math]::Round($ElapsedSeconds / 60, 1)
    $line = "[$issueRef] gate$gateProgress ($gateLabel) | todo $todoCount$todoText | ${mins}m"
    $autoDir = Join-Path $Workspace '.autonomad'
    if (-not (Test-Path -LiteralPath $autoDir)) { New-Item -ItemType Directory -Path $autoDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($statusFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))

    # Hash the CHANGE-SIGNAL (gate + todo statuses + active content) so callers
    # can print only when it actually changes.
    $signal = "$gateLabel|$($doneCount + $todoDone)|$total|$todoText"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($signal)
    return @{ Line = $line; Hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
}

<#
.SYNOPSIS
  Invoke the sandbox for an issue. Returns $LASTEXITCODE-equivalent result object.
  Docker mode: runs `docker run` and WATCHES it — logs a heartbeat each poll, and
  re-evaluates when the container makes no progress beyond progress_threshold.
  Mock mode: runs the mock dev-agent script.
#>
function Invoke-Sandbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [string]$EnvFile = '',
        [string]$BrainRoot = ''
    )
    # Write the assembled prompt to the workspace so the adapter can read it
    # regardless of size (adapter contract accepts a file path OR inline text).
    $autoDir = Join-Path $Workspace '.autonomad'
    if (-not (Test-Path -LiteralPath $autoDir)) { New-Item -ItemType Directory -Path $autoDir -Force | Out-Null }
    $promptFile = Join-Path $autoDir 'prompt.md'
    [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding($false)))

    $mode = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_SANDBOX_MODE')
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'docker' }

    if ($mode -eq 'mock') {
        return Invoke-MockSandbox -Config $Config -State $State -Workspace $Workspace -Prompt $Prompt -DataDir $DataDir
    }

    # --- docker mode ---
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Sandbox provisioning failed: docker CLI not found (set AUTONOMAD_SANDBOX_MODE=mock to dry-run)."
    }
    $cmd = New-SandboxCommand -Config $Config -Workspace $Workspace -PromptFile $promptFile `
        -BrainRoot $BrainRoot -EnvFile $EnvFile -DataDir $DataDir -ContainerName "autonomad-sandbox-$($State.issue_ref)"
    $containerName = "autonomad-sandbox-$($State.issue_ref)"
    Write-Host "SANDBOX: docker run -d --name $containerName (workspace=$Workspace, brain=$BrainRoot)"

    $watchPoll = [int]($Config['watch_poll'] ?? 15)
    $progressThreshold = [int]($Config['progress_threshold'] ?? 60)
    $stallKillSeconds = [int]($Config['stall_kill'] ?? 900)
    $hardTimeout = [int]($Config['sandbox_timeout'] ?? 1800)

    # --- launch the container detached (named, kept for docker logs) ---
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd[0]
    # ProcessStartInfo.Arguments is a single string — quote any arg containing
    # spaces (e.g. brain mounts "C:\GitRepos\AI Docs\context:/brain/context:ro")
    # so docker still sees them as one token.
    $psi.Arguments = ($cmd[1..($cmd.Length - 1)] | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in [System.Environment]::GetEnvironmentVariables().Keys) {
        if (-not $psi.Environment.ContainsKey($k)) { $psi.Environment[$k] = [System.Environment]::GetEnvironmentVariable($k) }
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    # `docker run -d` returns immediately with the container ID on stdout.
    $proc.WaitForExit()
    $runExit = $proc.ExitCode
    if ($runExit -ne 0) {
        $errText = try { $errTask.Result } catch { '' }
        $proc.Dispose()
        throw "docker run failed (exit $runExit): $errText"
    }
    Write-Host "SANDBOX: container $containerName started"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgress = (Get-Date).ToUniversalTime()
    $stalledPolls = 0
    $statePath = Join-Path $Workspace 'pipeline-state.json'
    $procKilled = $false
    $killReason = $null
    $lastGitHead = $null
    $lastLogLen = 0
    $lastStatusHash = $null

    try {
        while ($true) {
            Start-Sleep -Seconds $watchPoll
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 0)

            # LIVE PROGRESS: a growing `docker logs` is itself progress — the agent
            # is emitting commands even between pipeline-state commits. The raw log
            # is NOT echoed to the console (too noisy); instead the compact status
            # line below updates only when the ticket gate or todo list changes.
            $logGrew = $false
            $logs = & docker logs --tail $([int]1e9) $containerName 2>&1 | Out-String
            if ($logs) {
                $logLines = @($logs -split "`n" | Where-Object { $_ -ne '' })
                if ($logLines.Count -gt $lastLogLen) {
                    $logGrew = $true
                    $lastLogLen = $logLines.Count
                }
            }

            # Real-time status: render only when gate/todo actually changed, write
            # to .autonomad/status, and print a fresh line per change.
            $status = Get-AgentStatus -ContainerName $containerName -Workspace $Workspace `
                -StatePath $statePath -State $State -ElapsedSeconds $elapsed
            if ($status.Hash -ne $lastStatusHash) {
                Write-Host "STATUS: $($status.Line)"
                $lastStatusHash = $status.Hash
            }

            # Heartbeat + progress probe. Progress is EITHER:
            #   - pipeline-state.json updated_at newer than the last poll (the dev
            #     agent writes state after each gate), OR
            #   - a new git commit in the workspace (agent commits work between gates).
            $stateUpdated = $null
            if (Test-Path -LiteralPath $statePath) {
                try {
                    $tmp = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                    if ($tmp.updated_at) { $stateUpdated = [datetime]::Parse($tmp.updated_at).ToUniversalTime() }
                } catch { $stateUpdated = $null }
            }
            $gitHead = $null
            try {
                Push-Location $Workspace
                $gitHead = git rev-parse HEAD 2>$null
            } catch { $gitHead = $null } finally { Pop-Location }
            if ($stateUpdated -and $stateUpdated -gt $lastProgress) {
                $lastProgress = $stateUpdated
                $stalledPolls = 0
            }
            if ($gitHead -and $gitHead -ne $lastGitHead) {
                $lastGitHead = $gitHead
                $lastProgress = (Get-Date).ToUniversalTime()
                $stalledPolls = 0
            }
            if ($logGrew) {
                $lastProgress = (Get-Date).ToUniversalTime()
                $stalledPolls = 0
            }

            # Is the container still alive?
            $state = (& docker inspect -f '{{.State.Running}}' $containerName 2>$null).Trim()
            if ($state -eq 'false' -or $LASTEXITCODE -ne 0) {
                Write-Host "SANDBOX: container $containerName exited"
                break
            }

            $curGate = '?'
            if (Test-Path -LiteralPath $statePath) {
                try {
                    $live = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                    if ($live.next_gate) { $curGate = $live.next_gate }
                } catch { $curGate = '?' }
            }
            $model = if ($Config.Contains('model')) { $Config['model'] } else { '<default>' }
            $idleSec = [math]::Round(((Get-Date).ToUniversalTime() - $lastProgress).TotalSeconds, 0)
            Write-Host "SANDBOX: running (elapsed=${elapsed}s, gate=$curGate, model=$model, last_progress=${idleSec}s ago, log_lines=$lastLogLen)"

            # Re-evaluate at the short threshold: warn only on the FIRST crossing
            # (free-tier LLM calls legitimately take 30-60s each, so a single slow
            # round-trip is NOT a stall). Only KILL after stall_kill of no progress.
            if ($idleSec -gt $progressThreshold -and $stalledPolls -eq 0) {
                $stalledPolls = 1
                Write-Host "SANDBOX: WARN — no progress for ${idleSec}s (re-evaluate threshold ${progressThreshold}s); will KILL at ${stallKillSeconds}s of no progress."
            }
            if ($idleSec -gt $stallKillSeconds) {
                Write-Host "SANDBOX: KILL — no progress for >${stallKillSeconds}s (stall_kill); removing container (will retry)."
                $procKilled = $true
                $killReason = "no progress for >${stallKillSeconds}s (${idleSec}s observed)"
                & docker rm -f $containerName 2>&1 | Out-Null
                break
            }

            if ($elapsed -ge $hardTimeout) {
                Write-Host "SANDBOX: HARD TIMEOUT — ${elapsed}s >= sandbox_timeout ${hardTimeout}s; removing container."
                $procKilled = $true
                $killReason = "sandbox_timeout ${hardTimeout}s exceeded"
                & docker rm -f $containerName 2>&1 | Out-Null
                break
            }
        }

        # --- flush remaining logs + capture exit code before cleanup ---
        $logs = & docker logs --tail $([int]1e9) $containerName 2>&1 | Out-String
        if ($logs) {
            $logLines = @($logs -split "`n" | Where-Object { $_ -ne '' })
            if ($logLines.Count -gt $lastLogLen) {
                foreach ($l in $logLines[$lastLogLen..($logLines.Count - 1)]) {
                    Write-Host "  [agent] $l"
                }
            }
        }
        $exit = 0
        try {
            $exit = [int](& docker inspect -f '{{.State.ExitCode}}' $containerName 2>$null | Out-String).Trim()
        } catch { $exit = -1 }
        # Clean up the named container (kept alive only for docker logs during the run).
        & docker rm -f $containerName 2>&1 | Out-Null
        $sw.Stop()
        Write-Host "SANDBOX: exited with code $exit (elapsed $([math]::Round($sw.Elapsed.TotalSeconds,0))s)"
        return @{ exitcode = $exit; killed = $procKilled; kill_reason = $killReason }
    } finally {
        & docker rm -f $containerName 2>&1 | Out-Null
        $proc.Dispose()
    }
}

<#
.SYNOPSIS
  Mock sandbox: runs a mock dev-agent script instead of docker.
  AUTONOMAD_MOCK_SCRIPT (default: scripts/mock-dev-agent.ps1) writes a fake
  pipeline-state.json into the workspace simulating the dev agent's outcome.
#>
function Invoke-MockSandbox {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [object]$State,
        [string]$Workspace,
        [string]$Prompt,
        [string]$DataDir
    )
    $mockScript = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_MOCK_SCRIPT')
    if ([string]::IsNullOrWhiteSpace($mockScript)) {
        $mockScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts' 'mock-dev-agent.ps1'
    }
    if (-not (Test-Path -LiteralPath $mockScript)) {
        throw "Mock sandbox: AUTONOMAD_MOCK_SCRIPT not found at $mockScript"
    }
    Write-Host "SANDBOX(mock): $mockScript"
    & $mockScript -Workspace $Workspace -State $State -Config $Config
    return @{ exitcode = $LASTEXITCODE; killed = $false; kill_reason = $null }
}
