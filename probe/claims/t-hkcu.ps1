# probe/claims/t-hkcu.ps1 — T1: is HKCU policy honored at runtime?
# (issue #1 section 5). reg add HKCU value -> headed chrome://policy/ ->
# UIA dump -> HONORED/IGNORED -> finally: delete value AND key, with proof.
# Also probes Telemetry=1 in the same try/finally. MUST stay the last probe of
# the T1-T8 group so a registry leak cannot contaminate T2-T8.

param(
    [Parameter(Mandatory)][string]$Baseline,
    [string]$OutDir = $env:CLAIMS
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
$emit       = Join-Path $PSScriptRoot 'emit-verdict.ps1'
$policyDump = Join-Path $PSScriptRoot 'policy-dump.ps1'

function Emit([string]$details) {
    & $emit -Id 'T1' -Details $details -OutDir $OutDir
    exit 0
}

$regKey  = 'HKCU\Software\Policies\YandexBrowser'
$values  = @('YandexAliceMsgDisable', 'Telemetry')
$tree    = $null
$added   = $false
$verdict = 'FAIL - probe did not run'

# Outside the try on purpose: `Emit` exits the script, and PowerShell runs
# finally blocks even on exit - a registry cleanup here would be pointless
# (and throws outright where reg does not exist).
if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }

try {
    $tree = Join-Path $OutDir 'trees\t1'
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force

    try {
        $added = $true
        foreach ($v in $values) {
            & reg add $regKey /v $v /t REG_DWORD /d 1 /f 2>$null | Out-Null
            $addCode = $LASTEXITCODE
            Write-Host ("detail: T1: reg add {0} exit={1}" -f $v, $addCode)
            if ($addCode -ne 0) { throw "reg add $v failed with exit $addCode" }
        }

        $uiOut = Join-Path $OutDir 't1-uia.txt'
        & $policyDump -App $tree -OutFile $uiOut -LaunchSec 30 -Port 9591
        $dumpCode = $LASTEXITCODE
        $txt = if (Test-Path -LiteralPath $uiOut) { [string](Get-Content -LiteralPath $uiOut -Raw -ErrorAction SilentlyContinue) } else { '' }
        if ($null -eq $txt) { $txt = '' }
        if ([string]::IsNullOrWhiteSpace($txt)) {
            throw "policy page dump produced no text (uia exit=$dumpCode, bytes=$($txt.Length))"
        }

        $honored = @()
        $ignored = @()
        $valueNotes = @()
        foreach ($v in $values) {
            if ($txt -match [regex]::Escape($v)) {
                $honored += $v
                $line = @($txt -split "`n" | Where-Object { $_ -match [regex]::Escape($v) }) | Select-Object -First 1
                $lineTrim = if ($null -ne $line) { $line.Trim() } else { '' }
                $valueNotes += ('{0}[{1}]' -f $v, $lineTrim)
            }
            else {
                $ignored += $v
            }
        }
        Write-Host ("detail: T1: honored=[{0}] ignored=[{1}] bytes={2}" -f `
            ($honored -join ', '), ($ignored -join ', '), $txt.Length)

        if ($honored.Count -eq $values.Count) {
            $verdict = 'HONORED - {0} listed on chrome://policy after HKCU reg add (via=uia bytes={1}; rows: {2})' -f `
                ($honored -join ', '), $txt.Length, (($valueNotes -join ' | ') -replace '\s+', ' ')
        }
        elseif ($honored.Count -gt 0) {
            $verdict = 'IGNORED - absent from chrome://policy: {0} (listed: {1}; via=uia bytes={2})' -f `
                ($ignored -join ', '), ($honored -join ', '), $txt.Length
        }
        else {
            $verdict = 'IGNORED - {0} absent from chrome://policy after HKCU reg add (via=uia bytes={1})' -f `
                ($values -join ', '), $txt.Length
        }
    }
    catch {
        $verdict = 'FAIL - ' + $_.Exception.Message
    }
}
catch {
    $verdict = 'FAIL - ' + $_.Exception.Message
}
finally {
    # cleanup: remove every value, then the whole key we created, with proof.
    # Only when we reached the registry at all - an early-exit path must never
    # touch HKCU (the emit-above exits before this try even starts).
    if ($added) {
        $cleanupNotes = @()
        foreach ($v in $values) {
            & reg delete $regKey /v $v /f 2>$null | Out-Null
            $cleanupNotes += ('{0} value delete exit={1}' -f $v, $LASTEXITCODE)
        }
        & reg delete $regKey /f 2>$null | Out-Null
        $keyDeleteExit = $LASTEXITCODE
        $null = & reg query $regKey 2>$null
        $keyStillThere = ($LASTEXITCODE -eq 0)
        $cleanupNotes += ("key delete exit={0}; keyStillThere={1}" -f $keyDeleteExit, $keyStillThere)
        Write-Host ('detail: T1 cleanup: ' + ($cleanupNotes -join '; '))
        if ($keyStillThere) {
            $verdict = $verdict + ' | CLEANUP-FAILED: HKCU probe key still present after reg delete'
        }
    }
    if ($tree -and (Test-Path -LiteralPath $tree)) {
        Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Emit $verdict
