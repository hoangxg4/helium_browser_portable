@echo off
:: Registers Helium as a default-browser candidate (admin required; the script
:: asks for elevation itself). The real logic in Helium\ resolves its paths from
:: its own location, so it must run with that folder as the working directory.
setlocal
set "APP_DIR=%~dp0"
if not exist "%APP_DIR%Helium\default-apps-multi-profile.bat" (
  echo ERROR: "%APP_DIR%Helium\default-apps-multi-profile.bat" not found.
  pause
  exit /b 1
)
pushd "%APP_DIR%Helium"
call default-apps-multi-profile.bat
popd
exit /b 0
