# probe/claims/t-prune.ps1 — T7: cache prune safety. Launch, close, delete the
# volatile dirs, relaunch: PASS requires launch OK + launch-critical dirs
# recreated. Event-driven dirs (Crashpad, BrowserMetrics-*) are reported but
# never fail the probe by themselves (claims-lib Get-PruneVerdict).

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
    & $emit -Id 'T7' -Details $details -OutDir $OutDir
    exit 0
}

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }

    $tree = Join-Path $OutDir 'trees\t7'
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force

    $page = 'file:///' + ((Join-Path $pagesDir 'page.html') -replace '\\', '/')
    $out1 = Join-Path $OutDir 't7-launch1.txt'
    & $pageDump -App $tree -Url $page -OutFile $out1 -RequirePattern 'PAGE_OK' -Port 9571 -Label 't7-warm'
    $warmCode = $LASTEXITCODE

    $data = Join-Path $tree 'Data'
    if (-not (Test-Path -LiteralPath $data)) { Emit "FAIL - Data dir missing at $data" }
    $fixed = @('GPUCache', 'ShaderCache', 'GrShaderCache', 'DawnCache',
               'Default\Cache', 'Default\Code Cache', 'Default\Service Worker\CacheStorage', 'Crashpad')
    $existed = @()
    foreach ($rel in $fixed) {
        if (Test-Path -LiteralPath (Join-Path $data $rel)) { $existed += $rel }
    }
    $bmBefore = @(Get-ChildItem -LiteralPath $data -Directory -Force -Filter 'BrowserMetrics*' -ErrorAction SilentlyContinue)
    $bmExisted = ($bmBefore.Count -gt 0)
    Write-Host ("detail: T7: warm exit={0}; existing before prune=[{1}]; BrowserMetrics before={2}" -f `
        $warmCode, ($existed -join ', '), $bmExisted)
    if ($existed.Count -eq 0 -and -not $bmExisted) {
        Emit 'FAIL - no cache dirs existed after the warm-up launch (nothing to prune)'
    }

    # --- prune ---------------------------------------------------------------
    foreach ($rel in $existed) {
        Remove-Item -LiteralPath (Join-Path $data $rel) -Recurse -Force -ErrorAction Stop
        Write-Host ("detail: T7: pruned {0}" -f $rel)
    }
    foreach ($d in $bmBefore) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("detail: T7: pruned $($d.Name)")
    }

    # --- relaunch ------------------------------------------------------------
    $out2 = Join-Path $OutDir 't7-launch2.txt'
    & $pageDump -App $tree -Url $page -OutFile $out2 -RequirePattern 'PAGE_OK' -Port 9572 -Label 't7-relaunch'
    $relaunchCode = $LASTEXITCODE
    $dom = if (Test-Path -LiteralPath $out2) { [string](Get-Content -LiteralPath $out2 -Raw -ErrorAction SilentlyContinue) } else { '' }
    $relaunchOk = ($relaunchCode -eq 0 -and ($dom -match 'PAGE_OK'))
    Start-Sleep -Seconds 3

    $recreated = @()
    $missing = @()
    foreach ($rel in $existed) {
        if (Test-Path -LiteralPath (Join-Path $data $rel)) { $recreated += $rel } else { $missing += $rel }
    }
    if ($bmExisted) {
        $bmAfter = @(Get-ChildItem -LiteralPath $data -Directory -Force -Filter 'BrowserMetrics*' -ErrorAction SilentlyContinue)
        if ($bmAfter.Count -gt 0) { $recreated += 'BrowserMetrics-*' } else { $missing += 'BrowserMetrics-*' }
    }
    Write-Host ("detail: T7: relaunch exit={0} domBytes={1} ok={2}" -f $relaunchCode, $dom.Length, $relaunchOk)
    Write-Host ("detail: T7: recreated=[{0}] missing=[{1}]" -f ($recreated -join ', '), ($missing -join ', '))

    $eventDriven = @('Crashpad', 'BrowserMetrics-*')
    $v = Get-PruneVerdict -RelaunchOk $relaunchOk -Recreated $recreated -Missing $missing -EventDriven $eventDriven
    Emit ('{0} - {1}' -f $v.State, $v.Details)
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
finally {
    $t = Join-Path $OutDir 'trees\t7'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
