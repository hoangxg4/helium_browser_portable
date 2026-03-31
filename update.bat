@echo off
setlocal
echo Helium Portable Updater v1.2
echo =======================================
echo.
(
echo # Helium Portable Updater
echo $ErrorActionPreference = "Stop"
echo $appDir = "%~dp0".TrimEnd('\')
echo $chromePath = Join-Path $appDir "chrome.exe"
echo $manifestPath = Join-Path $appDir "*.manifest"
echo $apiUrl = "https://api.github.com/repos/imputnet/helium-windows/releases"
echo $tempDir = Join-Path $env:TEMP "HeliumUpdate"
echo.
echo try {
echo   # Get current Helium version from manifest file
echo   $manifestFile = Get-Item $manifestPath -ErrorAction SilentlyContinue
echo   $currentVersion = if ($manifestFile) {
echo     $manifestFile.Name -replace '\.manifest$', ''
echo   } else {
echo     "Not installed"
echo   }
echo.
echo   # Get latest release
echo   $allReleases = Invoke-RestMethod -Uri $apiUrl
echo   $latestRelease = $allReleases ^| Where-Object { -not $_.prerelease } ^| Select-Object -First 1
echo   $latestVersion = $latestRelease.tag_name
echo   $downloadUrl = ($latestRelease.assets ^| Where-Object { $_.name -like "*x64-windows.zip*" }).browser_download_url
echo.
echo   if (-not $downloadUrl) {
echo     Write-Host "Error: Could not find x64-windows.zip asset" -ForegroundColor Red
echo     exit 1
echo   }
echo.
echo   Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
echo   Write-Host "Latest version:  $latestVersion" -ForegroundColor Yellow
echo   Write-Host
echo.
echo   if ($currentVersion -eq $latestVersion) {
echo     Write-Host "Already up to date!" -ForegroundColor Green
echo     exit 0
echo   }
echo.
echo   $confirm = Read-Host "Do you want to update? (y/N)"
echo   if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit }
echo.
echo   # Stop running Helium processes
echo   Write-Host "Stopping processes..."
echo   Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
echo   Start-Sleep 2
echo.
echo   # Prepare temp directory
echo   if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
echo   New-Item -ItemType Directory -Path $tempDir -Force ^| Out-Null
echo   $zipFile = Join-Path $tempDir "helium.zip"
echo.
echo   # Download
echo   Write-Host "Downloading latest version..."
echo   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo   (New-Object System.Net.WebClient).DownloadFile($downloadUrl, $zipFile)
echo.
echo   # Extract
echo   Write-Host "Extracting..."
echo   Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force
echo.
echo   # Find the extracted helium folder (e.g., helium_0.10.7.1_x64-windows)
echo   $extractedDir = Get-ChildItem $tempDir -Directory ^| Where-Object { $_.Name -like "helium_*" } ^| Select-Object -First 1
echo   if (-not $extractedDir) {
echo     Write-Host "Error: Could not find extracted helium folder" -ForegroundColor Red
echo     exit 1
echo   }
echo.
echo   # Protected files that should not be overwritten
echo   $protectedFiles = @("helium++.ini", "debloater.reg", "default-apps-multi-profile.bat", "update.bat")
echo.
echo   # Update files
echo   Write-Host "Updating files..."
echo   Get-ChildItem $extractedDir.FullName -Recurse ^| ForEach-Object {
echo     $relativePath = $_.FullName.Substring($extractedDir.FullName.Length + 1)
echo     $destPath = Join-Path $appDir $relativePath
echo     if ($_.PSIsContainer) {
echo       if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath -Force ^| Out-Null }
echo     } else {
echo       if ($_.Name -in $protectedFiles) {
echo         Write-Host "  Skipping protected: $($_.Name)"
echo       } else {
echo         $destFolder = Split-Path $destPath -Parent
echo         if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force ^| Out-Null }
echo         Copy-Item $_.FullName -Destination $destPath -Force
echo       }
echo     }
echo   }
echo.
echo   # Cleanup
echo   Remove-Item $tempDir -Recurse -Force
echo.
echo   # Verify
echo   $newManifest = Get-Item (Join-Path $appDir "*.manifest") -ErrorAction SilentlyContinue
echo   $newVersion = if ($newManifest) { $newManifest.Name -replace '\.manifest$', '' } else { "Unknown" }
echo   Write-Host "Update completed! Version: $newVersion" -ForegroundColor Green
echo.
echo } catch {
echo   Write-Host "Error: $_" -ForegroundColor Red
echo   if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
echo }
echo.
echo Read-Host "Press Enter to exit"
) > "%TEMP%\helium_update.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\helium_update.ps1"
del "%TEMP%\helium_update.ps1" 2>nul
