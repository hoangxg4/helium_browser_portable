# probe/claims/emit-verdict.ps1 — the single writer of "T<n> verdict:" lines.
# Every probe calls this exactly once so the verify greps can never come up
# empty: line goes to the log, to verdicts.txt (job-level tally) and to the
# step summary table.

param(
    [Parameter(Mandatory)][ValidatePattern('^T\d+$')][string]$Id,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Details,
    [string]$OutDir = $env:CLAIMS
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')

$line = Format-VerdictLine -Id $Id -Details $Details
Write-Host $line

if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = [IO.Path]::GetTempPath() }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Content -Encoding utf8 -Path (Join-Path $OutDir 'verdicts.txt') -Value $line

if ($env:GITHUB_STEP_SUMMARY) {
    $md = $Details -replace '\|', '\|'
    Add-Content -Encoding utf8 -Path $env:GITHUB_STEP_SUMMARY -Value ("| {0} | {1} |" -f $Id, $md)
}

exit 0
