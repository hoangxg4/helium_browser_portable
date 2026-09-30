# probe/claims/t-first-run.ps1 — T5: do the six issue-named preseed keys exist
# after a real first run? Headed launch so the NTP opens naturally (promo/NTP
# keys only materialize after a newtab visit), then diff Preferences + Local
# State before vs after.

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
    & $emit -Id 'T5' -Details $details -OutDir $OutDir
    exit 0
}

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }

    $keys = @('neuro_question', 'video_button_enabled', 'show_ya_button',
              'app_side_promo_service_enabled', 'alissenger', 'default_apps_installed')
    $tree = Join-Path $OutDir 'trees\t5'
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force

    $pref = Join-Path $tree 'Data\Default\Preferences'
    $loc  = Join-Path $tree 'Data\Local State'
    function Read-Blob([string]$prefPath, [string]$locPath) {
        $a = if (Test-Path -LiteralPath $prefPath) { Get-Content -LiteralPath $prefPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $b = if (Test-Path -LiteralPath $locPath)   { Get-Content -LiteralPath $locPath   -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($null -eq $a) { $a = '' }
        if ($null -eq $b) { $b = '' }
        return ([string]$a + "`n" + [string]$b)
    }

    $before = Read-Blob -prefPath $pref -locPath $loc
    Write-Host ("detail: T5: before bytes={0} prefExists={1}" -f $before.Length, (Test-Path -LiteralPath $pref))
    foreach ($k in $keys) {
        $hits = Get-PreferenceKeyHits -Text $before -Keys @($k)
        Write-Host ("detail: T5: before {0}={1}" -f $k, $hits[$k])
    }

    # headed first run: no URL argument, so the first-run NTP opens naturally
    $out = Join-Path $OutDir 't5-headed.txt'
    & $pageDump -App $tree -Url 'about:blank' -OutFile $out -Headed -RunSec 25 -Port 9551 -Label 't5'
    Start-Sleep -Seconds 5

    $after = Read-Blob -prefPath $pref -locPath $loc
    Write-Host ("detail: T5: after bytes={0} prefExists={1}" -f $after.Length, (Test-Path -LiteralPath $pref))
    if ([string]::IsNullOrWhiteSpace($after)) {
        Emit ("FAIL - Preferences/Local State unreadable after first run (prefExists={0})" -f (Test-Path -LiteralPath $pref))
    }

    $diff = Get-PreferenceDiff -Before $before -After $after -Keys $keys
    foreach ($k in $keys) { Write-Host ("detail: T5: {0}={1}" -f $k, [string]$diff.Status[$k]) }

    $details = Get-FirstRunVerdict -Diff $diff
    Emit $details
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
finally {
    $t = Join-Path $OutDir 'trees\t5'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}
