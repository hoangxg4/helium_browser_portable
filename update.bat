@echo off
setlocal
echo Helium Portable Updater v1.3
echo =======================================
echo.
set "PS1=%TEMP%\helium_update.ps1"
more +11 "%~f0" > "%PS1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" "%~dp0"
del "%PS1%" 2>nul
exit /b
$appDir = $args[0] -replace '\\$'
$chromePath = Join-Path $appDir "chrome.exe"
$manifestPath = Join-Path $appDir "*.manifest"
$apiUrl = "https://api.github.com/repos/imputnet/helium-windows/releases"
$tempDir = Join-Path $env:TEMP "HeliumUpdate"

try {
    # Get current Helium version from manifest file
    $manifestFile = Get-Item $manifestPath -ErrorAction SilentlyContinue
    $currentVersion = if ($manifestFile) {
        $manifestFile.Name -replace '\.manifest$', ''
    } else {
        "Not installed"
    }

    # Get latest release
    $allReleases = Invoke-RestMethod -Uri $apiUrl
    $latestRelease = $allReleases | Where-Object { -not $_.prerelease } | Select-Object -First 1
    $latestVersion = $latestRelease.tag_name
    $downloadUrl = ($latestRelease.assets | Where-Object { $_.name -like "*x64-windows.zip*" }).browser_download_url

    if (-not $downloadUrl) {
        Write-Host "Error: Could not find x64-windows.zip asset" -ForegroundColor Red
        exit 1
    }

    Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
    Write-Host "Latest version:  $latestVersion" -ForegroundColor Yellow
    Write-Host

    if ($currentVersion -eq $latestVersion) {
        Write-Host "Already up to date!" -ForegroundColor Green
        exit 0
    }

    $confirm = Read-Host "Do you want to update? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit }

    # Stop running Helium processes
    Write-Host "Stopping processes..."
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep 2

    # Prepare temp directory
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $zipFile = Join-Path $tempDir "helium.zip"

    # Download
    Write-Host "Downloading latest version..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $zipFile)

    # Extract
    Write-Host "Extracting..."
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

    # Find the extracted helium folder
    $extractedDir = Get-ChildItem $tempDir -Directory | Where-Object { $_.Name -like "helium_*" } | Select-Object -First 1
    if (-not $extractedDir) {
        Write-Host "Error: Could not find extracted helium folder" -ForegroundColor Red
        exit 1
    }

    # Protected files
    $protectedFiles = @("helium++.ini", "default-apps-multi-profile.bat", "update.bat")

    # Update files
    Write-Host "Updating files..."
    Get-ChildItem $extractedDir.FullName -Recurse | ForEach-Object {
        $relativePath = $_.FullName.Substring($extractedDir.FullName.Length + 1)
        $destPath = Join-Path $appDir $relativePath
        if ($_.PSIsContainer) {
            if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath -Force | Out-Null }
        } else {
            if ($_.Name -in $protectedFiles) {
                Write-Host "  Skipping protected: $($_.Name)"
            } else {
                $destFolder = Split-Path $destPath -Parent
                if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
                Copy-Item $_.FullName -Destination $destPath -Force
            }
        }
    }

    # Cleanup
    Remove-Item $tempDir -Recurse -Force

    # Verify
    $newManifest = Get-Item (Join-Path $appDir "*.manifest") -ErrorAction SilentlyContinue
    $newVersion = if ($newManifest) { $newManifest.Name -replace '\.manifest$', '' } else { "Unknown" }
    Write-Host "Update completed! Version: $newVersion" -ForegroundColor Green

} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
}

Read-Host "Press Enter to exit"
