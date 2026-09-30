# probe/claims/t-atomic.ps1 — T6: atomic Preferences write acceptance.
# Benign probe key via .tmp + File.Replace, relaunch, then: value read back,
# JSON still valid, no corruption leftovers next to Preferences.

param(
    [Parameter(Mandatory)][string]$Baseline,
    [string]$OutDir = $env:CLAIMS
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
$emit     = Join-Path $PSScriptRoot 'emit-verdict.ps1'
$pageDump = Join-Path $PSScriptRoot 'page-dump.ps1'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pagesDir = Join-Path $repoRoot 'probe\claims'

function Emit([string]$details) {
    & $emit -Id 'T6' -Details $details -OutDir $OutDir
    exit 0
}

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }

    $probeKey = 'claims_probe_key'
    $probeVal = 'claims_probe_value_20260930'
    $tree = Join-Path $OutDir 'trees\t6'
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force

    $pref = Join-Path $tree 'Data\Default\Preferences'
    if (-not (Test-Path -LiteralPath $pref)) { Emit "FAIL - preseeded Preferences missing at $pref" }
    $before = Get-Content -LiteralPath $pref -Raw
    if ([string]::IsNullOrWhiteSpace($before)) { Emit 'FAIL - preseeded Preferences is empty' }
    $null = $before | ConvertFrom-Json
    if ($before -match [regex]::Escape('"' + $probeKey + '"')) { Emit "FAIL - probe key already present in preseeded Preferences" }

    # atomic replace: single-line insertion keeps every other byte identical
    $insert = '"' + $probeKey + '":"' + $probeVal + '",'
    $new = $before.Substring(0, 1) + $insert + $before.Substring(1)
    $null = $new | ConvertFrom-Json
    $tmp = $pref + '.tmp'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($tmp, $new, $utf8NoBom)
    [IO.File]::Replace($tmp, $pref, $null)
    $tmpGone = -not (Test-Path -LiteralPath $tmp)
    $mid = Get-Content -LiteralPath $pref -Raw
    $midOk = ($mid -match ('"{0}"\s*:\s*"{1}"' -f $probeKey, $probeVal))
    Write-Host ("detail: T6: tmpGoneAfterReplace={0} midReadBack={1}" -f $tmpGone, $midOk)

    # relaunch so the browser parses the replaced file
    $out = Join-Path $OutDir 't6-launch.txt'
    $page = 'file:///' + ((Join-Path $pagesDir 'page.html') -replace '\\', '/')
    & $pageDump -App $tree -Url $page -OutFile $out -RequirePattern 'PAGE_OK' -Port 9561 -Label 't6'
    $launchCode = $LASTEXITCODE
    $dom = if (Test-Path -LiteralPath $out) { [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) } else { '' }
    Start-Sleep -Seconds 3

    $after = Get-Content -LiteralPath $pref -Raw -ErrorAction SilentlyContinue
    if ($null -eq $after) { $after = '' }
    $jsonOk = $true
    try { $null = $after | ConvertFrom-Json } catch { $jsonOk = $false }
    $readBack = ($after -match ('"{0}"\s*:\s*"{1}"' -f $probeKey, $probeVal))
    $dir = Split-Path -Parent $pref
    $siblings = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Preferences*' } | ForEach-Object { $_.Name })
    $tmpLeftovers = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(tmp|bak|journal)$' -or $_.Name -like '*-journal' } | ForEach-Object { $_.Name })

    $problems = @()
    if ($launchCode -ne 0) { $problems += "launch exit=$launchCode (dom bytes=$($dom.Length))" }
    if (-not $jsonOk) { $problems += 'Preferences is not valid JSON after relaunch' }
    if (-not $readBack) { $problems += 'probe key not read back after relaunch' }
    if (-not $tmpGone) { $problems += '.tmp file survived File.Replace' }
    if ($tmpLeftovers.Count -gt 0) { $problems += ("corruption leftovers: {0}" -f ($tmpLeftovers -join ',')) }

    Write-Host ("detail: T6: siblings=[{0}]" -f ($siblings -join ', '))
    Write-Host ("detail: T6: jsonOk={0} readBack={1} domBytes={2}" -f $jsonOk, $readBack, $dom.Length)

    if ($problems.Count -gt 0) { Emit ('FAIL - ' + ($problems -join '; ')) }
    Emit ('PASS - atomic .tmp+File.Replace accepted: probe key read back after relaunch, JSON valid, no leftovers (dir Preferences files: {0})' -f ($siblings -join ','))
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
finally {
    $t = Join-Path $OutDir 'trees\t6'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
