# tests/update.tests.ps1 — behavior tests for update.bat (Task 05)
#
# Run:  pwsh -NoProfile -File tests/update.tests.ps1
# Needs: pwsh 7+. Hermetic: winget version resolution and the installer
# download are replaced after dot-sourcing the embedded body (no network),
# the builder is a local fixture script, and the debloater.reg import
# warn-path runs for real on hosts without `reg`.

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$updateBat = Join-Path $repoRoot 'update.bat'

$script:passed  = 0
$script:failed  = 0
$script:failure = @()

function Ok([string]$m) {
    $script:passed++
    Write-Host "  ok   $m"
}
function Fail([string]$m) {
    $script:failed++
    $script:failure += $m
    Write-Host "  FAIL $m" -ForegroundColor Red
}
function Assert([bool]$cond, [string]$m) {
    if ($cond) { Ok $m } else { Fail $m }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('ubx-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---------------------------------------------------------------- helpers --

function New-Tree([string]$root, [hashtable]$files) {
    foreach ($rel in $files.Keys) {
        $p = Join-Path $root ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar)
        $d = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Set-Content -Path $p -Value $files[$rel] -NoNewline
    }
}

function Get-Trimmed([string]$path) {
    return (Get-Content -LiteralPath $path -Raw).Trim()
}

# Fake builder standing in for build-yandex.ps1 at the package root: records
# its arguments, then lays out a "new version" staged package (nested CDM,
# reintroduced updater, staged Data\ that must be refused, root launch.bat).
function New-FakeBuilder([string]$pkgRoot, [switch]$Fail) {
    $failLine = ''
    if ($Fail) { $failLine = 'exit 1' }
    $body = @'
param(
    [string]$Installer,
    [switch]$Download,
    [string]$Version,
    [string]$OutDir,
    [string]$ChromePlusUrl = ''
)
function Get-CdnCandidateUrl([string]$v) { "https://example.invalid/$v/Yandex.exe" }
function Test-Url([string]$uri) { $false }
function Resolve-ManifestUrl([string]$v) { throw 'network not expected in tests' }
if ($MyInvocation.InvocationName -eq '.') { return }
Set-Content -Path (Join-Path $PSScriptRoot 'builder-invoked.txt') -Value "Version=$Version;Installer=$Installer;OutDir=$OutDir"
__FAIL__
$y = Join-Path $OutDir 'Yandex'
New-Item -ItemType Directory -Path $y -Force | Out-Null
Set-Content -Path (Join-Path $y 'browser.exe') -Value 'new-browser'
Set-Content -Path (Join-Path $y 'chrome++.ini') -Value 'INI_NEW'
Set-Content -Path (Join-Path $y 'update.bat') -Value 'BAT_NEW'
Set-Content -Path (Join-Path $y 'debloater.reg') -Value 'REG_NEW'
Set-Content -Path (Join-Path $y 'version.txt') -Value $Version
Set-Content -Path (Join-Path $y 'added.txt') -Value 'brand-new-file'
Set-Content -Path (Join-Path $y 'version.dll') -Value 'new-version-dll'
$nest = Join-Path (Join-Path $y '9.9.9') 'WidevineCdm'
New-Item -ItemType Directory -Path $nest -Force | Out-Null
Set-Content -Path (Join-Path $nest 'manifest.json') -Value '{"cdm":"staged"}'
Set-Content -Path (Join-Path $y 'service_update.exe') -Value 'stale-updater'
$evil = Join-Path $y 'Data'
New-Item -ItemType Directory -Path $evil -Force | Out-Null
Set-Content -Path (Join-Path $evil 'evil.txt') -Value 'must-not-land'
New-Item -ItemType Directory -Path (Join-Path $OutDir 'Data') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutDir 'Cache') -Force | Out-Null
Set-Content -Path (Join-Path $OutDir 'launch.bat') -Value 'staged-launch'
exit 0
'@
    $body = $body.Replace('__FAIL__', $failLine)
    Set-Content -Path (Join-Path $pkgRoot 'build-yandex.ps1') -Value $body
}

# Live (pre-update) package: Yandex\ with the four protected files, root
# Data\ + Cache\ sentinels, root launch.bat (era launcher) and the fake builder.
function New-LivePackage([string]$root, [string]$currentVersion) {
    $y = Join-Path $root 'Yandex'
    New-Tree $y @{
        'browser.exe'     = 'old-browser'
        'chrome++.ini'    = 'INI_LIVE'
        'update.bat'      = 'BAT_LIVE'
        'debloater.reg'   = 'REG_LIVE'
        'version.txt'     = $currentVersion
        'legacy-only.txt' = 'pre-update-file'
    }
    New-Tree (Join-Path $root 'Data')  @{ 'sentinel.txt' = 'profile-data' }
    New-Tree (Join-Path $root 'Cache') @{ 'sentinel.txt' = 'cache-data' }
    Set-Content -Path (Join-Path $root 'launch.bat') -Value 'LIVE_LAUNCH'
    New-FakeBuilder $root
    return $y
}

function Get-ChildDirCount([string]$filter) {
    return @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter $filter -ErrorAction SilentlyContinue).Count
}

# ------------------------------------------------------------------- tests --

Write-Host '== T1: 11-line bat header / -Skip 11 embedding =='
$batLines = @(Get-Content -LiteralPath $updateBat)
Assert ($batLines.Count -gt 11) "T1 bat carries an embedded PS body (got $($batLines.Count) lines)"
Assert ($batLines[8] -match 'Skip 11') 'T1 line 9 embeds the body with -Skip 11'
Assert ($batLines[5] -match '%~dp0') 'T1 line 6 pins APP_DIR to the script dir (%~dp0, not CWD)'
Assert ($batLines[10] -match '^exit /b') 'T1 line 11 is exit /b (propagates the PS exit code)'
Assert ($batLines[11] -match '^#') 'T1 PS body starts exactly at line 12 (skip count matches layout)'

Write-Host '== T2: extracted PS body parses cleanly =='
$bodyLines = $batLines[11..($batLines.Count - 1)]
$bodyFile  = Join-Path $work 'update-body.ps1'
Set-Content -Path $bodyFile -Value ($bodyLines -join "`n")
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($bodyFile, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert ($parseErrors.Count -eq 0) "T2 embedded body parses without errors (got $($parseErrors.Count))"
foreach ($e in $parseErrors) { Fail "T2 parse error line $($e.Extent.StartLineNumber): $($e.Message)" }

Write-Host '== T3: source invariants (plan Verify) =='
$raw = Get-Content -LiteralPath $updateBat -Raw
Assert ($raw -match 'protectedPaths') 'T3 protectedPaths present'
Assert ($raw -match 'build-yandex\.ps1') 'T3 reuses build-yandex.ps1 (no extraction logic duplicated)'
Assert ($raw -match 'WidevineCdm') 'T3 flat-CDM migration present'
Assert ($raw -match 'service_update') 'T3 stale updater strip present'
Assert ($raw -match 'debloater\.reg') 'T3 debloater.reg re-import present'
Assert ($raw -match 'Get-CdnCandidateUrl') 'T3 reuses the builder URL helpers (dot-source)'
Assert ($raw -notmatch 'disable-component-update') 'T3 never contains disable-component-update'

$definesFlow = Select-String -Path $updateBat -Pattern 'function\s+Invoke-UpdateFlow' -Quiet
Assert ($definesFlow -eq $true) 'T4 update.bat defines Invoke-UpdateFlow'

if ($definesFlow) {

    # Load the body functions only (the body has a dot-source guard before main).
    . $bodyFile

    Write-Host '== T4: dot-source exposes the flow functions (test seams) =='
    foreach ($fn in 'Invoke-UpdateFlow', 'Get-LatestPackageVersion', 'Save-LatestInstaller', 'Read-UpdatePrompt', 'Stop-AppBrowser', 'Copy-UpdatedFiles', 'Update-CdmLayout', 'Import-BloatPolicies', 'Resolve-InstallerUrl') {
        Assert ([bool](Get-Command $fn -ErrorAction SilentlyContinue)) "T4 function $fn exposed"
    }

    # ---- seams: replace the two network functions and the prompt reader ----
    $script:promptLog   = @()
    $script:promptQueue = New-Object System.Collections.Queue
    $script:latestVersion = '2.0.0.0'
    $script:downloadCount = 0

    function Read-UpdatePrompt([string]$Message) {
        $script:promptLog += $Message
        if ($script:promptQueue.Count -gt 0) { return [string]$script:promptQueue.Dequeue() }
        return 'y'
    }
    function Get-LatestPackageVersion { return $script:latestVersion }
    function Save-LatestInstaller([string]$Latest, [string]$BuilderScript, [string]$DestFile) {
        $script:downloadCount++
        $dir = Split-Path -Parent $DestFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $DestFile -Value "fake-installer-$Latest"
        return $DestFile
    }

    # ---- T5: full happy-path update ----
    Write-Host '== T5: full update flow (hermetic) =='
    $pkg5 = Join-Path $work 'pkg5'
    $y5   = New-LivePackage $pkg5 '1.0.0.0'
    $script:promptLog   = @()
    $script:downloadCount = 0
    $tempBefore = Get-ChildDirCount 'yandex-update-*'
    $r5 = $null
    $err5 = $null
    try { $r5 = Invoke-UpdateFlow -AppDir $y5 } catch { $err5 = $_.Exception.Message }
    Assert ($null -eq $err5) "T5 flow completes without error (got: $err5)"
    Assert ($r5 -and $r5.Outcome -eq 'Updated') "T5 outcome = Updated (got: $($r5.Outcome))"

    Assert ((Test-Path (Join-Path $y5 'version.txt')) -and ((Get-Trimmed (Join-Path $y5 'version.txt')) -eq '2.0.0.0')) 'T5 version.txt rewritten to the latest version'
    Assert ((Get-Trimmed (Join-Path $y5 'chrome++.ini')) -eq 'INI_LIVE') 'T5 chrome++.ini protected (not overwritten)'
    Assert ((Get-Trimmed (Join-Path $y5 'update.bat')) -eq 'BAT_LIVE') 'T5 update.bat protected (not overwritten)'
    Assert ((Get-Trimmed (Join-Path $y5 'debloater.reg')) -eq 'REG_LIVE') 'T5 debloater.reg protected (not overwritten)'
    $skippedOk = ($r5.Skipped -contains 'chrome++.ini') -and ($r5.Skipped -contains 'update.bat') -and
                 ($r5.Skipped -contains 'debloater.reg') -and ($r5.Skipped -contains 'version.txt')
    Assert $skippedOk "T5 Skipped lists all 4 protected files (got: $($r5.Skipped -join ','))"

    Assert ((Get-Trimmed (Join-Path $y5 'browser.exe')) -eq 'new-browser') 'T5 browser.exe updated from staged tree'
    Assert (Test-Path (Join-Path $y5 'added.txt')) 'T5 new staged file copied over'
    Assert (Test-Path (Join-Path $y5 'legacy-only.txt')) 'T5 live-only file kept (no wipe)'
    Assert ((Get-Trimmed (Join-Path (Join-Path $pkg5 'Data') 'sentinel.txt')) -eq 'profile-data') 'T5 package-root Data\ untouched'
    Assert ((Get-Trimmed (Join-Path (Join-Path $pkg5 'Cache') 'sentinel.txt')) -eq 'cache-data') 'T5 package-root Cache\ untouched'
    Assert (-not (Test-Path (Join-Path $y5 'Data'))) 'T5 staged Yandex\Data refused (never-touch guard)'
    Assert ($r5.Skipped -contains 'Data') 'T5 Data listed as skipped'

    $marker = Get-Trimmed (Join-Path $pkg5 'builder-invoked.txt')
    Assert ($marker -match 'Version=2\.0\.0\.0') 'T5 build-yandex.ps1 invoked with -Version <latest>'
    Assert ($marker -match 'Installer=.') 'T5 build-yandex.ps1 invoked with -Installer <downloaded>'
    Assert ($marker -match 'OutDir=.') 'T5 build-yandex.ps1 invoked with -OutDir <temp>'
    Assert ($script:downloadCount -eq 1) 'T5 installer downloaded exactly once'
    Assert (($script:promptLog -join '|') -match 'update\?') 'T5 confirm Read-Host prompt shown'

    Assert ($r5.CdmState -eq 'migrated') "T5 CdmState = migrated (got: $($r5.CdmState))"
    Assert (Test-Path (Join-Path (Join-Path $y5 'WidevineCdm') 'manifest.json')) 'T5 nested WidevineCdm moved FLAT to Yandex\WidevineCdm'
    Assert (-not (Test-Path (Join-Path (Join-Path $y5 '9.9.9') 'WidevineCdm'))) 'T5 versioned CDM nesting removed'
    Assert (-not (Test-Path (Join-Path $y5 'service_update.exe'))) 'T5 reintroduced service_update.exe stripped'
    Assert ($r5.BrowserExe -eq $true) 'T5 summary flag: browser.exe present after update'
    Assert ($r5.PolicyStatus -and ($r5.PolicyStatus -ne 'missing')) "T5 debloater.reg re-import attempted (status: $($r5.PolicyStatus))"
    if (-not (Get-Command reg -ErrorAction SilentlyContinue)) {
        Assert ($r5.PolicyStatus -eq 'failed-exception') 'T5 no reg on this host -> warn-and-continue (update still succeeds)'
    }

    Assert (Test-Path (Join-Path $y5 'version.dll')) 'T5 version.dll copied (DLL-era output)'
    Assert ((Get-Trimmed (Join-Path $pkg5 'launch.bat')) -eq 'LIVE_LAUNCH') 'T5 package-root launch.bat untouched (copy scope = Yandex\ only)'
    $tempAfter = Get-ChildDirCount 'yandex-update-*'
    Assert ($tempAfter -le $tempBefore) "T5 temp workspace cleaned up ($tempBefore -> $tempAfter)"

    # ---- T6: up-to-date short-circuit ----
    Write-Host '== T6: up-to-date short-circuit =='
    $pkg6 = Join-Path $work 'pkg6'
    $y6   = New-LivePackage $pkg6 '2.0.0.0'
    $script:promptLog   = @()
    $script:downloadCount = 0
    $r6 = $null
    $err6 = $null
    try { $r6 = Invoke-UpdateFlow -AppDir $y6 } catch { $err6 = $_.Exception.Message }
    Assert ($null -eq $err6) "T6 no error when up to date (got: $err6)"
    Assert ($r6.Outcome -eq 'Uptodate') "T6 outcome = Uptodate (got: $($r6.Outcome))"
    Assert ($script:downloadCount -eq 0) 'T6 no download when up to date'
    Assert ($script:promptLog.Count -eq 0) 'T6 no confirm prompt when up to date'
    Assert (-not (Test-Path (Join-Path $pkg6 'builder-invoked.txt'))) 'T6 builder not invoked when up to date'
    Assert ((Get-Trimmed (Join-Path $y6 'version.txt')) -eq '2.0.0.0') 'T6 version.txt untouched'

    # ---- T7: declined confirm ----
    Write-Host '== T7: declined confirm =='
    $pkg7 = Join-Path $work 'pkg7'
    $y7   = New-LivePackage $pkg7 '1.0.0.0'
    $script:promptLog   = @()
    $script:downloadCount = 0
    $script:promptQueue.Clear()
    $script:promptQueue.Enqueue('')
    $r7 = $null
    $err7 = $null
    try { $r7 = Invoke-UpdateFlow -AppDir $y7 } catch { $err7 = $_.Exception.Message }
    Assert ($null -eq $err7) "T7 no error on decline (got: $err7)"
    Assert ($r7.Outcome -eq 'Declined') "T7 outcome = Declined (got: $($r7.Outcome))"
    Assert ($script:downloadCount -eq 0) 'T7 no download after decline'
    Assert (-not (Test-Path (Join-Path $pkg7 'builder-invoked.txt'))) 'T7 builder not invoked after decline'
    Assert ((Get-Trimmed (Join-Path $y7 'version.txt')) -eq '1.0.0.0') 'T7 version.txt unchanged after decline'

    # ---- T8: debloater.reg re-import (reg stub = admin path) ----
    Write-Host '== T8: debloater.reg re-import (reg stub) =='
    $script:regArgs = @()
    function reg {
        $script:regArgs += ($args -join ' ')
        $global:LASTEXITCODE = 0
        return
    }
    $pkg8 = Join-Path $work 'pkg8'
    $y8   = New-LivePackage $pkg8 '1.0.0.0'
    $script:promptLog = @()
    $r8 = $null
    $err8 = $null
    try { $r8 = Invoke-UpdateFlow -AppDir $y8 } catch { $err8 = $_.Exception.Message }
    Assert ($null -eq $err8) "T8 update completes with reg available (got: $err8)"
    Assert ($r8.PolicyStatus -eq 'applied') "T8 PolicyStatus = applied (got: $($r8.PolicyStatus))"
    Assert ($script:regArgs.Count -eq 1) "T8 reg invoked exactly once (got $($script:regArgs.Count))"
    Assert (($script:regArgs -join ' ') -like '*debloater.reg*') 'T8 reg import targets the live debloater.reg'

    # ---- T9: CDM migration with pre-existing flat dir (merge case) ----
    Write-Host '== T9: flat CDM migration (merge + stale updater) =='
    $y9 = Join-Path (Join-Path $work 'pkg9') 'Yandex'
    New-Tree $y9 @{
        'browser.exe'                              = 'b'
        'WidevineCdm/manifest.json'                = '{"cdm":"flat-old"}'
        'WidevineCdm/_platform_specific/keep.txt'  = 'flat-keep'
        '25.1.2.3/WidevineCdm/manifest.json'       = '{"cdm":"nested-new"}'
        '25.1.2.3/WidevineCdm/_platform_specific/win_x64/widevinecdm.dll' = 'nested-dll'
        'service_update.exe'                       = 'stale'
    }
    $state9 = $null
    $err9 = $null
    try { $state9 = Update-CdmLayout -YandexDir $y9 } catch { $err9 = $_.Exception.Message }
    Assert ($null -eq $err9) "T9 migration runs without error (got: $err9)"
    Assert ($state9 -eq 'migrated') "T9 state = migrated (got: $state9)"
    Assert ((Get-Trimmed (Join-Path (Join-Path $y9 'WidevineCdm') 'manifest.json')) -eq '{"cdm":"nested-new"}') 'T9 nested manifest merged into flat'
    Assert (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $y9 'WidevineCdm') '_platform_specific') 'win_x64') 'widevinecdm.dll')) 'T9 nested CDM binary merged into flat tree'
    Assert (Test-Path (Join-Path (Join-Path (Join-Path $y9 'WidevineCdm') '_platform_specific') 'keep.txt')) 'T9 pre-existing flat files kept on merge'
    Assert (-not (Test-Path (Join-Path (Join-Path $y9 '25.1.2.3') 'WidevineCdm'))) 'T9 versioned dir removed after migration'
    Assert (-not (Test-Path (Join-Path $y9 'service_update.exe'))) 'T9 stale service_update.exe stripped'

    # ---- T10: CDM layout already clean (no-op) ----
    Write-Host '== T10: flat CDM layout already clean =='
    $y10 = Join-Path (Join-Path $work 'pkg10') 'Yandex'
    New-Tree $y10 @{
        'browser.exe'               = 'b'
        'WidevineCdm/manifest.json' = '{"cdm":"flat"}'
    }
    $state10 = Update-CdmLayout -YandexDir $y10
    Assert ($state10 -eq 'flat-present') "T10 state = flat-present on clean tree (got: $state10)"
    Assert ((Get-Trimmed (Join-Path (Join-Path $y10 'WidevineCdm') 'manifest.json')) -eq '{"cdm":"flat"}') 'T10 flat CDM untouched'
    $y10b = Join-Path (Join-Path $work 'pkg10b') 'Yandex'
    New-Tree $y10b @{ 'browser.exe' = 'b' }
    $state10b = Update-CdmLayout -YandexDir $y10b
    Assert ($state10b -eq 'absent') "T10 state = absent when no CDM shipped (got: $state10b)"

    # ---- T12: missing builder fails fast, version not rewritten ----
    Write-Host '== T12: build-yandex.ps1 missing at package root =='
    $pkg12 = Join-Path $work 'pkg12'
    $y12   = New-LivePackage $pkg12 '1.0.0.0'
    Remove-Item -LiteralPath (Join-Path $pkg12 'build-yandex.ps1') -Force
    $script:promptLog   = @()
    $script:downloadCount = 0
    $err12 = $null
    try { $null = Invoke-UpdateFlow -AppDir $y12 } catch { $err12 = $_.Exception.Message }
    Assert ($err12 -match 'build-yandex\.ps1 not found') "T12 clear missing-builder error (got: $err12)"
    Assert ($script:downloadCount -eq 0) 'T12 no download attempted without the builder'
    Assert ((Get-Trimmed (Join-Path $y12 'version.txt')) -eq '1.0.0.0') 'T12 version.txt not rewritten on failure'

    # ---- T13: builder failure propagates, temp cleaned, version untouched ----
    Write-Host '== T13: builder exit 1 propagates =='
    $pkg13 = Join-Path $work 'pkg13'
    $y13   = New-LivePackage $pkg13 '1.0.0.0'
    New-FakeBuilder $pkg13 -Fail
    $script:promptLog = @()
    $tempBefore13 = Get-ChildDirCount 'yandex-update-*'
    $err13 = $null
    try { $null = Invoke-UpdateFlow -AppDir $y13 } catch { $err13 = $_.Exception.Message }
    Assert ($err13 -match 'build-yandex\.ps1 failed') "T13 builder failure propagates (got: $err13)"
    Assert ((Get-Trimmed (Join-Path $y13 'version.txt')) -eq '1.0.0.0') 'T13 version.txt not rewritten when builder fails'
    $tempAfter13 = Get-ChildDirCount 'yandex-update-*'
    Assert ($tempAfter13 -le $tempBefore13) "T13 temp workspace cleaned up after failure ($tempBefore13 -> $tempAfter13)"
}

# ------------------------------------------------------------------ report --

try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passed, $script:failed)
foreach ($f in $script:failure) { Write-Host "  FAILED: $f" -ForegroundColor Red }
if ($script:failed -gt 0) { exit 1 }
exit 0
