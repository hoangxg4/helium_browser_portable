@echo off

:: ==============================================
:: CONFIGURATION SECTION
:: ==============================================
set "app=%~dp0"
set "CHROMIUM_PATH=%app%chrome.exe"
set "PROFILE_PATH=%app%Data"
set "BROWSER_NAME=Helium Portable"
set "BROWSER_DESC=Helium Portable default browser with custom profile"

:: ==============================================
:: SYSTEM CHECKS
:: ==============================================
NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    ECHO Requesting administrative privileges...
    powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
    EXIT /B
)

if not exist "%CHROMIUM_PATH%" (
    echo ERROR: Helium not found at:
    echo "%CHROMIUM_PATH%"
    pause
    exit /b 1
)

if not exist "%PROFILE_PATH%" (
    echo WARNING: Profile directory doesn't exist:
    echo "%PROFILE_PATH%"
    echo Creating it now...
    mkdir "%PROFILE_PATH%"
)

:: ==============================================
:: REGISTRY CONFIGURATION
:: ==============================================
echo Configuring registry settings...

reg delete "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_NAME%HTML" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_NAME%URL" /f >nul 2>&1

reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%" /ve /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

reg add "HKLM\Software\Classes\%BROWSER_NAME%HTML" /ve /d "%BROWSER_NAME% Document" /f
reg add "HKLM\Software\Classes\%BROWSER_NAME%HTML\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Classes\%BROWSER_NAME%HTML\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

reg add "HKLM\Software\Classes\%BROWSER_NAME%URL" /ve /d "%BROWSER_NAME% URL" /f
reg add "HKLM\Software\Classes\%BROWSER_NAME%URL" /v "URL Protocol" /d "" /f
reg add "HKLM\Software\Classes\%BROWSER_NAME%URL\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Classes\%BROWSER_NAME%URL\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities" /v "ApplicationName" /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities" /v "ApplicationDescription" /d "%BROWSER_DESC%" /f

reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\FileAssociations" /v ".htm" /d "%BROWSER_NAME%HTML" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\FileAssociations" /v ".html" /d "%BROWSER_NAME%HTML" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\FileAssociations" /v ".pdf" /d "%BROWSER_NAME%HTML" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\FileAssociations" /v ".svg" /d "%BROWSER_NAME%HTML" /f

reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\URLAssociations" /v "http" /d "%BROWSER_NAME%URL" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\URLAssociations" /v "https" /d "%BROWSER_NAME%URL" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities\URLAssociations" /v "ftp" /d "%BROWSER_NAME%URL" /f

reg add "HKLM\Software\RegisteredApplications" /v "%BROWSER_NAME%" /d "Software\Clients\StartMenuInternet\%BROWSER_NAME%\Capabilities" /f

:: ==============================================
:: COMPLETION
:: ==============================================
echo Browser registered successfully!
echo.
echo NOTE: Due to Windows 10/11 security restrictions, automatic default browser
echo setting is not possible through registry. Please follow these steps:
echo.
echo 1. The Windows Settings app will open automatically
echo 2. Go to Apps ^> Default apps
echo 3. Look for "Web browser" section
echo 4. Click on the current default browser
echo 5. Select "%BROWSER_NAME%" from the list
echo.

assoc .html=%BROWSER_NAME%HTML >nul 2>&1
assoc .htm=%BROWSER_NAME%HTML >nul 2>&1
ftype %BROWSER_NAME%HTML="%CHROMIUM_PATH%" --user-data-dir="%PROFILE_PATH%" "%%1" >nul 2>&1

start "" "ms-settings:defaultapps"

echo.
echo Configuration complete!
echo Please manually set it as default using the Windows Settings that just opened.
echo.
pause
