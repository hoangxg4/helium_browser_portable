@echo off
setlocal
echo Helium Portable Updater v1.5.1 (Fixed)
echo =======================================
echo.
set "APP_DIR=%~dp0"
set "APP_DIR=%APP_DIR:~0,-1%"
set "PS1=%TEMP%\helium_update.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:APP_DIR='%APP_DIR%'; (Get-Content '%~f0' | Select-Object -Skip 12) | Out-File -Encoding utf8 '%PS1%'; & '%PS1%'"
del "%PS1%" 2>nul
exit /b

$appDir = $env:APP_DIR
$versionPath = Join-Path $appDir "version.txt"
$chromePath = Join-Path $appDir "chrome.exe"
$apiUrl = "https://api.github.com/repos/imputnet/helium-windows/releases"
$tempDir = Join-Path $env:TEMP "HeliumUpdate"

try {
    # 1. Kiểm tra phiên bản hiện tại
    $currentVersion = if (Test-Path $versionPath) { (Get-Content $versionPath -Raw).Trim() } else { "Not installed" }

    # 2. Lấy thông tin từ GitHub API
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

    # 3. So sánh phiên bản
    if ($currentVersion -eq $latestVersion) {
        Write-Host "Already up to date!" -ForegroundColor Green
        Read-Host "Press Enter to exit"
        exit 0
    }

    $confirm = Read-Host "Do you want to update? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit }

    # 4. Dọn dẹp tiến trình
    Write-Host "Stopping processes..." -Cyan
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep 2

    # 5. Tải về và giải nén
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $zipFile = Join-Path $tempDir "helium.zip"

    Write-Host "Downloading latest version..." -Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile

    Write-Host "Extracting..." -Cyan
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

    # Tìm thư mục chứa nội dung sau khi giải nén
    $extractedDir = Get-ChildItem $tempDir -Directory | Where-Object { $_.Name -like "helium_*" } | Select-Object -First 1
    if (-not $extractedDir) {
        Write-Host "Error: Could not find extracted helium folder" -ForegroundColor Red
        exit 1
    }

    # 6. Cập nhật Files
    $protectedFiles = @("chrome++.ini", "default-apps-multi-profile.bat", "update.bat")
    Write-Host "Updating files..." -Cyan
    
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

    # 7. CHỐT PHIÊN BẢN (Sửa lỗi quan trọng nhất ở đây)
    Set-Content -Path $versionPath -Value $latestVersion -Force

    # Dọn dẹp rác
    Remove-Item $tempDir -Recurse -Force

    Write-Host ""
    Write-Host "Update completed successfully!" -ForegroundColor Green
    Write-Host "New Version: $latestVersion" -ForegroundColor Green

} catch {
    Write-Host "Error occurred: $_" -ForegroundColor Red
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
}

Read-Host "Press Enter to exit"
