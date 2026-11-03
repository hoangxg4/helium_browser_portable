@echo off
:: Portable launcher. Everything is resolved from this file's own location, so
:: the package keeps working after being moved or extracted anywhere (a .lnk
:: stores an absolute path and breaks).
:: The browser itself must stay in Helium\: Chrome++ (version.dll) has to sit
:: next to chrome.exe, and chrome++.ini resolves the profile, cache and Crashpad
:: folders relative to it.
setlocal
set "APP_DIR=%~dp0"
set "HELIUM_EXE=%APP_DIR%Helium\chrome.exe"
if not exist "%HELIUM_EXE%" (
  echo ERROR: "%HELIUM_EXE%" not found.
  echo Extract the whole zip and keep this launcher next to the Helium folder.
  pause
  exit /b 1
)
:: Absolute paths on purpose. The ini's relative ..\Data\Crashpad resolves against
:: the working directory, which a hand-made shortcut can leave empty — that is how
:: the AppData leak in issue #9 came back. BREAKPAD_DUMP_LOCATION is set as well
:: because Crashpad reads that variable inside the browser process.
set "BREAKPAD_DUMP_LOCATION=%APP_DIR%Data\Crashpad"
:: LOCALAPPDATA is redirected as well. Chromium derives the Crashpad
:: database (and the base "User Data" folder it appends) from the DEFAULT
:: user data directory, which is built from %LOCALAPPDATA% and ignores both
:: --user-data-dir and --breakpad-dump-location
:: (chrome/common/chrome_paths.cc DIR_CRASH_DUMPS, crbug.com/40447560). A
:: child process that is spawned without our switches therefore still lands
:: in the real AppData — redirecting %LOCALAPPDATA% covers those too, because
:: every child inherits this environment.
if not exist "%APP_DIR%Data\Local\imput" mkdir "%APP_DIR%Data\Local\imput" 2>nul
set "LOCALAPPDATA=%APP_DIR%Data\Local"
cd /d "%APP_DIR%Helium"
start "" "%HELIUM_EXE%" --breakpad-dump-location="%APP_DIR%Data\Crashpad" --user-data-dir="%APP_DIR%Data" --disable-crash-reporter %*
exit /b 0
