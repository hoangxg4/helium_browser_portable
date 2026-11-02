@echo off

:: Adds/removes a Microsoft Defender exclusion for the whole portable folder

:: (Data\ and Cache\ live here, one level above Helium\, so excluding only the

:: browser folder would leave user data scanned). The inner script elevates and

:: excludes the folder containing itself... which is Helium\, so the wrapper

:: keeps it impossible to run the wrong target by excluding this root instead.

setlocal

set "APP_DIR=%~dp0"

if not exist "%APP_DIR%Helium\bypass_windows_defender.bat" (

  echo ERROR: "%APP_DIR%Helium\bypass_windows_defender.bat" not found.

  pause

  exit /b 1

)

pushd "%APP_DIR%Helium"

call bypass_windows_defender.bat "%APP_DIR%"

popd

exit /b 0

