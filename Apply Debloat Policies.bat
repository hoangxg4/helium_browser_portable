@echo off
:: Applies debloater.reg (privacy policies + component/update policy that keeps
:: component *downloads* off while still letting Chrome register the preinstalled
:: Widevine CDM). Needs admin, so it re-launches itself elevated.
setlocal
set "APP_DIR=%~dp0"
set "REG_FILE=%APP_DIR%Helium\debloater.reg"
if not exist "%REG_FILE%" (
  echo ERROR: "%REG_FILE%" not found.
  pause
  exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrative privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)
echo Applying "%REG_FILE%" ...
reg import "%REG_FILE%"
if %errorlevel% equ 0 (
  echo Done. Helium policies applied.
) else (
  echo WARNING: reg import returned %errorlevel%.
)
pause
exit /b 0
