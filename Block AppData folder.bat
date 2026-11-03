@echo off
:: Optional hardening for issue #9.
::
:: Chromium derives its *default* user data directory (and therefore
:: %LOCALAPPDATA%\imput\Helium\User Data\Crashpad) from %LOCALAPPDATA%, and ignores
:: --user-data-dir / --breakpad-dump-location for that path
:: (chrome/common/chrome_paths.cc, crbug.com/40447560). "Helium Browser.bat"
:: redirects %LOCALAPPDATA% into the package, which covers every child process it
:: starts - but it only works for launches made through that launcher.
::
:: This script removes the write permission on %LOCALAPPDATA%\imput so that no
:: launch path (an old shortcut, a taskbar pin, a file-association registration,
:: a hand-made .bat) can recreate the folder. Nothing else on the machine uses
:: that vendor folder, and this package redirects Crashpad into Data\Crashpad.
::
:: Needs administrator rights. Reversible: run "icacls"%TARGET%" /reset /t /c".
setlocal
set "TARGET=%LOCALAPPDATA%\imput"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrative privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

echo Target: "%TARGET%"
echo.
echo 1 = Block it (deny write access so Helium cannot recreate it)
echo 2 = Undo   (restore normal permissions)
echo 3 = Exit
set "choice="
set /p choice="Enter your choice (1-3): "
if "%choice%"=="1" goto block
if "%choice%"=="2" goto unblock
exit /b 0

:block
if not exist "%TARGET%" mkdir "%TARGET%" 2>nul
if not exist "%TARGET%" (
  echo ERROR: could not create "%TARGET%" - nothing to protect.
  pause
  exit /b 1
)
icacls "%TARGET%" /inheritance:r /grant:r "%USERNAME%":(F) /deny "*S-1-1-0":(WD,AD,WA) >nul
if %errorlevel% neq 0 (
  echo WARNING: icacls reported a problem. Current permissions:
  icacls "%TARGET%"
) else (
  echo Done. "%TARGET%" can no longer be written to by any process.
  echo Run "Fix AppData leftovers.bat" first if it still contains files.
)
pause
exit /b 0

:unblock
if not exist "%TARGET%" (
  echo Nothing to undo - "%TARGET%" does not exist.
  pause
  exit /b 0
)
icacls "%TARGET%" /reset /t /c >nul
icacls "%TARGET%" /inheritance:e >nul
echo Done. Permissions on "%TARGET%" restored.
pause
exit /b 0
