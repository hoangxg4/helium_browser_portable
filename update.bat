@echo off
setlocal
echo Yandex Browser Portable Updater v1.0.0
echo ==============================================
echo.
set "APP_DIR=%~dp0"
set "APP_DIR=%APP_DIR:~0,-1%"
set "PS1=%TEMP%\yandex_update.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSModulePath = $PSHOME + '\Modules;' + $env:PSModulePath; $env:APP_DIR='%APP_DIR%'; (Get-Content '%~f0' | Select-Object -Skip 11) | Out-File -Encoding utf8 '%PS1%'; & '%PS1%'"
set "RC=%ERRORLEVEL%" & del "%PS1%" 2>nul
exit /b %RC%
# ---------------------------------------------------------------------------
# update.bat PowerShell body - extracted by the batch header above
# (Select-Object -Skip 11). Keep that count exact.
# Ships INSIDE Yandex\: $APP_DIR is the Yandex\ dir; Data\ and Cache\ live at
# the package root (one level up: $APP_DIR\..\) and are NEVER touched.
# ---------------------------------------------------------------------------
# Files the update must never overwrite (Helium #5 protectedPaths lesson);
# version.txt is rewritten by this flow itself after a successful update.
$protectedPaths = @('chrome++.ini', 'update.bat', 'debloater.reg', 'version.txt')

# When update.bat is spawned from pwsh (smoke CI), powershell.exe 5.1 inherits
# pwsh's PSModulePath (Core paths first) and cannot auto-load Utility commands
# such as Get-FileHash (PowerShell issue #8635). The batch header prepends
# $PSHOME\Modules, and this .NET fallback keeps hashing working regardless.
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    function Get-FileHash {
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [string]$Algorithm = 'SHA256'
        )
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [IO.File]::OpenRead($LiteralPath)
        try {
            [pscustomobject]@{ Hash = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') }
        }
        finally {
            $fs.Dispose()
            $sha.Dispose()
        }
    }
}

function Read-UpdatePrompt([string]$Message) {
    # Single Read-Host wrapper: CI pipes `echo y| update.bat` (Helium pattern).
    Read-Host $Message
}

function Get-LatestPackageVersion {
    # winget-pkgs PackageVersion dirs are the same source of truth
    # build-yandex.ps1 trusts for tag/zip/version.txt (design section 3).
    $listUrl = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/y/Yandex/Browser'
    $hdrs = @{ 'User-Agent' = 'yandex-browser-portable-updater' }
    if ($env:GITHUB_TOKEN) { $hdrs['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $entries = Invoke-RestMethod -Uri $listUrl -Headers $hdrs
    $versions = @($entries | Where-Object { $_.type -eq 'dir' } | ForEach-Object {
        $v = $null
        if ([version]::TryParse($_.name, [ref]$v)) { [pscustomobject]@{ Name = $_.name; Version = $v } }
    })
    if ($versions.Count -eq 0) { throw "no winget PackageVersion directories under $listUrl" }
    return ($versions | Sort-Object Version -Descending | Select-Object -First 1).Name
}

function Resolve-InstallerUrl([string]$Latest, [string]$BuilderScript) {
    # Reuse the builder's URL helpers via dot-source (the builder has its own
    # dot-source guard) - no CDN/manifest logic duplicated in this script.
    . $BuilderScript
    $candidate = Get-CdnCandidateUrl $Latest
    if (Test-Url $candidate) {
        Write-Host "  InstallerUrl from CDN pattern: $candidate"
        return $candidate
    }
    Write-Host "  CDN candidate not live: $candidate - falling back to winget manifest"
    return (Resolve-ManifestUrl $Latest)
}

function Save-LatestInstaller([string]$Latest, [string]$BuilderScript, [string]$DestFile) {
    $url = Resolve-InstallerUrl -Latest $Latest -BuilderScript $BuilderScript
    Write-Host "  downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $DestFile -TimeoutSec 900 -UseBasicParsing
    return $DestFile
}

function Stop-AppBrowser([string]$AppDir) {
    $procs = @(Get-Process -Name browser -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -like "$AppDir*" } catch { $false } })
    if ($procs.Count -eq 0) {
        Write-Host '  no running browser.exe under the app dir'
        return 0
    }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Write-Host "  stopped $($procs.Count) browser.exe process(es)"
    return $procs.Count
}

function Copy-TreeMerge([string]$From, [string]$To) {
    # Recursive merge copy (Move-Item cannot merge onto an existing dir name).
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    foreach ($c in @(Get-ChildItem -LiteralPath $From -Force)) {
        $dest = Join-Path $To $c.Name
        if ($c.PSIsContainer) { Copy-TreeMerge $c.FullName $dest }
        else { Copy-Item -LiteralPath $c.FullName -Destination $dest -Force }
    }
}

function Copy-UpdatedFiles([string]$SourceDir, [string]$TargetDir, [string[]]$Protected) {
    # Never-touch set: profile/cache live at the package ROOT and are not part
    # of the staged tree, but refuse anyway if a staged entry ever carries them.
    $neverTouch = @('Data', 'Cache')
    $before = @{}
    foreach ($p in $Protected) {
        $f = Join-Path $TargetDir $p
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $before[$p] = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        }
    }
    $skipped = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $SourceDir -Force)) {
        $name = $item.Name
        if ($Protected -contains $name) {
            Write-Host "  skipping protected: $name"
            $skipped += $name
            continue
        }
        if ($neverTouch -contains $name) {
            Write-Host "  refusing to touch $name (user data lives at the package root)"
            $skipped += $name
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $TargetDir $name) -Recurse -Force
    }
    # Hash-assert: protected files must be byte-identical after copy-over.
    foreach ($p in $before.Keys) {
        $after = (Get-FileHash -LiteralPath (Join-Path $TargetDir $p) -Algorithm SHA256).Hash
        if ($after -ne $before[$p]) { throw "protected file changed during copy-over: $p" }
    }
    return ,$skipped
}

function Update-CdmLayout([string]$YandexDir) {
    # Flat CDM rule (review fix #16 / design section 4): Chrome registers the
    # preinstalled WidevineCdm ONLY from the exe-dir flat path - versioned
    # Yandex\<ver>\WidevineCdm nesting is dead weight. Migrate it flat and
    # strip updaters a mixed copy may have reintroduced. launch.bat (root) and
    # version.dll (Yandex\) can legitimately coexist after an era change - both
    # launch the same portable Data\, so neither is removed (documented).
    $flat = Join-Path $YandexDir 'WidevineCdm'
    $state = 'absent'
    if (Test-Path -LiteralPath $flat) { $state = 'flat-present' }
    foreach ($n in @(Get-ChildItem -LiteralPath $YandexDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'WidevineCdm' -and $_.FullName -ne $flat })) {
        Write-Host "  migrating versioned CDM $($n.FullName) -> flat Yandex\WidevineCdm"
        if (-not (Test-Path -LiteralPath $flat)) {
            Move-Item -LiteralPath $n.FullName -Destination $flat
        }
        else {
            Copy-TreeMerge $n.FullName $flat
            Remove-Item -LiteralPath $n.FullName -Recurse -Force
        }
        $state = 'migrated'
    }
    $leftover = @(Get-ChildItem -LiteralPath $YandexDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'WidevineCdm' -and $_.FullName -ne $flat })
    if ($leftover.Count -gt 0) { throw "versioned WidevineCdm nesting still present: $($leftover[0].FullName)" }
    foreach ($u in 'service_update.exe', 'yupdate-exec.exe') {
        foreach ($f in @(Get-ChildItem -LiteralPath $YandexDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $u })) {
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Host "  stripped stale updater $($f.Name)"
        }
    }
    return $state
}

function Import-BloatPolicies([string]$RegFile) {
    if (-not (Test-Path -LiteralPath $RegFile)) {
        Write-Host "  Warning: $RegFile not found - policies NOT re-applied" -ForegroundColor Yellow
        return 'missing'
    }
    try {
        & reg import $RegFile 2>&1 | Out-Null
        if ($LASTEXITCODE) {
            Write-Host "  Warning: reg import exited $LASTEXITCODE - re-import as administrator to re-apply policies" -ForegroundColor Yellow
            return "failed-exit-$LASTEXITCODE"
        }
        Write-Host '  debloater.reg re-applied'
        return 'applied'
    }
    catch {
        Write-Host "  Warning: reg import unavailable ($($_.Exception.Message)) - re-import Yandex\debloater.reg manually" -ForegroundColor Yellow
        return 'failed-exception'
    }
}

function Invoke-UpdateFlow([string]$AppDir) {
    $AppDir = $AppDir.TrimEnd('\', '/')
    $pkgRoot = Split-Path -Parent $AppDir
    $versionPath = Join-Path $AppDir 'version.txt'
    $current = if (Test-Path -LiteralPath $versionPath) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { 'Not installed' }

    $latest = Get-LatestPackageVersion
    Write-Host "  current version: $current"
    Write-Host "  latest version : $latest"

    if ($current -eq $latest) {
        Write-Host 'Already up to date!' -ForegroundColor Green
        return [pscustomobject]@{ Outcome = 'Uptodate'; Current = $current; Latest = $latest; Skipped = @(); PolicyStatus = $null; CdmState = $null; BrowserExe = $null }
    }

    $confirm = Read-UpdatePrompt 'Do you want to update? (y/N)'
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host 'Update cancelled.'
        return [pscustomobject]@{ Outcome = 'Declined'; Current = $current; Latest = $latest; Skipped = @(); PolicyStatus = $null; CdmState = $null; BrowserExe = $null }
    }

    $null = Stop-AppBrowser $AppDir

    $work = Join-Path ([IO.Path]::GetTempPath()) ('yandex-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $builderScript = Join-Path $pkgRoot 'build-yandex.ps1'
        if (-not (Test-Path -LiteralPath $builderScript)) {
            throw "build-yandex.ps1 not found at $builderScript (package root)"
        }

        $installerFile = Save-LatestInstaller -Latest $latest -BuilderScript $builderScript -DestFile (Join-Path $work 'Yandex.exe')
        $buildOut = Join-Path $work 'pkg'
        & $builderScript -Installer $installerFile -Version $latest -OutDir $buildOut
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "build-yandex.ps1 failed (exit $LASTEXITCODE)"
        }

        $staged = Join-Path $buildOut 'Yandex'
        if (-not (Test-Path -LiteralPath (Join-Path $staged 'browser.exe'))) {
            throw "staged package has no browser.exe: $staged"
        }

        $skipped = Copy-UpdatedFiles -SourceDir $staged -TargetDir $AppDir -Protected $protectedPaths
        if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'browser.exe'))) {
            throw "browser.exe missing in $AppDir after copy-over"
        }
        $cdm = Update-CdmLayout -YandexDir $AppDir
        $policy = Import-BloatPolicies -RegFile (Join-Path $AppDir 'debloater.reg')

        # Mixed launch eras are harmless: root launch.bat is outside the copy
        # scope, Yandex\version.dll is inside - both target the same portable Data\.
        if ((Test-Path -LiteralPath (Join-Path $AppDir 'version.dll')) -and (Test-Path -LiteralPath (Join-Path $pkgRoot 'launch.bat'))) {
            Write-Host '  note: version.dll + launch.bat both present (mixed launch eras) - kept, both target the same portable Data\'
        }

        # version.txt last: never leave a stale version on failure (Helium #5).
        Set-Content -Path $versionPath -Value $latest

        Write-Host ''
        Write-Host 'Update summary'
        Write-Host "  version      : $current -> $latest"
        Write-Host "  protected    : $(if ($skipped.Count) { $skipped -join ', ' } else { '(none)' })"
        Write-Host '  browser.exe  : present (flat exe-dir rule)'
        Write-Host "  WidevineCdm  : $cdm (flat rule: no Yandex\*\WidevineCdm nesting)"
        Write-Host "  policies     : $policy"
        Write-Host 'Update completed successfully!' -ForegroundColor Green

        return [pscustomobject]@{ Outcome = 'Updated'; Current = $current; Latest = $latest; Skipped = @($skipped); PolicyStatus = $policy; CdmState = $cdm; BrowserExe = $true }
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Dot-source (tests) loads only the functions above; a direct run continues.
if ($MyInvocation.InvocationName -eq '.') { return }

# --------------------------------------------------------------- main (run)
$appDir = $env:APP_DIR
if (-not $appDir) {
    Write-Host 'update.bat: APP_DIR is not set - run update.bat from the package (it ships inside Yandex\)' -ForegroundColor Red
    exit 1
}
$rc = 0
$outcome = $null
try {
    $result = Invoke-UpdateFlow -AppDir $appDir
    $outcome = $result.Outcome
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  PSModulePath: $env:PSModulePath" -ForegroundColor Red
    $rc = 1
}
if ($outcome -ne 'Declined') {
    $null = Read-UpdatePrompt 'Press Enter to exit'
}
exit $rc
