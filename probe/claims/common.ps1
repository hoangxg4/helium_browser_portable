# probe/claims/common.ps1 — shared layout/process helpers for the claims probes.
# Dot-source only; every helper is IO glue over the package tree.

Set-StrictMode -Version Latest

function Get-ClaimsAppLayout {
    <# Resolve a package root (contains Yandex\, Data\) or a raw install dir
       into the pieces every probe needs: browser.exe, install dir, profile. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App)

    $appDir = $null
    $exe    = $null
    if (Test-Path -LiteralPath (Join-Path $App 'browser.exe')) {
        $appDir = $App
        $exe    = Join-Path $App 'browser.exe'
    }
    elseif (Test-Path -LiteralPath (Join-Path $App 'Yandex\browser.exe')) {
        $appDir = Join-Path $App 'Yandex'
        $exe    = Join-Path $appDir 'browser.exe'
    }
    else {
        throw ("browser.exe not found under {0}" -f $App)
    }

    $pkg = if (Test-Path -LiteralPath (Join-Path $App 'Yandex')) { $App } else { Split-Path -Parent $appDir }
    return [pscustomobject]@{
        Root    = $pkg
        AppDir  = $appDir
        Exe     = $exe
        Profile = (Join-Path $pkg 'Data')
    }
}

function Disable-ClaimsVersionDll {
    <# smoke lesson: set version.dll aside so probes run stock browser.exe and
       the explicit --user-data-dir decides where Data/Cache live. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppDir)

    $dll = Join-Path $AppDir 'version.dll'
    if (Test-Path -LiteralPath $dll) {
        $aside = "$dll.aside"
        Move-Item -LiteralPath $dll -Destination $aside -Force
        Write-Host "detail: claims: version.dll moved aside -> $aside"
        return $aside
    }
    return $null
}

function Stop-ClaimsBrowser {
    [CmdletBinding()]
    param()
    Stop-Process -Name browser, browser_proxy -Force -ErrorAction SilentlyContinue
}

function Close-ClaimsBrowserGracefully {
    <# Ask each browser window to close, then force what is left. #>
    [CmdletBinding()]
    param([int]$TimeoutSec = 20)

    $procs = @(Get-Process -Name browser -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try { $null = $p.CloseMainWindow() } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-Process -Name browser -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    Stop-ClaimsBrowser
    $left = @(Get-Process -Name browser, browser_proxy -ErrorAction SilentlyContinue).Count
    Write-Host ("detail: claims: graceful close done (remaining processes={0})" -f $left)
}

function Get-ClaimsDirBytes {
    <# Recursive byte total of a tree (T3 baseline/saved measurement). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $sum += $_.Length }
    return [long]$sum
}
