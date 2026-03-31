@echo off
setlocal
echo Helium Portable Updater v1.4
echo =======================================
echo.
set "PS1=%TEMP%\helium_update.ps1"
set "APP_DIR=%~dp0"

> "%PS1%" echo $appDir = '%APP_DIR:~0,-1%'
>> "%PS1%" echo $chromePath = Join-Path $appDir "chrome.exe"
>> "%PS1%" echo $manifestPath = Join-Path $appDir "*.manifest"
>> "%PS1%" echo $apiUrl = "https://api.github.com/repos/imputnet/helium-windows/releases"
>> "%PS1%" echo $tempDir = Join-Path $env:TEMP "HeliumUpdate"
>> "%PS1%" echo.
>> "%PS1%" echo try ^{
>> "%PS1%" echo     $manifestFile = Get-Item $manifestPath -ErrorAction SilentlyContinue
>> "%PS1%" echo     $currentVersion = if ($manifestFile^) ^{ $manifestFile.Name -replace '\.manifest$', '' ^} else ^{ "Not installed" ^}
>> "%PS1%" echo.
>> "%PS1%" echo     $allReleases = Invoke-RestMethod -Uri $apiUrl
>> "%PS1%" echo     $latestRelease = $allReleases ^| Where-Object ^{ -not $_.prerelease ^} ^| Select-Object -First 1
>> "%PS1%" echo     $latestVersion = $latestRelease.tag_name
>> "%PS1%" echo     $downloadUrl = ($latestRelease.assets ^| Where-Object ^{ $_.name -like "*x64-windows.zip*" ^}).browser_download_url
>> "%PS1%" echo.
>> "%PS1%" echo     if (-not $downloadUrl^) ^{ Write-Host "Error: Could not find x64-windows.zip asset" -ForegroundColor Red; exit 1 ^}
>> "%PS1%" echo.
>> "%PS1%" echo     Write-Host "Current version: $currentVersion" -ForegroundColor Yellow
>> "%PS1%" echo     Write-Host "Latest version:  $latestVersion" -ForegroundColor Yellow
>> "%PS1%" echo     Write-Host
>> "%PS1%" echo.
>> "%PS1%" echo     if ($currentVersion -eq $latestVersion^) ^{ Write-Host "Already up to date!" -ForegroundColor Green; exit 0 ^}
>> "%PS1%" echo.
>> "%PS1%" echo     $confirm = Read-Host "Do you want to update? (y/N^)"
>> "%PS1%" echo     if ($confirm -ne 'y' -and $confirm -ne 'Y'^) ^{ exit ^}
>> "%PS1%" echo.
>> "%PS1%" echo     Write-Host "Stopping processes..."
>> "%PS1%" echo     Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
>> "%PS1%" echo     Start-Sleep 2
>> "%PS1%" echo.
>> "%PS1%" echo     if (Test-Path $tempDir^) ^{ Remove-Item $tempDir -Recurse -Force ^}
>> "%PS1%" echo     New-Item -ItemType Directory -Path $tempDir -Force ^| Out-Null
>> "%PS1%" echo     $zipFile = Join-Path $tempDir "helium.zip"
>> "%PS1%" echo.
>> "%PS1%" echo     Write-Host "Downloading latest version..."
>> "%PS1%" echo     [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
>> "%PS1%" echo     (New-Object System.Net.WebClient^).DownloadFile($downloadUrl, $zipFile^)
>> "%PS1%" echo.
>> "%PS1%" echo     Write-Host "Extracting..."
>> "%PS1%" echo     Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force
>> "%PS1%" echo.
>> "%PS1%" echo     $extractedDir = Get-ChildItem $tempDir -Directory ^| Where-Object ^{ $_.Name -like "helium_*" ^} ^| Select-Object -First 1
>> "%PS1%" echo     if (-not $extractedDir^) ^{ Write-Host "Error: Could not find extracted helium folder" -ForegroundColor Red; exit 1 ^}
>> "%PS1%" echo.
>> "%PS1%" echo     $protectedFiles = @("helium++.ini", "default-apps-multi-profile.bat", "update.bat"^)
>> "%PS1%" echo.
>> "%PS1%" echo     Write-Host "Updating files..."
>> "%PS1%" echo     Get-ChildItem $extractedDir.FullName -Recurse ^| ForEach-Object ^{
>> "%PS1%" echo         $relativePath = $_.FullName.Substring($extractedDir.FullName.Length + 1^)
>> "%PS1%" echo         $destPath = Join-Path $appDir $relativePath
>> "%PS1%" echo         if ($_.PSIsContainer^) ^{
>> "%PS1%" echo             if (-not (Test-Path $destPath^)^) ^{ New-Item -ItemType Directory -Path $destPath -Force ^| Out-Null ^}
>> "%PS1%" echo         ^} else ^{
>> "%PS1%" echo             if ($_.Name -in $protectedFiles^) ^{
>> "%PS1%" echo                 Write-Host "  Skipping protected: $($_.Name^)"
>> "%PS1%" echo             ^} else ^{
>> "%PS1%" echo                 $destFolder = Split-Path $destPath -Parent
>> "%PS1%" echo                 if (-not (Test-Path $destFolder^)^) ^{ New-Item -ItemType Directory -Path $destFolder -Force ^| Out-Null ^}
>> "%PS1%" echo                 Copy-Item $_.FullName -Destination $destPath -Force
>> "%PS1%" echo             ^}
>> "%PS1%" echo         ^}
>> "%PS1%" echo     ^}
>> "%PS1%" echo.
>> "%PS1%" echo     Remove-Item $tempDir -Recurse -Force
>> "%PS1%" echo.
>> "%PS1%" echo     $newManifest = Get-Item (Join-Path $appDir "*.manifest"^) -ErrorAction SilentlyContinue
>> "%PS1%" echo     $newVersion = if ($newManifest^) ^{ $newManifest.Name -replace '\.manifest$', '' ^} else ^{ "Unknown" ^}
>> "%PS1%" echo     Write-Host "Update completed! Version: $newVersion" -ForegroundColor Green
>> "%PS1%" echo.
>> "%PS1%" echo ^} catch ^{
>> "%PS1%" echo     Write-Host "Error: $_" -ForegroundColor Red
>> "%PS1%" echo     if (Test-Path $tempDir^) ^{ Remove-Item $tempDir -Recurse -Force ^}
>> "%PS1%" echo ^}
>> "%PS1%" echo.
>> "%PS1%" echo Read-Host "Press Enter to exit"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" 2>nul
exit /b
