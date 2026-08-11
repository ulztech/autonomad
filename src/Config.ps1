# Autonomad v1 — src/Config.ps1
#
# Shared configuration parsing for all Autonomad PowerShell scripts.
# Dot-source this file:  . "$PSScriptRoot/Config.ps1"
#
# Parses:
#   - repo.config          (INI-style key = value, # comments)
#   - .env                 (INI-style key = value, exported into the process env)
#
# All functions are strict, return clear exit codes, and never touch secrets
# beyond exposing them through the process environment.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known keys in repo.config (used for validation + defaults).
$script:ConfigKeys = @(
    'repo', 'harness', 'model', 'test_command', 'build_command',
    'poll_interval', 'idle_timeout', 'ttl', 'max_retries', 'bot_login',
    'branch_prefix', 'base_branch', 'brain_paths',
    'sandbox_timeout', 'progress_threshold', 'watch_poll', 'stall_kill',
    'learnings_dir', 'test_runner'
)

<#
.SYNOPSIS
  Parse an INI-style file (key = value, lines starting with # or ; are comments)
  into an ordered hashtable. Never throws for missing file when $Required=$false.
#>
function Read-IniFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$Required = $true
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Required) { throw "Config file not found: $Path" }
        return @{}
    }
    $result = [ordered]@{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }  # no '=' -> not a key/value line
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($key -eq '') { continue }
        $result[$key] = $value
    }
    return $result
}

<#
.SYNOPSIS
  Load repo.config and validate it. Returns an ordered hashtable of settings.
#>
function Read-RepoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )
    $cfg = Read-IniFile -Path $ConfigPath -Required $true

    $errors = @()
    foreach ($req in @('repo', 'harness', 'test_command', 'build_command')) {
        if (-not $cfg.Contains($req) -or [string]::IsNullOrWhiteSpace($cfg[$req])) {
            $errors += "Missing required config key: $req"
        }
    }
    if ($cfg.Contains('harness') -and $cfg['harness'] -notin @('opencode', 'claude', 'copilot')) {
        $errors += "harness must be one of: opencode | claude | copilot (got '$($cfg['harness'])')"
    }
    if (-not ($cfg['repo'] -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) {
        $errors += "repo must be owner/name (got '$($cfg['repo'])')"
    }
    foreach ($intKey in @('poll_interval', 'idle_timeout', 'ttl', 'max_retries', 'sandbox_timeout', 'progress_threshold', 'watch_poll', 'stall_kill')) {
        if ($cfg.Contains($intKey) -and -not ($cfg[$intKey] -match '^\d+$')) {
            $errors += "$intKey must be a positive integer (got '$($cfg[$intKey])')"
        }
    }
    # model: optional override; must be a non-empty string when present.
    if ($cfg.Contains('model') -and [string]::IsNullOrWhiteSpace($cfg['model'])) {
        $errors += "model must be a non-empty string when set (got empty)"
    }
    # brain_paths: optional comma-separated list; each entry non-empty when present.
    if ($cfg.Contains('brain_paths') -and [string]::IsNullOrWhiteSpace($cfg['brain_paths'])) {
        $errors += "brain_paths must be a comma-separated list of brain subdirectories (got empty)"
    }
    if ($cfg.Contains('brain_paths') -and -not [string]::IsNullOrWhiteSpace($cfg['brain_paths'])) {
        $empty = @($cfg['brain_paths'] -split ',' | Where-Object { [string]::IsNullOrWhiteSpace($_) })
        if ($empty.Count -gt 0) {
            $errors += "brain_paths contains empty entries (got '$($cfg['brain_paths'])')"
        }
    }
    # learnings_dir / test_runner: optional; non-empty when present.
    foreach ($opt in @('learnings_dir', 'test_runner')) {
        if ($cfg.Contains($opt) -and [string]::IsNullOrWhiteSpace($cfg[$opt])) {
            $errors += "$opt must be a non-empty string when set (got empty)"
        }
    }
    if ($errors.Count -gt 0) {
        throw "repo.config validation failed:`n  " + ($errors -join "`n  ")
    }

    # Defaults for optional keys.
    $defaults = @{
        poll_interval     = '60'
        idle_timeout      = '1800'
        ttl               = '3600'
        max_retries       = '2'
        bot_login         = 'autonomad-bot'
        branch_prefix     = 'autonomad'
        base_branch       = 'main'
        sandbox_timeout   = '1800'
        progress_threshold = '60'
        watch_poll        = '15'
        stall_kill        = '900'
    }
    foreach ($k in $defaults.Keys) {
        if (-not $cfg.Contains($k) -or [string]::IsNullOrWhiteSpace($cfg[$k])) {
            $cfg[$k] = $defaults[$k]
        }
    }
    return $cfg
}

<#
.SYNOPSIS
  Load .env into the process environment (never overriding an existing variable).
  Returns the raw parse result too, so callers can read non-env vars.
#>
function Import-EnvFile {
    [CmdletBinding()]
    param(
        [string]$EnvFilePath
    )
    if ([string]::IsNullOrWhiteSpace($EnvFilePath)) { return @{} }
    if (-not (Test-Path -LiteralPath $EnvFilePath)) {
        Write-Warning "Import-EnvFile: .env not found at '$EnvFilePath' (continuing with existing env)"
        return @{}
    }
    $envVars = Read-IniFile -Path $EnvFilePath -Required $false
    foreach ($k in $envVars.Keys) {
        # Never clobber a value already set in the environment (docker --env-file style).
        if (-not [System.Environment]::GetEnvironmentVariable($k)) {
            [System.Environment]::SetEnvironmentVariable($k, $envVars[$k])
        }
    }
    return $envVars
}

<#
.SYNOPSIS
  Resolve the AIOS brain subdirectory paths, applying the CORRECTED layout:
    graphify-out/ context/ references/ decisions/  -> at AIOS root
    skills/ agents/                                 -> under .github/
  Returns a hashtable of name -> absolute path, filtering out missing dirs.
#>
function Resolve-BrainPaths {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [string[]]$Requested = @('graphify-out', 'context', 'references', 'decisions', '.github/skills', '.github/agents')
    )
    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($BrainRoot)) {
        Write-Warning "Resolve-BrainPaths: AIOS_BRAIN_PATH is empty; no brain mounts will be available."
        return $result
    }
    foreach ($rel in $Requested) {
        $rel = $rel.Trim()
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        # Corrected mapping: skills/agents actually live under .github/ in the AIOS repo.
        $name = Split-Path -Leaf ($rel -replace '^\.github[/\\]', '')
        $full = if ($rel -match '^\.github[/\\]') {
            Join-Path $BrainRoot $rel
        } else {
            Join-Path $BrainRoot $rel
        }
        if (Test-Path -LiteralPath $full) {
            $result[$name] = $full
        } else {
            Write-Warning "Resolve-BrainPaths: brain dir not found (skipping mount): $full"
        }
    }
    return $result
}

<#
.SYNOPSIS
  Splits brain_paths from repo.config (comma-separated) into an array.
#>
function ConvertFrom-BrainPaths {
    [CmdletBinding()]
    param([string]$BrainPathsCsv)
    if ([string]::IsNullOrWhiteSpace($BrainPathsCsv)) {
        return @('graphify-out', 'context', 'references', 'decisions', '.github/skills', '.github/agents')
    }
    return @($BrainPathsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
