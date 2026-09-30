# probe/claims/t-admx.ps1 — T2: ADMX audit of issue #1 section 5 key names.
# Re-downloaded in CI for reproducibility (Discovery evidence must not be
# re-asserted from memory). Needs no extracted source tree.

param(
    [string]$OutDir = $env:CLAIMS,
    [string]$AdmxUrl = 'https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
$emit = Join-Path $PSScriptRoot 'emit-verdict.ps1'

function Emit([string]$details) {
    & $emit -Id 'T2' -Details $details -OutDir $OutDir
    exit 0
}

try {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'claims-YandexBrowser.admx'
    Write-Host "detail: T2: downloading $AdmxUrl"
    Invoke-WebRequest -Uri $AdmxUrl -OutFile $tmp -TimeoutSec 180 -UseBasicParsing
    $bytes = [IO.File]::ReadAllBytes($tmp)
    $start = 0
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $start = 2 }
    $text = [Text.Encoding]::Unicode.GetString($bytes, $start, $bytes.Length - $start)
    Write-Host ("detail: T2: bytes={0} decodedChars={1}" -f $bytes.Length, $text.Length)

    $audit = Get-AdmxAudit -AdmxText $text
    if ($audit.Total -eq 0) { Emit 'FAIL - ADMX parsed 0 policy elements (download or UTF-16 decode failure)' }

    $classPart = if ($audit.AllClassBoth) {
        'all class=Both'
    }
    else {
        $pairs = @()
        foreach ($k in $audit.ClassCounts.Keys) { $pairs += ('class {0}x{1}' -f $k, $audit.ClassCounts[$k]) }
        (($pairs | Sort-Object) -join ', ')
    }
    Write-Host ("detail: T2: issue-claimed names missing (fabricated): {0}" -f ($audit.IssueMissing -join ', '))
    Write-Host ("detail: T2: issue-claimed names present: {0}" -f (
        @($audit.Issue.Keys | Where-Object { $audit.Issue[$_] -eq 'EXISTS' }) -join ', '))
    Write-Host ("detail: T2: shipped names present: {0}/{1}" -f (
        @($audit.Shipped.Keys | Where-Object { $audit.Shipped[$_] -eq 'EXISTS' }).Count, $audit.Shipped.Count))
    if (@($audit.ShippedMissing).Count -gt 0) {
        Write-Host ("detail: T2: shipped names MISSING from ADMX: {0}" -f ($audit.ShippedMissing -join ', '))
    }

    $details = '{0} of 9 claimed names fabricated; {1} policies; {2}' -f `
        $audit.IssueFabricatedCount, $audit.Total, $classPart
    Emit $details
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
