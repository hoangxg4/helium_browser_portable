# tests/build-yandex.tests.ps1 — behavior tests for build-yandex.ps1 (Task 03)
#
# Run:  pwsh -NoProfile -File tests/build-yandex.tests.ps1
# Needs: pwsh 7+, 7z (p7zip) in PATH. No network required (Chrome++ stage is
# fed local fixture archives, and the -Download path is only tested for its
# missing-Version guard).

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$builder  = Join-Path $repoRoot 'build-yandex.ps1'
$pwshExe  = (Get-Process -Id $PID).Path
$CdnPattern = 'https://download.cdn.yandex.net/browser/int/26_8_4_893/en/Yandex.exe'

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

$work = Join-Path ([IO.Path]::GetTempPath()) ('ybx-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---------------------------------------------------------------- fixtures --

function New-Tree([string]$root, [hashtable]$files) {
    foreach ($rel in $files.Keys) {
        $p = Join-Path $root ($rel -replace '/', [string][IO.Path]::DirectorySeparatorChar)
        $d = Split-Path -Parent $p
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Set-Content -Path $p -Value $files[$rel] -NoNewline
    }
}

function Compress([string]$cwd, [string[]]$entries, [string]$archive) {
    Push-Location $cwd
    try {
        & 7z a -t7z -y $archive @entries | Out-Null
        if ($LASTEXITCODE -gt 1) { throw "7z a failed (exit $LASTEXITCODE) for $archive" }
    }
    finally { Pop-Location }
}

# Branch A fixture: Yandex.exe (7z) -> x_browser/browser.7z -> Browser-bin/...
# Contains a NESTED WidevineCdm and both updater exes so layout/strip are exercised.
function New-FixtureBranchA([string]$root) {
    $inner = Join-Path $root 'inner-src'
    New-Tree $inner @{
        'Browser-bin/browser.exe'                    = 'fake-browser-binary'
        'Browser-bin/browser_proxy.exe'              = 'fake-proxy'
        'Browser-bin/clids_yandex.xml'               = '<clid/>'
        'Browser-bin/26.8.4.893/browser.dll'         = 'fake-dll'
        'Browser-bin/26.8.4.893/WidevineCdm/manifest.json' = '{"name":"widevine-cdm"}'
        'Browser-bin/service_update.exe'             = 'updater'
        'Browser-bin/yupdate-exec.exe'               = 'updater'
    }
    $innerArch = Join-Path $root 'browser.7z'
    Compress $inner @('Browser-bin') $innerArch

    $outer = Join-Path $root 'outer-src'
    New-Item -ItemType Directory -Path (Join-Path $outer 'x_browser') -Force | Out-Null
    Copy-Item $innerArch (Join-Path (Join-Path $outer 'x_browser') 'browser.7z')
    $exe = Join-Path $root 'Yandex.exe'
    Compress $outer @('x_browser') $exe
    return $exe
}

# Branch B fixture: a post-silent-install tree containing Installer\browser.7z.
function New-FixtureBranchB([string]$root) {
    $inner = Join-Path $root 'b-inner-src'
    New-Tree $inner @{ 'Browser-bin/browser.exe' = 'fake-browser-binary-b' }
    $inst = Join-Path $root 'postinstall'
    $inst = Join-Path $inst 'Installer'
    New-Item -ItemType Directory -Path $inst -Force | Out-Null
    Compress $inner @('Browser-bin') (Join-Path $inst 'browser.7z')
    return (Join-Path $root 'postinstall')
}

# Archive with no browser payload at all (neither branch can match).
function New-FixtureNoBrowser([string]$root) {
    $src = Join-Path $root 'nobrowser-src'
    New-Tree $src @{ 'readme.txt' = 'no browser here' }
    $exe = Join-Path $root 'YandexNoPayload.exe'
    Compress $src @('readme.txt') $exe
    return $exe
}

# Local Chrome++ archive fixture (x64/App/version.dll, same shape as the pinned release).
function New-FixtureChromePlus([string]$root) {
    $src = Join-Path $root 'cpp-src'
    New-Tree $src @{ 'x64/App/version.dll' = 'fake-version-dll' }
    $arch = Join-Path $root 'chromeplus.7z'
    Compress $src @('x64') $arch
    return $arch
}

# ----------------------------------------------------------------- helpers --

function Invoke-Builder([string[]]$argList) {
    $output = & $pwshExe -NoProfile -File $builder @argList 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Get-TreePaths([string]$root) {
    if (-not (Test-Path $root)) { return @() }
    return @(Get-ChildItem -Path $root -Recurse -Force | ForEach-Object {
        $_.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
    })
}

$Version    = '26.8.4.893'
$fixA       = New-FixtureBranchA (Join-Path $work 'fixtureA')
$fixB       = New-FixtureBranchB (Join-Path $work 'fixtureB')
$fixNo      = New-FixtureNoBrowser (Join-Path $work 'fixtureNo')
$fixCpp     = New-FixtureChromePlus $work
$missingCpp = Join-Path $work 'definitely-missing-chromeplus.7z'

# ------------------------------------------------------------------- tests --

Write-Host '== T1: branch A extract + layout =='
$out1 = Join-Path $work 'out1'
$r1 = Invoke-Builder @('-Installer', $fixA, '-Version', $Version, '-OutDir', $out1, '-ChromePlusUrl', $fixCpp)
Assert ($r1.ExitCode -eq 0) "T1 builder exits 0 (got $($r1.ExitCode))"
Assert (Test-Path (Join-Path $out1 'Yandex/browser.exe')) 'T1 Yandex\browser.exe laid out'
Assert (Test-Path (Join-Path $out1 'Yandex/version.txt')) 'T1 Yandex\version.txt written'
$vtxt = Join-Path $out1 'Yandex/version.txt'
Assert ((Test-Path $vtxt) -and ((Get-Content $vtxt -Raw).Trim() -eq $Version)) 'T1 version.txt == winget PackageVersion passed by caller'
foreach ($f in 'chrome++.ini', 'debloater.reg', 'update.bat') {
    Assert (Test-Path (Join-Path $out1 "Yandex/$f")) "T1 copied $f into Yandex\"
}
Assert (Test-Path (Join-Path $out1 'build-yandex.ps1')) 'T1 build-yandex.ps1 copied to package ROOT (update.bat runtime dependency)'
Assert (Test-Path (Join-Path $out1 'Data')) 'T1 Data\ created at OutDir root'
Assert (Test-Path (Join-Path $out1 'Cache')) 'T1 Cache\ created at OutDir root'
Assert ($r1.Output -match 'cross-check') 'T1 binary version logged as cross-check only'

Write-Host '== T2: flat WidevineCdm rule (review fix #12) =='
$paths1 = Get-TreePaths $out1
Assert ($paths1 -contains 'Yandex/WidevineCdm/manifest.json') 'T2 WidevineCdm moved FLAT to Yandex\WidevineCdm'
Assert (-not ($paths1 | Where-Object { $_ -match '^Yandex/.+/WidevineCdm/' })) 'T2 no Yandex\*\WidevineCdm versioned nesting remains'

Write-Host '== T3: strip updater =='
$paths3 = Get-TreePaths (Join-Path $out1 'Yandex')
Assert (-not ($paths3 -contains 'service_update.exe')) 'T3 service_update.exe stripped'
Assert (-not ($paths3 -contains 'yupdate-exec.exe')) 'T3 yupdate-exec.exe stripped'
Assert ($r1.Output -match 'service_update') 'T3 strip deletion logged'

Write-Host '== T4: Chrome++ branch — pinned version.dll path =='
$out4a = Join-Path $work 'out4a'
$r4a = Invoke-Builder @('-Installer', $fixA, '-Version', $Version, '-OutDir', $out4a, '-ChromePlusUrl', $fixCpp)
Assert ($r4a.ExitCode -eq 0) "T4a builder exits 0 (got $($r4a.ExitCode))"
Assert (Test-Path (Join-Path $out4a 'Yandex/version.dll')) 'T4a version.dll placed next to browser.exe'
Assert (-not (Test-Path (Join-Path $out4a 'launch.bat'))) 'T4a no launch.bat when version.dll loaded (XOR)'

Write-Host '== T5: Chrome++ fallback — launch.bat path =='
$out4b = Join-Path $work 'out4b'
$r4b = Invoke-Builder @('-Installer', $fixA, '-Version', $Version, '-OutDir', $out4b, '-ChromePlusUrl', $missingCpp)
Assert ($r4b.ExitCode -eq 0) "T5 builder exits 0 on Chrome++ failure (got $($r4b.ExitCode))"
$launch = Join-Path $out4b 'launch.bat'
Assert (Test-Path $launch) 'T5 launch.bat written when version.dll unavailable'
if (Test-Path $launch) {
    $lines = @(Get-Content $launch)
    Assert ($lines[0] -eq '@echo off') 'T5 launch.bat line 1 is @echo off'
    Assert ($lines[1] -eq 'start "" "%~dp0Yandex\browser.exe" --user-data-dir="%~dp0Data" %*') 'T5 launch.bat starts browser.exe with portable --user-data-dir'
    Assert (-not ((Get-Content $launch -Raw) -match 'disable-component-update')) 'T5 launch.bat has no --disable-component-update'
}
Assert ($r4b.Output -match 'version\.dll') 'T5 Chrome++ fallback logged'
Assert (-not (Test-Path (Join-Path $out4b 'Yandex/version.dll'))) 'T5 no version.dll when falling back (XOR)'

Write-Host '== T6: layout-manifest.txt =='
$manifest = Join-Path $out1 'layout-manifest.txt'
Assert (Test-Path $manifest) 'T6 layout-manifest.txt written at package root'
if (Test-Path $manifest) {
    $mtext = Get-Content $manifest -Raw
    Assert ($mtext -match 'browser\.exe') 'T6 manifest lists browser.exe'
    Assert ($mtext -match 'WidevineCdm') 'T6 manifest has a WidevineCdm line'
}

Write-Host '== T7: branch B (post-silent-install Installer\browser.7z) =='
$out7 = Join-Path $work 'out7'
$r7 = Invoke-Builder @('-Installer', $fixB, '-Version', $Version, '-OutDir', $out7, '-ChromePlusUrl', $fixCpp)
Assert ($r7.ExitCode -eq 0) "T7 builder exits 0 (got $($r7.ExitCode))"
Assert (Test-Path (Join-Path $out7 'Yandex/browser.exe')) 'T7 Yandex\browser.exe laid out from Installer\browser.7z'

Write-Host '== T8: hard-fail names BOTH extraction branches =='
$out8 = Join-Path $work 'out8'
$r8 = Invoke-Builder @('-Installer', $fixNo, '-Version', $Version, '-OutDir', $out8)
Assert ($r8.ExitCode -ne 0) 'T8 builder exits non-zero when neither branch matches'
Assert ($r8.Output -match 'browser\.exe') 'T8 error message mentions browser.exe'
Assert ($r8.Output -match 'Branch A') 'T8 error names branch A (outer exe resource archive)'
Assert ($r8.Output -match 'Branch B') 'T8 error names branch B (post-silent-install Installer\browser.7z)'
Assert (-not (Test-Path (Join-Path $out8 'Yandex/browser.exe'))) 'T8 no partial package left behind'

Write-Host '== T9: -Download requires -Version =='
$out9 = Join-Path $work 'out9'
$r9 = Invoke-Builder @('-Download', '-OutDir', $out9)
Assert ($r9.ExitCode -ne 0) 'T9 -Download without -Version exits non-zero'
Assert ($r9.Output -match '-Version') 'T9 error mentions -Version (winget PackageVersion)'

Write-Host '== T10: CDN URL construction is unit-testable =='
$definesFn = Select-String -Path $builder -Pattern 'function\s+Get-CdnCandidateUrl' -Quiet
Assert ($definesFn -eq $true) 'T10 build-yandex.ps1 exposes Get-CdnCandidateUrl (dot-source test seam)'
if ($definesFn) {
    # Dot-sourcing binds the builder's param() into THIS scope — save/restore
    # the test's variables around it.
    $saved = @{}
    foreach ($n in 'Version', 'Installer', 'OutDir', 'Download', 'ChromePlusUrl') {
        $saved[$n] = (Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue)
    }
    . $builder
    foreach ($n in $saved.Keys) {
        Set-Variable -Name $n -Value $saved[$n]
    }
    Assert ((Get-CdnCandidateUrl $Version) -eq $CdnPattern) 'T10 candidate URL = digits joined with _ in CDN pattern'
    try {
        $resolved = Resolve-ManifestUrl $Version
        Assert ($resolved -match '^https://download\.cdn\.yandex\.net/.+Yandex\.exe$') 'T10 winget manifest yields an InstallerUrl (live)'
    }
    catch {
        Fail "T10 winget manifest resolve threw: $($_.Exception.Message)"
    }
}

Write-Host '== T11: idempotent re-run =='
$r11 = Invoke-Builder @('-Installer', $fixA, '-Version', $Version, '-OutDir', $out1, '-ChromePlusUrl', $fixCpp)
Assert ($r11.ExitCode -eq 0) "T11 second run over existing OutDir exits 0 (got $($r11.ExitCode))"
Assert (Test-Path (Join-Path $out1 'Yandex/browser.exe')) 'T11 package still valid after re-run'
Assert (Test-Path (Join-Path $out1 'Data')) 'T11 Data\ preserved across re-run'

Write-Host '== T12: source invariants (plan Verify) =='
$src = Get-Content $builder -Raw
Assert ($src -match 'version\.txt') 'T12 source references version.txt'
Assert ($src -match 'WidevineCdm') 'T12 source references WidevineCdm'
Assert ($src -match 'service_update') 'T12 source references service_update'
Assert ($src -notmatch 'disable-component-update') 'T12 source never contains --disable-component-update'

# ------------------------------------------------------------------ report --

try { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:passed, $script:failed)
foreach ($f in $script:failure) { Write-Host "  FAILED: $f" -ForegroundColor Red }
if ($script:failed -gt 0) { exit 1 }
exit 0
