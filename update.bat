@echo off
setlocal
echo Yandex Browser Portable Updater v0.1.0 (stub)
echo ==============================================
echo.
set "APP_DIR=%~dp0"
set "APP_DIR=%APP_DIR:~0,-1%"
set "PS1=%TEMP%\yandex_update.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:APP_DIR='%APP_DIR%'; (Get-Content '%~f0' | Select-Object -Skip 11) | Out-File -Encoding utf8 '%PS1%'; & '%PS1%'"
del "%PS1%" 2>nul
exit /b
# ---------------------------------------------------------------------------
# update.bat PowerShell body (Task 4) — everything below line 11 is extracted
# by the batch header above (Select-Object -Skip 11). Keep that count exact.
# ---------------------------------------------------------------------------
$appDir = $env:APP_DIR

# TODO(Task 4): read $versionPath = Join-Path $appDir "version.txt"
# TODO(Task 4): resolve latest release — winget PackageVersion / GitHub Releases
#               is the SOLE source of truth for the version (design §3 correction).
# TODO(Task 4): stop browser.exe processes rooted at $appDir.
# TODO(Task 4): download the official Yandex.exe payload and re-extract to a fresh dir.
# TODO(Task 4): copy-over with protectedPaths
#               @("chrome++.ini", "update.bat", "debloater.reg", "Data\", "Cache\")
# TODO(Task 4): re-apply debloater.reg (policies may have been overwritten).
# TODO(Task 4): flat-path CDM check (Yandex\WidevineCdm) + EME re-verify (Helium #5).
# TODO(Task 4): rewrite version.txt BEFORE finishing (never leave a stale version).

Write-Host "update.bat: stub — not implemented yet (Task 4)"
if ($Host.Name -eq 'ConsoleHost') { Read-Host "Press Enter to exit" }
