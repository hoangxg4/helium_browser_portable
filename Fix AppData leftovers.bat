@echo off

:: Removes Crashpad leftovers the browser may have created in %LOCALAPPDATA%

:: before the portable config redirected them (issue #9). Purely a cleanup: the

:: portable folder never needs these, and they are recreated only by an old

:: launcher/config that is no longer shipped.

setlocal

set "TARGET=%LOCALAPPDATA%\imput"

echo This will delete: "%TARGET%"

echo (Crashpad/User Data leftovers created by an older launcher.)

echo.

set /p confirm="Delete it now? (y/N) "

if /i not "%confirm%"=="y" (

  echo Cancelled.

  pause

  exit /b 0

)

if exist "%TARGET%" (

  rmdir /s /q "%TARGET%"

  if exist "%TARGET%" (

    echo WARNING: could not remove everything - close Helium and run again.

  ) else (

    echo Removed "%TARGET%".

  )

) else (

  echo Nothing to remove - "%TARGET%" does not exist.

)

pause

exit /b 0

