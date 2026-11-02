@echo off
:: Runs the real updater inside Helium\ without leaving this folder.
:: Using a wrapper instead of copying update.bat to the root is deliberate:
:: update.bat resolves every path from its own location (%~dp0), so moving it
:: would make it update the wrong directory.
setlocal
set "APP_DIR=%~dp0"
if not exist "%APP_DIR%Helium\update.bat" (
  echo ERROR: "%APP_DIR%Helium\update.bat" not found.
  pause
  exit /b 1
)
pushd "%APP_DIR%Helium"
call update.bat
popd
exit /b 0
