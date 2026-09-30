# probe/claims/t-locale.ps1 — T8: locale trim render check. Uses the T3 group-E
# tree when it exists (Locales trimmed to en-US.pak); builds its own group-E
# trim otherwise so -f test=t8 works standalone. Asserts the UI really renders
# (non-empty body, title carries navigator.language).

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
    & $emit -Id 'T8' -Details $details -OutDir $OutDir
    exit 0
}

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }

    $tree = Join-Path $OutDir 'trees\gE'
    $source = 'reused T3-E tree'
    if (-not (Test-Path -LiteralPath (Join-Path $tree 'Yandex\browser.exe'))) {
        $tree = Join-Path $OutDir 'trees\t8'
        $source = 'fresh group-E trim (T3-E tree unavailable)'
        if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
        Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force
        $spec = Get-TrimGroupSpec -GroupId 'E'
        $loc = Get-ChildItem -LiteralPath $tree -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'Locales' } | Select-Object -First 1
        if ($null -eq $loc) { Emit "FAIL - Locales directory not found under $tree" }
        foreach ($child in @(Get-ChildItem -LiteralPath $loc.FullName -Force -ErrorAction SilentlyContinue)) {
            if (@($spec.Keep | Where-Object { $_ -ieq $child.Name }).Count -gt 0) { continue }
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $locDir = Get-ChildItem -LiteralPath $tree -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'Locales' } | Select-Object -First 1
    if ($null -eq $locDir) { Emit "FAIL - Locales directory missing under $tree" }
    $locFiles = @(Get-ChildItem -LiteralPath $locDir.FullName -File -Force -ErrorAction SilentlyContinue)
    $locNames = @($locFiles | ForEach-Object { $_.Name })
    $onlyEn = ($locFiles.Count -eq 1 -and $locFiles[0].Name -ieq 'en-US.pak')
    Write-Host ("detail: T8: source={0}; Locales files=[{1}]; onlyEn={2}" -f $source, ($locNames -join ', '), $onlyEn)

    $page = 'file:///' + ((Join-Path $pagesDir 'locale.html') -replace '\\', '/')
    $out = Join-Path $OutDir 't8-locale.txt'
    & $pageDump -App $tree -Url $page -OutFile $out -RequirePattern 'LOCALE_' -Port 9581 -Label 't8'
    $code = $LASTEXITCODE
    $dom = if (Test-Path -LiteralPath $out) { [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) } else { '' }

    $lang = $null
    if ($dom -match 'LOCALE_([A-Za-z][A-Za-z-]*)') { $lang = $Matches[1] }
    $bodyOk = ($dom -match 'RENDERED_TEXT_OK')
    $bytes = $dom.Length
    Write-Host ("detail: T8: exit={0} domBytes={1} lang={2} bodyOk={3}" -f $code, $bytes, $lang, $bodyOk)

    $langText = if ($null -eq $lang) { '' } else { $lang }
    $verdict = Get-LocaleVerdict -DomOk $bodyOk -OnlyEn $onlyEn -Lang $langText -DomBytes $bytes
    Emit ("{0} (source={1}; Locales=[{2}])" -f $verdict, $source, ($locNames -join ', '))
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
finally {
    $t8 = Join-Path $OutDir 'trees\t8'
    if (Test-Path -LiteralPath $t8) { Remove-Item -LiteralPath $t8 -Recurse -Force -ErrorAction SilentlyContinue }
}
