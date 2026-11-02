@echo off
:: Portable launcher. Everything stays relative to this file, so the folder can
:: be moved or extracted anywhere (a .lnk would store an absolute path and break).
:: Always launches Helium\chrome.exe WITH Helium\ as the working directory: that is
:: how chrome++.ini finds the profile (..\Data), the cache and the Crashpad folder,
:: and how Chrome++ loads Helium\version.dll.
setlocal
set "APP_DIR=%~dp0"
set "HELIUM_EXE=%APP_DIR%Helium\chrome.exe"
if not exist "%HELIUM_EXE%" (
  echo ERROR: "%HELIUM_EXE%" not found.
  echo Extract the whole zip and keep this launcher next to the Helium folder.
  pause
  exit /b 1
)
cd /d "%APP_DIR%Helium"
start "" "%HELIUM_EXE%" %*
exit /b 0
