# Pester tests for adapters/copilot.sh (issue #35 — implement the T4 stub).
#
# The adapter is a bash script, so these tests shell out to a mocked `copilot`
# CLI (a small bash stub that records its argv) via Git Bash on Windows. Each
# test asserts the exact argv the adapter builds, the env passthrough, and the
# exit-code contract.
#
# NOTE: written for Pester 3.4 (old-style Describe/It; no BeforeAll).
# Run:   pwsh -NoProfile -Command "Invoke-Pester tests/CopilotAdapter.Tests.ps1"

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Adapter = Join-Path $script:RepoRoot 'adapters' 'copilot.sh'

# Git Bash (bash on Windows). Falls back to whatever `bash` resolves to (WSL,
# CI containers) when the standard install path is absent.
$script:Bash = if (Test-Path 'C:\Program Files\Git\bin\bash.exe') {
    'C:\Program Files\Git\bin\bash.exe'
} elseif (Test-Path 'C:\Program Files\Git\usr\bin\bash.exe') {
    'C:\Program Files\Git\usr\bin\bash.exe'
} else {
    'bash'
}

# Single-quoted here-strings only: bash content must stay verbatim (no $@ / $1
# expansion by PowerShell). Paths are threaded through env vars, never inlined.
$script:MockScript = @'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$MOCK_ARGV_LOG"
echo "mock copilot called"
exit "${MOCK_EXIT:-0}"
'@

<#
.SYNOPSIS
  Scaffold a temp dir containing a mock `copilot` executable that appends its
  full argv to argv.log and exits with MOCK_EXIT (default 0).
#>
function New-MockCopilotEnv {
    param([int]$ExitCode = 0)
    $tmp = Join-Path $env:TEMP ("copilot-adapter-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $bin = Join-Path $tmp 'copilot'
    Set-Content -LiteralPath $bin -Value $script:MockScript -Encoding ascii
    & $script:Bash -c "chmod +x '$($bin -replace "'", "''")'" 2>$null
    return @{ Dir = $tmp; Bin = $bin; ArgvLog = Join-Path $tmp 'argv.log' }
}

# A bash wrapper that (a) sets MOCK_ARGV_LOG + MOCK_EXIT, (b) optionally sets
# extra harness env, (c) invokes the real adapter's run-agent, (d) prints
# ADAPTER_EXIT=<code>. Env-only — no inline paths.
$script:RunWrapper = @'
#!/usr/bin/env bash
set -euo pipefail
# Prepend the mock bin dir so `command -v copilot` resolves to the mock, not a
# real globally-installed copilot CLI.
export PATH="$MOCK_BIN:$PATH"
export MOCK_ARGV_LOG="$MOCK_ARGV_LOG"
export MOCK_EXIT="${MOCK_EXIT:-0}"
export COPILOT_MODEL="${COPILOT_MODEL:-}"
export COPILOT_EFFORT="${COPILOT_EFFORT:-}"
bash "$ADAPTER_PATH" run-agent "$PROMPT_ARG" >"$OUT_LOG" 2>"$ERR_LOG"
code=$?
echo "ADAPTER_EXIT=$code"
cat "$ERR_LOG" >&2
exit "$code"
'@

$script:NoBinWrapper = @'
#!/usr/bin/env bash
set -euo pipefail
export MOCK_ARGV_LOG="$MOCK_ARGV_LOG"
export PATH="$EMPTY_BIN"
"$HARNESS_BASH" "$ADAPTER_PATH" run-agent 'probe' >"$OUT_LOG" 2>"$ERR_LOG"
echo "ADAPTER_EXIT=$?"
'@

$script:MkWrapper = @'
#!/usr/bin/env bash
set -euo pipefail
bash "$ADAPTER_PATH" load-marketplace >"$OUT_LOG" 2>"$ERR_LOG"
echo "ADAPTER_EXIT=$?"
'@

<#
.SYNOPSIS
  Run the real adapter's run-agent verb against the mock. Threads prompt/paths
  through env vars so the bash wrapper stays verbatim.
#>
function Invoke-CopilotAdapter {
    param(
        [string]$Prompt,
        [string]$PromptFile = '',
        [string]$MockExit = '0',
        [string]$CopilotModel = '',
        [string]$CopilotEffort = ''
    )
    $envSetup = New-MockCopilotEnv -ExitCode ([int]$MockExit)
    $arg = if ($PromptFile) { Get-Content -LiteralPath $PromptFile -Raw } else { $Prompt }
    $wrapper = Join-Path $envSetup.Dir 'run.sh'
    Set-Content -LiteralPath $wrapper -Value $script:RunWrapper -Encoding ascii

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Bash
    $psi.Arguments = "`"$wrapper`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['MOCK_ARGV_LOG'] = $envSetup.ArgvLog
    $psi.Environment['MOCK_EXIT'] = $MockExit
    $psi.Environment['ADAPTER_PATH'] = $script:Adapter
    $psi.Environment['PROMPT_ARG'] = $arg
    $psi.Environment['MOCK_BIN'] = $envSetup.Dir
    $psi.Environment['OUT_LOG'] = Join-Path $envSetup.Dir 'stdout.log'
    $psi.Environment['ERR_LOG'] = Join-Path $envSetup.Dir 'stderr.log'
    $psi.Environment['COPILOT_MODEL'] = $CopilotModel
    $psi.Environment['COPILOT_EFFORT'] = $CopilotEffort

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $proc.WaitForExit()
    $outText = $outTask.Result
    $exit = $proc.ExitCode
    $proc.Dispose()

    $errText = ''
    if (Test-Path -LiteralPath $psi.Environment['ERR_LOG']) {
        $errText = Get-Content -LiteralPath $psi.Environment['ERR_LOG'] -Raw
    }
    $outLog = ''
    if (Test-Path -LiteralPath $psi.Environment['OUT_LOG']) {
        $outLog = Get-Content -LiteralPath $psi.Environment['OUT_LOG'] -Raw
    }

    return @{
        Exit   = $exit
        Output = $outText
        Err    = $errText
        All    = ($outText + $errText + $outLog)
        Argv   = if (Test-Path -LiteralPath $envSetup.ArgvLog) { Get-Content -LiteralPath $envSetup.ArgvLog } else { @() }
        Dir    = $envSetup.Dir
    }
}

Describe 'adapters/copilot.sh run-agent' {
    It 'passes the prompt via -p and always adds --output-format json + --allow-all-tools' {
        $r = Invoke-CopilotAdapter -Prompt 'develop this issue'
        $r.Exit | Should Be 0
        $r.Argv -contains '-p' | Should Be $true
        $r.Argv -contains 'develop this issue' | Should Be $true
        $r.Argv -contains '--output-format' | Should Be $true
        $r.Argv -contains 'json' | Should Be $true
        $r.Argv -contains '--allow-all-tools' | Should Be $true
    }

    It 'passes COPILOT_MODEL and COPILOT_EFFORT through as --model / --effort' {
        $r = Invoke-CopilotAdapter -Prompt 'x' -CopilotModel 'claude-sonnet-4-5' -CopilotEffort 'high'
        $r.Exit | Should Be 0
        $r.Argv -contains '--model' | Should Be $true
        $r.Argv -contains 'claude-sonnet-4-5' | Should Be $true
        $r.Argv -contains '--effort' | Should Be $true
        $r.Argv -contains 'high' | Should Be $true
    }

    It 'omits --model/--effort when the env vars are unset (CLI defaults)' {
        $r = Invoke-CopilotAdapter -Prompt 'x'
        $r.Argv -contains '--model' | Should Be $false
        $r.Argv -contains '--effort' | Should Be $false
    }

    It 'reads the prompt from a file path argument' {
        $promptFile = Join-Path $env:TEMP ("copilot-prompt-" + [guid]::NewGuid().ToString('N') + '.md')
        Set-Content -LiteralPath $promptFile -Value 'file-sourced prompt' -Encoding ascii
        try {
            $r = Invoke-CopilotAdapter -PromptFile $promptFile
            $r.Exit | Should Be 0
            $r.Argv -contains 'file-sourced prompt' | Should Be $true
        } finally {
            Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'propagates the copilot exit code' {
        $r = Invoke-CopilotAdapter -Prompt 'x' -MockExit '3'
        $r.Exit | Should Be 3
    }

    It 'returns 1 with a clear error when the copilot CLI is missing' {
        $envSetup = New-MockCopilotEnv
        $wrapper = Join-Path $envSetup.Dir 'run-nobin.sh'
        Set-Content -LiteralPath $wrapper -Value $script:NoBinWrapper -Encoding ascii

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Bash
        $psi.Arguments = "`"$wrapper`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Environment['MOCK_ARGV_LOG'] = $envSetup.ArgvLog
        $psi.Environment['ADAPTER_PATH'] = $script:Adapter
        $psi.Environment['HARNESS_BASH'] = $script:Bash
        $psi.Environment['EMPTY_BIN'] = Join-Path $envSetup.Dir 'empty-bin'
        New-Item -ItemType Directory -Path (Join-Path $envSetup.Dir 'empty-bin') -Force | Out-Null
        $psi.Environment['OUT_LOG'] = Join-Path $envSetup.Dir 'stdout.log'
        $psi.Environment['ERR_LOG'] = Join-Path $envSetup.Dir 'stderr.log'

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $proc.WaitForExit()
        $outText = $outTask.Result
        $exit = $proc.ExitCode
        $proc.Dispose()

        $errText = ''
        if (Test-Path -LiteralPath $psi.Environment['ERR_LOG']) {
            $errText = Get-Content -LiteralPath $psi.Environment['ERR_LOG'] -Raw
        }
        $outLog = ''
        if (Test-Path -LiteralPath $psi.Environment['OUT_LOG']) {
            $outLog = Get-Content -LiteralPath $psi.Environment['OUT_LOG'] -Raw
        }
        $allText = $outText + $errText + $outLog

        $allText | Should Match 'copilot CLI not found'
        $exit | Should Be 1
    }

    It 'returns 1 with a clear error on an empty prompt' {
        $r = Invoke-CopilotAdapter -Prompt ''
        $r.Exit | Should Be 1
        $r.All | Should Match 'run-agent requires a prompt'
    }
}

Describe 'adapters/copilot.sh load-marketplace' {
    It 'is a no-op returning 0 (no agent registration for copilot)' {
        $envSetup = New-MockCopilotEnv
        $wrapper = Join-Path $envSetup.Dir 'run-mk.sh'
        Set-Content -LiteralPath $wrapper -Value $script:MkWrapper -Encoding ascii

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Bash
        $psi.Arguments = "`"$wrapper`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Environment['ADAPTER_PATH'] = $script:Adapter
        $psi.Environment['OUT_LOG'] = Join-Path $envSetup.Dir 'stdout.log'
        $psi.Environment['ERR_LOG'] = Join-Path $envSetup.Dir 'stderr.log'

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $proc.WaitForExit()
        $outText = $outTask.Result
        $exit = $proc.ExitCode
        $proc.Dispose()

        $errText = ''
        if (Test-Path -LiteralPath $psi.Environment['ERR_LOG']) {
            $errText = Get-Content -LiteralPath $psi.Environment['ERR_LOG'] -Raw
        }
        $outLog = ''
        if (Test-Path -LiteralPath $psi.Environment['OUT_LOG']) {
            $outLog = Get-Content -LiteralPath $psi.Environment['OUT_LOG'] -Raw
        }
        $allText = $outText + $errText + $outLog

        $exit | Should Be 0
        $allText | Should Match 'marketplace'
    }
}
