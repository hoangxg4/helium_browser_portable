param(
    [string]$Installer,
    [switch]$Download,
    [string]$Version,
    [string]$OutDir,
    [string]$ChromePlusUrl = 'https://github.com/bibicadotnet/Chromium_SetDLL/releases/download/1.18.2/Chrome.2B.2B_v1.18.2_x86_x64_arm64.7z'
)

<#
    build-yandex.ps1 - Yandex Browser Portable builder (Task 3: extract, layout,
    version.txt, strip updater, spike reconciliation).

    Stages (design section 3, idempotent):
      1. Resolve source  - -Installer <path> (user-supplied) or -Download (CI, public
                           CDN). The winget PackageVersion passed via -Version is the
                           SOLE source of truth for the release tag, zip name and
                           version.txt; a version read back from the binary is a
                           log-only cross-check. -Download builds the CDN candidate
                           URL from -Version (digits joined by _), HEAD-verifies it
                           and falls back to the winget manifest InstallerUrl.
      2. Extract         - spike P1 branch A (outer exe resource archive: 7z payload
                           of Yandex.exe -> nested browser.7z/BROWSER.PACKED.7Z) and
                           branch B (post-silent-install tree with
                           Installer\browser.7z). Hard-fails naming BOTH branches
                           when neither yields browser.exe.
      3. Layout          - Yandex_Portable\{Yandex\..., Data\, Cache\}; copy
                           chrome++.ini/debloater.reg/update.bat into Yandex\, this
                           script to the package root (update.bat calls
                           $APP_DIR\..\build-yandex.ps1), write version.txt, apply
                           the flat CDM rule (Yandex\WidevineCdm next to
                           browser.exe - Chrome registers the preinstalled CDM only
                           from the exe-dir flat path), place Chrome++ version.dll
                           next to browser.exe with a launch.bat --user-data-dir
                           fallback (spike P2/P2b), then write layout-manifest.txt.
      4. Debloat         - profile preseed: copy preseed/Local State ->
                           Data\Local State, preseed/Preferences ->
                           Data\Default\Preferences, empty "First Run" sentinel
                           -> Data\ (prefs-only path, works without admin -
                           review fix #10; without the sentinel Yandex discards
                           hand-made profile files). debloater.reg itself is
                           applied outside this builder (admin import / CI
                           smoke validation).
      5. Strip updater   - remove service_update.exe / yupdate-exec.exe;
                           UpdateAllowed=0 and BackgroundUpdateAllowed=0 are already
                           carried by debloater.reg.

    Never: SafeBrowsingProtectionLevel, ComponentUpdatesEnabled, component updates
    switched off on the command line (breaks Widevine/DRM), security updates beyond
    the UpdateAllowed rationale, any bundled certificates.
#>

# ------------------------------------------------------------------ helpers --

function Get-CdnCandidateUrl([string]$version) {
    # CDN pattern from the winget manifest (e.g. 26.8.4.893 -> 26_8_4_893);
    # live releases carry an extra _build suffix, so this is only a candidate.
    $flat = $version -replace '\.', '_'
    return "https://download.cdn.yandex.net/browser/int/$flat/en/Yandex.exe"
}

function Test-Url([string]$uri) {
    try {
        $r = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5 -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
    }
    catch {
        return $false
    }
}

function Resolve-ManifestUrl([string]$version) {
    # winget manifest is authoritative for the exact InstallerUrl (it carries the
    # CDN _build suffix the bare pattern cannot guess).
    $manifestUrl = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/y/Yandex/Browser/$version/Yandex.Browser.installer.yaml"
    $manifest = Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    if ($manifest.Content -notmatch '(?m)^\s*InstallerUrl:\s*(\S+)\s*$') {
        throw "winget manifest for $version has no InstallerUrl (checked $manifestUrl)"
    }
    $url = $Matches[1]
    if (-not (Test-Url $url)) {
        Write-Host "note: HEAD did not confirm $url (CDN may reject HEAD) - download will verify it"
    }
    return $url
}

function Invoke-SevenZipExtract([string]$archive, [string]$dest) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & 7z x $archive "-o$dest" -y | Out-Null
    return ($LASTEXITCODE -le 1)
}

function Find-BrowserRoot([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $exe = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'browser.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($exe) { return $exe.Directory.FullName }
    return $null
}

function Find-NestedBrowserArchive([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $hit = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(browser\.7z|browser\.packed\.7z)$' } |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Resolve-ChromePlusDll([string]$source, [string]$workDir) {
    # spike P2: pinned Chrome++ version.dll (x64) loaded side-by-side with
    # browser.exe relocates Data/Cache per chrome++.ini. Any failure (offline,
    # archive changed) returns $null -> launch.bat fallback.
    try {
        $archive = $null
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $archive = $source
        }
        elseif ($source -match '^https?://') {
            $archive = Join-Path $workDir 'chromeplus.7z'
            Invoke-WebRequest -Uri $source -OutFile $archive -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
        }
        else {
            Write-Host "Chrome++: version.dll source not found: $source"
            return $null
        }
        $cppDir = Join-Path $workDir 'chromeplus'
        if (-not (Invoke-SevenZipExtract $archive $cppDir)) {
            Write-Host 'Chrome++: version.dll archive could not be extracted'
            return $null
        }
        $candidates = @(Get-ChildItem -LiteralPath $cppDir -Recurse -File -Filter 'version.dll' -ErrorAction SilentlyContinue)
        if ($candidates.Count -eq 0) {
            Write-Host 'Chrome++: version.dll missing from archive'
            return $null
        }
        $x64 = @($candidates | Where-Object { $_.FullName -match '[\\/]x64[\\/]' })
        if ($x64.Count -gt 0) { $pick = $x64[0] } else { $pick = $candidates[0] }
        Write-Host "Chrome++: version.dll candidate $($pick.FullName)"
        return $pick.FullName
    }
    catch {
        Write-Host "Chrome++: version.dll unavailable ($($_.Exception.Message))"
        return $null
    }
}

# Dot-source (tests) loads only the functions above; a direct run continues.
if ($MyInvocation.InvocationName -eq '.') { return }

# ------------------------------------------------------------ stage 1: source

if ($Download) {
    if (-not $Version) {
        Write-Error '-Download requires -Version <winget PackageVersion> (sole source of truth for tag/zip/version.txt)'
        exit 1
    }
    $candidate = Get-CdnCandidateUrl $Version
    if (Test-Url $candidate) {
        $installerUrl = $candidate
        Write-Host "stage 1: InstallerUrl from CDN pattern: $installerUrl"
    }
    else {
        Write-Host "stage 1: CDN candidate not live (HEAD failed): $candidate - falling back to winget manifest"
        try {
            $installerUrl = Resolve-ManifestUrl $Version
        }
        catch {
            Write-Error "stage 1: cannot resolve InstallerUrl for version $Version - $($_.Exception.Message)"
            exit 1
        }
        Write-Host "stage 1: InstallerUrl from winget manifest: $installerUrl"
    }
    $downloaded = Join-Path ([IO.Path]::GetTempPath()) ("Yandex-" + $Version + ".exe")
    Write-Host "stage 1: downloading $installerUrl -> $downloaded"
    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $downloaded -TimeoutSec 900 -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Error "stage 1: download failed: $($_.Exception.Message)"
        exit 1
    }
    $Installer = $downloaded
}
else {
    if (-not $Installer) {
        Write-Error 'pass -Installer <Yandex.exe | silent-install dir> or -Download -Version <winget PackageVersion>'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Installer)) {
        Write-Error "stage 1: installer path not found: $Installer"
        exit 1
    }
    Write-Host "stage 1: Installer=$Installer"
}

if (-not $Version) {
    Write-Error 'pass -Version <winget PackageVersion> (winget PackageVersion is the sole version source of truth)'
    exit 1
}

if (-not $OutDir) { $OutDir = Join-Path (Get-Location).Path 'Yandex_Portable' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
Write-Host "stage 1: version=$Version OutDir=$OutDir"

if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
    Write-Error 'stage 2: 7z not found in PATH - install p7zip/7-Zip first'
    exit 1
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('yandex-build-' + [guid]::NewGuid().ToString('N'))
$exitCode = 0

try {
    # ------------------------------------------------------- stage 2: extract
    $appRoot = $null

    if (Test-Path -LiteralPath $Installer -PathType Container) {
        # Branch B - post-silent-install tree: Installer\browser.7z
        Write-Host "stage 2: branch B (post-silent-install) - scanning $Installer for Installer\browser.7z"
        $nested = Find-NestedBrowserArchive $Installer
        if ($nested -and (Invoke-SevenZipExtract $nested (Join-Path $work 'app'))) {
            $appRoot = Find-BrowserRoot (Join-Path $work 'app')
        }
        if (-not $appRoot) {
            $appRoot = Find-BrowserRoot $Installer
        }
    }
    else {
        # Branch A - outer exe resource archive (spike P1 verdict: PASS, branch A)
        Write-Host "stage 2: branch A (outer exe resource archive) - opening payload of $Installer"
        $outer = Join-Path $work 'outer'
        if (Invoke-SevenZipExtract $Installer $outer) {
            $appRoot = Find-BrowserRoot $outer
            if (-not $appRoot) {
                $nested = Find-NestedBrowserArchive $outer
                if ($nested -and (Invoke-SevenZipExtract $nested (Join-Path $work 'app'))) {
                    $appRoot = Find-BrowserRoot (Join-Path $work 'app')
                }
            }
        }
        else {
            Write-Host "stage 2: branch A could not open the archive - will report both branches if nothing matches"
        }
    }

    if (-not $appRoot) {
        Write-Error ("build-yandex.ps1: no browser.exe found - neither extraction branch matched. " +
            "Branch A (outer exe resource archive): the Yandex.exe payload is a 7z archive containing a nested browser.7z/BROWSER.PACKED.7Z. " +
            "Branch B (post-silent-install): a silent-install tree containing Installer\browser.7z. " +
            "Pass -Installer <Yandex.exe | install dir> that contains one of them.")
        exit 1
    }
    Write-Host "stage 2: app root = $appRoot"

    # --------------------------------------------------------- stage 3: layout
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $yandexDir = Join-Path $OutDir 'Yandex'
    if (Test-Path -LiteralPath $yandexDir) {
        Remove-Item -LiteralPath $yandexDir -Recurse -Force   # idempotent rebuild; Data\ and Cache\ are kept
    }
    New-Item -ItemType Directory -Path $yandexDir -Force | Out-Null

    Get-ChildItem -LiteralPath $appRoot -Force | Copy-Item -Destination $yandexDir -Recurse -Force

    # Flat CDM rule: Chrome registers the preinstalled WidevineCdm only from the
    # exe-dir flat path - any versioned Yandex\<ver>\WidevineCdm nesting is dead.
    $flatCdm = Join-Path $yandexDir 'WidevineCdm'
    $nestedCdm = @(Get-ChildItem -LiteralPath $yandexDir -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'WidevineCdm' -and $_.FullName -ne $flatCdm })
    foreach ($n in $nestedCdm) {
        if (-not (Test-Path -LiteralPath $flatCdm)) {
            Move-Item -LiteralPath $n.FullName -Destination $flatCdm
        }
        else {
            Get-ChildItem -LiteralPath $n.FullName | Move-Item -Destination $flatCdm -Force
            Remove-Item -LiteralPath $n.FullName -Recurse -Force
        }
        Write-Host "stage 3: WidevineCdm moved to flat Yandex\WidevineCdm (exe-dir rule)"
    }
    $badCdm = @(Get-ChildItem -LiteralPath $yandexDir -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'WidevineCdm' -and $_.FullName -ne $flatCdm })
    if ($badCdm.Count -gt 0) {
        Write-Error "stage 3: versioned WidevineCdm nesting still present after layout ($($badCdm[0].FullName)) - aborting"
        exit 1
    }

    foreach ($f in 'chrome++.ini', 'debloater.reg', 'update.bat') {
        # Shipped packages carry these inside Yandex\ already (and the update
        # flow treats them as protected), so a missing source here is expected
        # when rebuilding from an extracted package - not an error.
        $src = Join-Path $PSScriptRoot $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $yandexDir -Force
        }
    }

    # update.bat invokes $APP_DIR\..\build-yandex.ps1 - ship this script at the
    # package root, as a sibling of Yandex\.
    $selfDest = Join-Path $OutDir 'build-yandex.ps1'
    if ($selfDest -ne $PSCommandPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $selfDest -Force
    }

    # version.txt - winget PackageVersion from the caller, never binary-parsed.
    Set-Content -Path (Join-Path $yandexDir 'version.txt') -Value $Version

    $browserExe = Join-Path $yandexDir 'browser.exe'
    if (-not (Test-Path -LiteralPath $browserExe)) {
        Write-Error "stage 3: browser.exe missing in $yandexDir - aborting"
        exit 1
    }
    try {
        $binaryVersion = (Get-Item -LiteralPath $browserExe).VersionInfo.FileVersion
    }
    catch {
        $binaryVersion = ''
    }
    if ($binaryVersion) {
        Write-Host "stage 3: cross-check binary version=$binaryVersion (log only; version.txt stays winget PackageVersion $Version)"
    }
    else {
        Write-Host "stage 3: cross-check binary version unavailable (log only; version.txt stays winget PackageVersion $Version)"
    }

    New-Item -ItemType Directory -Path (Join-Path $OutDir 'Data') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $OutDir 'Cache') -Force | Out-Null

    # Chrome++ branch (spike P2 PASS): version.dll next to browser.exe, else the
    # launch.bat --user-data-dir fallback (Tensionix precedent).
    $dll = Resolve-ChromePlusDll $ChromePlusUrl $work
    if ($dll) {
        Copy-Item -LiteralPath $dll -Destination (Join-Path $yandexDir 'version.dll') -Force
        Write-Host 'stage 3: version.dll placed next to browser.exe (Chrome++ portable Data/Cache)'
    }
    else {
        $launchBody = '@echo off' + "`r`n" +
            'start "" "%~dp0Yandex\browser.exe" --user-data-dir="%~dp0Data" %*' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $OutDir 'launch.bat'), $launchBody)
        Write-Host 'stage 3: version.dll unavailable - wrote launch.bat fallback (--user-data-dir launcher)'
    }

    # ------------------------------------------------ stage 4: profile preseed
    # Prefs-only debloat path (review fix #10) - no admin rights needed. The
    # empty "First Run" sentinel must ship with the JSON, otherwise Yandex
    # treats hand-made profile files as corrupted and regenerates defaults.
    $preseedSrc   = Join-Path $PSScriptRoot 'preseed'
    $preseedFiles = @('Local State', 'Preferences', 'First Run')
    foreach ($pf in $preseedFiles) {
        $pfPath = Join-Path $preseedSrc $pf
        if (-not (Test-Path -LiteralPath $pfPath)) {
            Write-Error "stage 4: missing preseed file: $pfPath"
            exit 1
        }
    }
    $dataDir    = Join-Path $OutDir 'Data'
    $defaultDir = Join-Path $dataDir 'Default'
    New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $preseedSrc 'Local State') -Destination (Join-Path $dataDir 'Local State') -Force
    Copy-Item -LiteralPath (Join-Path $preseedSrc 'Preferences') -Destination (Join-Path $defaultDir 'Preferences') -Force
    Copy-Item -LiteralPath (Join-Path $preseedSrc 'First Run') -Destination (Join-Path $dataDir 'First Run') -Force
    # Ship the preseed sources next to this script at the package root so
    # update.bat-triggered rebuilds ($APP_DIR\..\build-yandex.ps1) stay self-contained.
    $preseedOut = Join-Path $OutDir 'preseed'
    New-Item -ItemType Directory -Path $preseedOut -Force | Out-Null
    foreach ($pf in $preseedFiles) {
        Copy-Item -LiteralPath (Join-Path $preseedSrc $pf) -Destination $preseedOut -Force
    }
    Write-Host 'stage 4: preseed applied -> Data\Local State, Data\Default\Preferences, Data\First Run (source preseed\ shipped at package root)'

    # -------------------------------------------------- stage 5: strip updater
    foreach ($updater in 'service_update.exe', 'yupdate-exec.exe') {
        $found = @(Get-ChildItem -LiteralPath $yandexDir -Recurse -File -Filter $updater -ErrorAction SilentlyContinue)
        foreach ($u in $found) {
            Remove-Item -LiteralPath $u.FullName -Force
            Write-Host "stage 5: stripped updater $($u.Name)"
        }
    }

    # --------------------------------------------------------- layout manifest
    $manifestLines = @(
        'build-yandex.ps1 layout manifest'
        "version=$Version"
        ''
        '[package root]'
    )
    Get-ChildItem -LiteralPath $OutDir -Force |
        Where-Object { $_.Name -ne 'layout-manifest.txt' } |
        Sort-Object Name |
        ForEach-Object {
            if ($_.PSIsContainer) { $manifestLines += "  $($_.Name)\" } else { $manifestLines += "  $($_.Name)" }
        }
    $manifestLines += '[Yandex]'
    Get-ChildItem -LiteralPath $yandexDir -Force | Sort-Object Name | ForEach-Object {
        if ($_.PSIsContainer) { $manifestLines += "  $($_.Name)\" } else { $manifestLines += "  $($_.Name)" }
    }
    if (Test-Path -LiteralPath $flatCdm) {
        $manifestLines += 'WidevineCdm=Yandex\WidevineCdm (flat, next to browser.exe)'
    }
    else {
        $manifestLines += 'WidevineCdm=ABSENT (runtime component registration only)'
    }
    Set-Content -Path (Join-Path $OutDir 'layout-manifest.txt') -Value ($manifestLines -join "`n")
    Write-Host "layout: manifest written: $(Join-Path $OutDir 'layout-manifest.txt')"
}
catch {
    Write-Error "build-yandex.ps1: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($exitCode -ne 0) { exit $exitCode }
Write-Host "build-yandex.ps1: done - package at $OutDir"
exit 0
