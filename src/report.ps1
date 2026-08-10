# Autonomad v1 — src/report.ps1
#
# Per-issue artifact report (T6/Q21): generates reports/{issue-ref}.html and
# appends one line to reports/runs.log.
#
# Usage:
#   pwsh -File src/report.ps1 -State <obj> -ReportsDir <dir> [-LogsDir <dir>] [-Issue <obj>]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][object]$State,
    [string]$ReportsDir = '',
    [string]$LogsDir = '',
    [object]$Issue = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $PSScriptRoot
if (-not $ReportsDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $ReportsDir = if ($envData) { Join-Path $envData 'reports' } else { Join-Path $script:Root 'reports' }
}
if (-not $LogsDir) {
    $envData = [System.Environment]::GetEnvironmentVariable('AUTONOMAD_DATA')
    $LogsDir = if ($envData) { Join-Path $envData 'logs' } else { Join-Path $script:Root 'logs' }
}
if (-not (Test-Path -LiteralPath $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

$issueRef = $State.issue_ref
$title = if ($Issue -and $Issue.title) { $Issue.title } else { "Issue #$($State.issue_number)" }
$body = if ($Issue -and $Issue.body) { $Issue.body } else { '' }

# Gate status table
$gateRows = ''
foreach ($prop in $State.gates.PSObject.Properties) {
    $color = switch ($prop.Value) {
        'completed'  { '#16a34a' }
        'in_progress' { '#d97706' }
        'skipped'    { '#6b7280' }
        default      { '#9ca3af' }
    }
    $gateRows += "<tr><td>$(ConvertTo-HtmlSafe $prop.Name)</td><td style='color:$color;font-weight:600'>$(ConvertTo-HtmlSafe $prop.Value)</td></tr>"
}

$completedGates = ($State.completed -join ', ')
$pendingGates = ($State.pending -join ', ')

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Autonomad Report — $issueRef</title>
<style>
  body { font-family: -apple-system, 'Segoe UI', Roboto, sans-serif; margin: 2rem auto; max-width: 900px; padding: 0 1rem; color: #1f2937; background: #f9fafb; }
  h1 { font-size: 1.5rem; border-bottom: 2px solid #e5e7eb; padding-bottom: .5rem; }
  h2 { font-size: 1.1rem; margin-top: 2rem; }
  table { border-collapse: collapse; width: 100%; background: #fff; }
  th, td { border: 1px solid #e5e7eb; padding: .5rem .75rem; text-align: left; font-size: .9rem; }
  th { background: #f3f4f6; }
  .meta { font-size: .85rem; color: #6b7280; }
  .box { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 1rem; }
  pre { background: #111827; color: #e5e7eb; padding: 1rem; border-radius: 8px; overflow-x: auto; font-size: .85rem; }
  .status { display: inline-block; padding: .2rem .6rem; border-radius: 999px; font-size: .8rem; font-weight: 600; }
  .status.pending-review { background: #dbeafe; color: #1d4ed8; }
  .status.needs-human { background: #fee2e2; color: #b91c1c; }
  .status.in-progress { background: #fef3c7; color: #92400e; }
  .status.done { background: #dcfce7; color: #166534; }
</style>
</head>
<body>
  <h1>Autonomad Report — <code>$issueRef</code></h1>
  <p class="meta">Generated <span id="gen">$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</span> UTC &middot; repo <code>$(ConvertTo-HtmlSafe $State.repo)</code> &middot; branch <code>$(ConvertTo-HtmlSafe $State.branch)</code></p>

  <h2>Summary</h2>
  <div class="box">
    <p><strong>Issue:</strong> $(ConvertTo-HtmlSafe $title)</p>
    <p><strong>Status:</strong> <span class="status $(ConvertTo-HtmlSafe $State.status)">$(ConvertTo-HtmlSafe $State.status)</span></p>
    <p><strong>PR:</strong> $(if ($State.pr_url) { "<a href='$(ConvertTo-HtmlSafe $State.pr_url)'>$(ConvertTo-HtmlSafe $State.pr_url)</a>" } else { 'n/a' })</p>
    <p><strong>Confidence:</strong> $(if ($null -ne $State.confidence) { [math]::Round([double]$State.confidence * 100) } else { '-' })%</p>
    <p><strong>Attempts:</strong> $($State.attempts) / $($State.max_retries)</p>
    $(if ($State.halt_reason) { "<p><strong>Halt reason:</strong> $(ConvertTo-HtmlSafe $State.halt_reason)</p>" } else { '' })
  </div>

  <h2>Pipeline gates</h2>
  <table>
    <tr><th>Gate</th><th>Status</th></tr>
    $gateRows
  </table>
  <p class="meta">Completed: $(ConvertTo-HtmlSafe $completedGates)<br>Pending: $(ConvertTo-HtmlSafe $pendingGates)</p>

  <h2>Timeline</h2>
  <table>
    <tr><th>Event</th><th>Timestamp (UTC)</th></tr>
    <tr><td>created_at</td><td>$(ConvertTo-HtmlSafe $State.created_at)</td></tr>
    <tr><td>updated_at</td><td>$(ConvertTo-HtmlSafe $State.updated_at)</td></tr>
    $(if ($State.timestamps) {
        ($State.timestamps.PSObject.Properties | ForEach-Object { "<tr><td>$($_.Name)</td><td>$(ConvertTo-HtmlSafe $_.Value)</td></tr>" }) -join "`n"
    } else { '' })
  </table>

  <h2>Issue body</h2>
  <div class="box"><pre>$(ConvertTo-HtmlSafe $body)</pre></div>
</body>
</html>
"@

$reportFile = Join-Path $ReportsDir "$issueRef.html"
[System.IO.File]::WriteAllText($reportFile, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[report] wrote $reportFile"

# runs.log append
$runsLog = Join-Path $LogsDir 'runs.log'
$now = (Get-Date).ToUniversalTime().ToString('o')
$line = "$now`t$($State.repo)`t$issueRef`t$($State.status)`t$($State.pr_url)`tattempts=$($State.attempts)`tconfidence=$($State.confidence)"
Add-Content -LiteralPath $runsLog -Value $line
Write-Host "[report] appended $runsLog"

exit 0
