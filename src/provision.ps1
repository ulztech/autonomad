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
        [string]$Image = '',
        [string]$Adapter = ''
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

    $cmd = @('docker', 'run', '--rm')
    # Workspace (issue branch) read-write.
    $cmd += @('-v', "${Workspace}:/workspace")
    # AIOS brain read-only at corrected paths.
    $brainMounts = Get-BrainMounts -BrainRoot $BrainRoot -Config $Config
    foreach ($m in $brainMounts) { $cmd += @('-v', $m) }
    # .env injected (model keys, GH_TOKEN for the sandbox).
    if (-not [string]::IsNullOrWhiteSpace($EnvFile) -and (Test-Path -LiteralPath $EnvFile)) {
        $cmd += @('--env-file', $EnvFile)
    }
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
    $cmd += @('-w', '/workspace')
    $cmd += @($Image)
    $cmd += @('bash', $adapterPath, 'run-agent', "/workspace/.autonomad/prompt.md")
    return $cmd
}

<#
.SYNOPSIS
  Invoke the sandbox for an issue. Returns $LASTEXITCODE-equivalent result object.
  Docker mode: runs `docker run`. Mock mode: runs the mock dev-agent script.
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
        -BrainRoot $BrainRoot -EnvFile $EnvFile
    Write-Host "SANDBOX: docker run (workspace=$Workspace, brain=$BrainRoot)"
    & $cmd[0] $cmd[1..($cmd.Length - 1)]
    $exit = $LASTEXITCODE
    Write-Host "SANDBOX: exited with code $exit"
    return @{ exitcode = $exit }
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
    return @{ exitcode = $LASTEXITCODE }
}
