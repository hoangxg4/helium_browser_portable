# Portable Layout Restructure (hibbiki-style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the release zip so its root contains only `Helium/` (+ runtime `Data/`/`Cache/`), all fixed files under `Helium/`, Widevine nested `Helium/<version>/WidevineCdm`, plus three hibbiki adoptions (`bypass_windows_defender.bat`, upgraded default-apps bat, `policy_key=Portable`) — enforced by CI validation.

**Architecture:** Everything happens in the GitHub Actions assembly step (`main.yml`) plus repo-side config/script files. `chrome++.ini` points data/cache one level up (`%app%\..\Data`), so the absolute runtime path is unchanged from the current flat layout (zero data migration). `update.bat` and `debloater.reg` are deliberately untouched.

**Tech Stack:** GitHub Actions (bash + PowerShell), batch scripts, `chrome++.ini`, registry (`.reg`/`reg add`), Python (local validation harness + zip central-directory probe).

**Spec:** `docs/superpowers/specs/2026-09-25-portable-layout-restructure-design.md` (the plan argues from the spec; executors read both).

## Global Constraints

- Zip layout: root contains `Helium_Portable/Helium/` (fixed files) only; runtime `Data/`/`Cache/` stay at `Helium_Portable/` root.
- `chrome++.ini`: `data_dir=%app%\..\Data` and `cache_dir=%app%\..\Cache` — **single backslashes**, exact strings; plus `policy_key=Portable` (no-op on Chrome++ 1.18.2, disclosed in spec §1).
- Widevine destination: `Helium_Portable\Helium\$heliumVer\WidevineCdm` (versioned subdir, hibbiki style).
- `update.bat` and `debloater.reg` are **not modified** (update.bat PowerShell preamble stays Skip=11 compatible).
- The version.dll `-like "*\${arch}\App\*"` selection, `exit 1` hard-fail, and pre-package `Test-Path` assertion must all remain (issue #7 regression guard). `validate.yml` must keep rejecting the literal string `\\\\App\\\\`.
- `validate.yml` must pass locally (full harness in Task 6) before pushing.
- Conventional commit messages: `feat(scope): ...`, `docs(README): ...`.
- Paths in workflow files use Windows backslashes (existing house style); PowerShell `Copy-Item` destinations for scripts become `Helium_Portable\Helium\`.

---

### Task 1: chrome++.ini portable-root paths + inverted validate check

**Files:**
- Modify: `chrome++.ini` (lines 1–2 and end of `[general]`)
- Modify: `.github/workflows/validate.yml:58-74` (step `Validate chrome++.ini`)

**Interfaces:**
- Consumes: none.
- Produces: repo `chrome++.ini` containing exact strings `data_dir=%app%\..\Data`, `cache_dir=%app%\..\Cache`, `policy_key=Portable`; validate step that asserts these three (replaces the old "reject `..\`" warning). Task 4's build copies this ini into `Helium_Portable\Helium\`; Task 6's harness runs this step.

- [ ] **Step 1: Replace the `..\` warning block in validate.yml (red test)**

In `.github/workflows/validate.yml`, inside step `Validate chrome++.ini`, replace exactly this block:

```yaml
        # Check paths don't go outside (no ..\)
        if grep '\.\.\\' chrome++.ini; then
          echo "  WARNING: '..\' found in paths — data may be stored outside app dir"
        else
          echo "  Paths: OK (no ..\ references)"
        fi
```

with:

```yaml
        # hibbiki-style layout: %app% = Helium\, so ..\ escapes to the portable
        # root where Data/Cache must live. This check used to reject '..\' —
        # the restructure inverted the requirement (spec section 7).
        grep -qF 'data_dir=%app%\..\Data' chrome++.ini || { echo "  ERROR: data_dir must be %app%\..\Data"; exit 1; }
        grep -qF 'cache_dir=%app%\..\Cache' chrome++.ini || { echo "  ERROR: cache_dir must be %app%\..\Cache"; exit 1; }
        grep -qF 'policy_key=Portable' chrome++.ini || { echo "  ERROR: missing policy_key=Portable"; exit 1; }
        echo "  Paths: OK (data/cache at portable root)"
```

- [ ] **Step 2: Run the new checks against the OLD ini — verify FAIL (red)**

```bash
grep -qF 'data_dir=%app%\..\Data' chrome++.ini || echo "RED: data_dir check fails as expected"
grep -qF 'policy_key=Portable' chrome++.ini || echo "RED: policy_key check fails as expected"
```

Expected: both print `RED: ...` (current ini has `data_dir=%app%\\Data`, no `policy_key`).

- [ ] **Step 3: Rewrite chrome++.ini**

Full new content of `chrome++.ini` (change lines 2–3, add `policy_key=Portable` after `ignore_policies=0`; everything else identical):

```ini
[general]
data_dir=%app%\..\Data
cache_dir=%app%\..\Cache
command_line=--no-first-run --no-default-browser-check --disable-component-update
launch_on_startup=
launch_on_exit=
boss_key=
translate_key=
show_password=0
win32k=0
ignore_policies=0
policy_key=Portable
[tabs]
double_click_close=0
right_click_close=0
keep_last_tab=1
wheel_tab=1
wheel_tab_when_press_rbutton=1
open_url_new_tab=0
open_bookmark_new_tab=0
new_tab_disable=1
new_tab_disable_name="about:blank"
```

- [ ] **Step 4: Run the new checks — verify PASS (green)**

```bash
grep -qF 'data_dir=%app%\..\Data' chrome++.ini && \
grep -qF 'cache_dir=%app%\..\Cache' chrome++.ini && \
grep -qF 'policy_key=Portable' chrome++.ini && \
echo "GREEN: all three ini checks pass"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml')); print('validate.yml YAML: OK')"
```

Expected: `GREEN: all three ini checks pass` and `validate.yml YAML: OK`.

- [ ] **Step 5: Commit**

```bash
git add chrome++.ini .github/workflows/validate.yml
git commit -m "feat(chrome++.ini): point data/cache at portable root + add policy_key"
```

---

### Task 2: Add bypass_windows_defender.bat (hibbiki port, root exclusion)

**Files:**
- Create: `bypass_windows_defender.bat` (repo root)
- Modify: `.github/workflows/validate.yml:136-145` (REQUIRED array)

**Interfaces:**
- Consumes: none.
- Produces: `bypass_windows_defender.bat` at repo root — Task 4's build copies it into `Helium_Portable\Helium\`; validate REQUIRED list includes it — Task 6's harness runs this step.

- [ ] **Step 1: Add to validate.yml REQUIRED array (red test)**

In `.github/workflows/validate.yml`, add one line to the `REQUIRED=(` array (keep the rest):

```bash
        REQUIRED=(
          "chrome++.ini"
          "bypass_windows_defender.bat"
          "debloater.reg"
          "default-apps-multi-profile.bat"
          "update.bat"
          "README.md"
          "WidevineCdm/manifest.json"
          ".github/workflows/main.yml"
          ".github/workflows/validate.yml"
        )
```

- [ ] **Step 2: Run structure check locally — verify FAIL (red)**

```bash
test -f bypass_windows_defender.bat || echo "RED: file missing as expected"
```

Expected: `RED: file missing as expected`.

- [ ] **Step 3: Create bypass_windows_defender.bat**

Full content of `bypass_windows_defender.bat` — ported from hibbiki with ONE deviation (`currentDir` = portable **root**, i.e. the script's parent dir, because `Data/`/`Cache/` live one level up; hibbiki excludes only the script's own dir):

```bat
@echo off
setlocal enabledelayedexpansion
title Microsoft Defender Exclusion Tool

:: Automatically check and request Administrator rights
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~f0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%~dp0"

    :: Deviation from hibbiki: exclude the portable ROOT (this script lives in
    :: Helium\, but Data\ and Cache\ sit one level up — excluding only %~dp0
    :: would leave user data scanned).
    for %%I in ("%~dp0..") do set "currentDir=%%~fI"

    :: Define ANSI Escape Codes
    for /F "tokens=1,2 delims=#" %%a in ('"prompt #$H#$E# & echo on & for %%b in (1) do rem"') do set "ESC=%%b"
    set "Yellow=%ESC%[33m"
    set "Green=%ESC%[32m"
    set "Red=%ESC%[31m"
    set "Reset=%ESC%[0m"

:check_status
:: Refresh status by calling PowerShell and capturing output
set "isExcluded=false"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$p=(Get-MpPreference).ExclusionPath; if($p -contains '%currentDir%'){'true'}else{'false'}"`) do (
    set "isExcluded=%%i"
)

:menu
cls
echo ====================================================
echo         MICROSOFT DEFENDER EXCLUSION TOOL
echo ====================================================
echo  Current Folder: %Yellow%"%currentDir%"%Reset%
echo.

if "!isExcluded!"=="true" (
    echo  Status: %Green%ALREADY EXCLUDED%Reset%
    echo.
    echo  1. Remove current folder from Exclusion list
) else (
    echo  Status: %Red%NOT EXCLUDED%Reset%
    echo.
    echo  1. Add current folder to Exclusion list
)
echo  2. Exit
echo ====================================================
set "choice="
set /p choice="Enter your choice (1-2): "

:: Exit if Enter is pressed or choice is 2
if "%choice%"=="" exit
if "%choice%"=="2" exit

if "%choice%"=="1" (
    cls
    echo.
    echo Exclusions
    echo.
    if "!isExcluded!"=="true" (
        echo [ACTION] Removing current folder from Microsoft Defender exclusions...
        echo.
        cmd /c "powershell -NoProfile -Command "Remove-MpPreference -ExclusionPath '%currentDir%'""
        echo [SUCCESS] Folder has been removed from the exclusion list.
    ) else (
        echo Add or remove items that you want to exclude from Microsoft Defender Antivirus scans.
        echo.
        echo [ACTION] Adding current folder to Microsoft Defender exclusions...
        echo.
        cmd /c "powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%currentDir%'""
        echo [SUCCESS] Folder has been added to the exclusion list.
    )

    echo.
    echo Done. Refreshing status...
    timeout /t 2 >nul
    goto check_status
)

:: Refresh menu if input is invalid
goto menu
```

- [ ] **Step 4: Run checks — verify PASS (green)**

```bash
test -f bypass_windows_defender.bat && \
grep -q '%~dp0\.\.' bypass_windows_defender.bat && \
grep -qF '"bypass_windows_defender.bat"' .github/workflows/validate.yml && \
echo "GREEN: file exists, root-exclusion deviation present, REQUIRED entry present"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml')); print('validate.yml YAML: OK')"
```

Expected: `GREEN: ...` then `validate.yml YAML: OK`.

- [ ] **Step 5: Commit**

```bash
git add bypass_windows_defender.bat .github/workflows/validate.yml
git commit -m "feat: add bypass_windows_defender.bat (hibbiki port, excludes portable root)"
```

---

### Task 3: Upgrade default-apps-multi-profile.bat to hibbiki registry model

**Files:**
- Modify: `default-apps-multi-profile.bat` (full rewrite, see content below)

**Interfaces:**
- Consumes: layout decision — bat ships inside `Helium\` (so `%app%` = `Helium\`, `PROFILE_PATH=%app%..\Data` = portable root `Data\`).
- Produces: registry keys under stable ID `HeliumPortable` (not the display name), `Application`/`ApplicationIcon` declarations, RegisteredApplications cleanup. Task 4 copies this file into `Helium_Portable\Helium\` unchanged.

- [ ] **Step 1: Write the failing checks (red test)**

Run — these must FAIL against the current file (no `BROWSER_ID`, no `ApplicationIcon`, no RegisteredApplications cleanup):

```bash
grep -q 'BROWSER_ID=HeliumPortable' default-apps-multi-profile.bat || echo "RED: BROWSER_ID missing"
grep -q 'ApplicationIcon' default-apps-multi-profile.bat || echo "RED: Application declarations missing"
grep -qF 'reg delete "HKLM\Software\RegisteredApplications" /v "%BROWSER_NAME%"' default-apps-multi-profile.bat || echo "RED: RegisteredApplications cleanup missing"
grep -qF 'PROFILE_PATH=%app%..\Data' default-apps-multi-profile.bat || echo "RED: PROFILE_PATH still flat (%app%Data)"
grep -qF -- '--user-data-dir=\"%PROFILE_PATH%\"' default-apps-multi-profile.bat && echo "already green: user-data-dir deviation present (must remain after rewrite)"
```

Expected: the first four print `RED: ...` (current file has none of those); the fifth prints `already green: ...` — the `--user-data-dir` flag already exists today and must still exist after the rewrite (spec §4 deviation).

- [ ] **Step 2: Rewrite default-apps-multi-profile.bat**

Full new content — hibbiki's registry model (`BROWSER_ID` keys, Application declarations, RegisteredApplications cleanup, `chcp 65001`) + deliberate deviations kept from our current file (documented in spec §4): `--user-data-dir` in every registered command, `PROFILE_PATH` + `mkdir` safety, legacy `assoc`/`ftype` lines, richer completion instructions. Also deletes the legacy name-based registry keys created by the OLD bat (migration):

```bat
@echo off
chcp 65001 >nul

:: ==============================================
:: CONFIGURATION SECTION
:: ==============================================
set "app=%~dp0"
set "CHROMIUM_PATH=%app%chrome.exe"
set "PROFILE_PATH=%app%..\Data"
set "BROWSER_NAME=Helium Portable"
set "BROWSER_ID=HeliumPortable"
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

:: Clean up existing settings (ID-based keys from this bat)
reg delete "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_ID%HTML" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_ID%URL" /f >nul 2>&1
:: Clean up legacy name-based keys created by older versions of this bat
reg delete "HKLM\Software\Clients\StartMenuInternet\%BROWSER_NAME%" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_NAME%HTML" /f >nul 2>&1
reg delete "HKLM\Software\Classes\%BROWSER_NAME%URL" /f >nul 2>&1
:: Clean up RegisteredApplications to remove any old name or ID remnants
reg delete "HKLM\Software\RegisteredApplications" /v "%BROWSER_NAME%" /f >nul 2>&1
reg delete "HKLM\Software\RegisteredApplications" /v "%BROWSER_ID%" /f >nul 2>&1

:: Register browser capabilities
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%" /ve /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

:: Register file associations
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML" /ve /d "%BROWSER_NAME% Document" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

:: Declare UI properties for File Associations (Required to display name in Windows Settings)
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML\Application" /v "ApplicationName" /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML\Application" /v "ApplicationIcon" /d "\"%CHROMIUM_PATH%\",0" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%HTML\Application" /v "ApplicationDescription" /d "%BROWSER_DESC%" /f

:: Register URL protocols
reg add "HKLM\Software\Classes\%BROWSER_ID%URL" /ve /d "%BROWSER_NAME% URL" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%URL" /v "URL Protocol" /d "" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%URL\DefaultIcon" /ve /d "\"%CHROMIUM_PATH%\"" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%URL\shell\open\command" /ve /d "\"%CHROMIUM_PATH%\" --user-data-dir=\"%PROFILE_PATH%\" \"%%1\"" /f

:: Declare UI properties for URL Protocols (Required to display name in Windows Settings)
reg add "HKLM\Software\Classes\%BROWSER_ID%URL\Application" /v "ApplicationName" /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%URL\Application" /v "ApplicationIcon" /d "\"%CHROMIUM_PATH%\",0" /f
reg add "HKLM\Software\Classes\%BROWSER_ID%URL\Application" /v "ApplicationDescription" /d "%BROWSER_DESC%" /f

:: Set capabilities
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities" /v "ApplicationName" /d "%BROWSER_NAME%" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities" /v "ApplicationDescription" /d "%BROWSER_DESC%" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities" /v "ApplicationIcon" /d "\"%CHROMIUM_PATH%\",0" /f

:: File associations (.htm/.html only — matches hibbiki; the old bat mapped
:: .pdf/.svg to the HTML ProgID which was semantically wrong)
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities\FileAssociations" /v ".htm" /d "%BROWSER_ID%HTML" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities\FileAssociations" /v ".html" /d "%BROWSER_ID%HTML" /f

:: URL associations
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities\URLAssociations" /v "http" /d "%BROWSER_ID%URL" /f
reg add "HKLM\Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities\URLAssociations" /v "https" /d "%BROWSER_ID%URL" /f

:: Register with Windows
reg add "HKLM\Software\RegisteredApplications" /v "%BROWSER_NAME%" /d "Software\Clients\StartMenuInternet\%BROWSER_ID%\Capabilities" /f

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

assoc .html=%BROWSER_ID%HTML >nul 2>&1
assoc .htm=%BROWSER_ID%HTML >nul 2>&1
ftype %BROWSER_ID%HTML="%CHROMIUM_PATH%" --user-data-dir="%PROFILE_PATH%" "%%1" >nul 2>&1

start "" "ms-settings:defaultapps"

echo.
echo Configuration complete!
echo Please manually set it as default using the Windows Settings that just opened.
echo.
pause
```

- [ ] **Step 3: Run the failing checks — verify PASS (green)**

```bash
grep -q 'BROWSER_ID=HeliumPortable' default-apps-multi-profile.bat && \
grep -q 'ApplicationIcon' default-apps-multi-profile.bat && \
grep -qF 'reg delete "HKLM\Software\RegisteredApplications" /v "%BROWSER_NAME%"' default-apps-multi-profile.bat && \
grep -qF -- '--user-data-dir=\"%PROFILE_PATH%\"' default-apps-multi-profile.bat && \
grep -q 'PROFILE_PATH=%app%..\Data' default-apps-multi-profile.bat && \
! grep -qF 'StartMenuInternet\%BROWSER_NAME%\DefaultIcon' default-apps-multi-profile.bat && \
echo "GREEN: hibbiki registry model + deviations verified"
```

Expected: `GREEN: hibbiki registry model + deviations verified`.

- [ ] **Step 4: Commit**

```bash
git add default-apps-multi-profile.bat
git commit -m "feat(default-apps): hibbiki registry model (BROWSER_ID keys + Application decls)"
```

---

### Task 4: Assemble the zip in hibbiki layout (main.yml) + build-workflow validate checks

**Files:**
- Modify: `.github/workflows/validate.yml:120-131` (step `Validate build workflow`)
- Modify: `.github/workflows/main.yml:126-161` (step `Build (${{ matrix.arch }})`)

**Interfaces:**
- Consumes: `bypass_windows_defender.bat` exists (Task 2); `chrome++.ini` already has `%app%\..` paths (Task 1); default-apps + update.bat present (Task 3 / pre-existing).
- Produces: build that emits `Helium_Portable\Helium\{chrome.exe,version.dll,chrome++.ini,update.bat,default-apps-multi-profile.bat,bypass_windows_defender.bat,debloater.reg,version.txt,<heliumVer>\WidevineCdm\...}`; validate checks that pin this assembly (Task 6 harness runs them).

- [ ] **Step 1: Update validate.yml build checks (red test)**

In `.github/workflows/validate.yml`, step `Validate build workflow`:

1a. Replace this single line:

```bash
        grep -q 'Test-Path "Helium_Portable\\version\.dll"' .github/workflows/main.yml || { echo "  ERROR: missing pre-package version.dll assertion in main.yml"; exit 1; }
```

with:

```bash
        grep -q 'Test-Path "Helium_Portable\\Helium\\version\.dll"' .github/workflows/main.yml || { echo "  ERROR: missing pre-package version.dll assertion in main.yml"; exit 1; }
```

1b. Immediately after the line `echo "  version.dll selection + assertion + hard-fail: OK"` append:

```bash

        # hibbiki-style layout: assembly must target Helium_Portable\Helium\
        # and nest WidevineCdm under the Helium version dir (spec sections 2, 7).
        grep -qF 'Helium_Portable\Helium' .github/workflows/main.yml || { echo "  ERROR: main.yml does not assemble into Helium_Portable\Helium"; exit 1; }
        grep -qF '$heliumVer\WidevineCdm' .github/workflows/main.yml || { echo "  ERROR: WidevineCdm not nested under the version dir"; exit 1; }
        echo "  hibbiki layout assembly: OK"
```

Do NOT touch the `\\\\App\\\\` broken-regex rejection or the other version.dll checks in this step.

- [ ] **Step 2: Run the two new/changed checks against OLD main.yml — verify FAIL (red)**

```bash
grep -q 'Test-Path "Helium_Portable\\Helium\\version\.dll"' .github/workflows/main.yml || echo "RED: assertion path not updated yet"
grep -qF 'Helium_Portable\Helium' .github/workflows/main.yml || echo "RED: assembly target missing"
grep -qF '$heliumVer\WidevineCdm' .github/workflows/main.yml || echo "RED: nested Widevine missing"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml')); print('validate.yml YAML: OK')"
```

Expected: three `RED: ...` lines, then `validate.yml YAML: OK`.

- [ ] **Step 3: Restructure main.yml build step — six exact edits**

Edit **3a** — replace:

```powershell
        New-Item -Force -Type Directory Helium_Portable | Out-Null

        # Copy Helium files
        $heliumDir = Get-ChildItem helium_extracted -Directory | Select-Object -First 1
        Copy-Item "$($heliumDir.FullName)\*" Helium_Portable\ -Recurse -Force
```

with:

```powershell
        # hibbiki-style layout: everything fixed lives under Helium_Portable\Helium\
        New-Item -Force -Type Directory Helium_Portable\Helium | Out-Null

        # Copy Helium files
        $heliumDir = Get-ChildItem helium_extracted -Directory | Select-Object -First 1
        Copy-Item "$($heliumDir.FullName)\*" Helium_Portable\Helium\ -Recurse -Force
```

Edit **3b** — replace:

```powershell
        Copy-Item $dll.FullName Helium_Portable\ -Force
```

with:

```powershell
        Copy-Item $dll.FullName Helium_Portable\Helium\ -Force
```

(Edit 3b's surrounding comment block and the `-like` selection/`exit 1` hard-fail stay byte-identical.)

Edit **3c** — replace:

```powershell
        Copy-Item chrome++.ini,debloater.reg,default-apps-multi-profile.bat,update.bat Helium_Portable\ -Force
```

with:

```powershell
        Copy-Item chrome++.ini,debloater.reg,default-apps-multi-profile.bat,update.bat,bypass_windows_defender.bat Helium_Portable\Helium\ -Force
```

Edit **3d** — replace:

```powershell
        Copy-Item WidevineCdm Helium_Portable\ -Recurse -Force
```

with:

```powershell
        Copy-Item WidevineCdm "Helium_Portable\Helium\$heliumVer\" -Recurse -Force
```

Edit **3e** — replace:

```powershell
        Set-Content -Path "Helium_Portable\version.txt" -Value "$heliumVer"
```

with:

```powershell
        Set-Content -Path "Helium_Portable\Helium\version.txt" -Value "$heliumVer"
```

Edit **3f** — replace:

```powershell
        # Safety net: never ship a zip without version.dll — portable data
        # (chrome++.ini data_dir) only works when Chrome++ DLL is loaded.
        if (-not (Test-Path "Helium_Portable\version.dll")) {
          Write-Error "Helium_Portable\version.dll missing before packaging — aborting"
          exit 1
        }
```

with:

```powershell
        # Safety net: never ship a zip without version.dll — portable data
        # (chrome++.ini data_dir) only works when Chrome++ DLL is loaded.
        if (-not (Test-Path "Helium_Portable\Helium\version.dll")) {
          Write-Error "Helium_Portable\Helium\version.dll missing before packaging — aborting"
          exit 1
        }
        if (-not (Test-Path "Helium_Portable\Helium\chrome.exe")) {
          Write-Error "Helium_Portable\Helium\chrome.exe missing before packaging — aborting"
          exit 1
        }
        if (-not (Test-Path "Helium_Portable\Helium\$heliumVer\WidevineCdm\manifest.json")) {
          Write-Error "WidevineCdm not nested at Helium\$heliumVer\WidevineCdm — aborting"
          exit 1
        }
```

`Compress-Archive Helium_Portable "$tag.zip" -Force` and everything after it stay unchanged.

- [ ] **Step 4: Run checks — verify PASS (green) + YAML parse both workflows**

```bash
grep -q 'Test-Path "Helium_Portable\\Helium\\version\.dll"' .github/workflows/main.yml && \
grep -qF 'Helium_Portable\Helium' .github/workflows/main.yml && \
grep -qF '$heliumVer\WidevineCdm' .github/workflows/main.yml && \
grep -q 'Copy-Item chrome++.ini,debloater.reg,default-apps-multi-profile.bat,update.bat,bypass_windows_defender.bat Helium_Portable\\Helium\\ -Force' .github/workflows/main.yml && \
grep -q 'Helium_Portable\\Helium\\version.txt' .github/workflows/main.yml && \
grep -qF '\\\\App\\\\' .github/workflows/validate.yml && \
! grep -qF '\\\\App\\\\' .github/workflows/main.yml && \
echo "GREEN: assembly + assertions in place, broken-regex guard intact"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/main.yml')); yaml.safe_load(open('.github/workflows/validate.yml')); print('both workflows YAML: OK')"
```

Expected: `GREEN: ...` then `both workflows YAML: OK`. (Note: `grep -qF '\\\\App\\\\'` on validate.yml must succeed — the guard string lives in validate.yml; on main.yml it must NOT be found.)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/main.yml .github/workflows/validate.yml
git commit -m "feat(main.yml): assemble zip in hibbiki layout (Helium/ subdir, versioned Widevine)"
```

---

### Task 5: README — new layout + migration guide

**Files:**
- Modify: `README.md` (full rewrite, 21 lines currently)

**Interfaces:**
- Consumes: layout from Tasks 1–4 (file list, paths).
- Produces: user-facing docs matching the shipped zip; migration section for existing flat-layout users.

- [ ] **Step 1: Rewrite README.md**

Full new content (note: the layout block below is a fenced code block; when writing the file use a triple-backtick fence around it):

````markdown
# Helium Portable

Helium Browser Portable - Chromium-based browser by [imputnet](https://github.com/imputnet/helium-windows), packaged as a portable version with Chrome++ for local data storage and debloating.

### Features
- Helium Portable with all data stored locally, no installation required
- Chrome++ integration for portable data directory and cache
- Debloated with privacy-focused policies (disabled AI, tracking, telemetry)
- Widevine CDM support for DRM content
- Auto-update script to fetch latest Helium releases

### Layout
```
Helium_Portable/
├── Helium/                     browser + fixed files (scripts, config, CDM)
│   ├── chrome.exe
│   ├── version.dll, chrome++.ini
│   ├── update.bat
│   ├── default-apps-multi-profile.bat
│   ├── bypass_windows_defender.bat
│   ├── debloater.reg
│   ├── version.txt
│   └── <version>/WidevineCdm/
├── Data/                       runtime profile (created on first run)
└── Cache/                      runtime cache (created on first run)
```

### Files (inside `Helium/`)
- `chrome++.ini` — Chrome++ configuration (data at `../Data`, cache at `../Cache`)
- `debloater.reg` — Disable unnecessary Chromium features
- `default-apps-multi-profile.bat` — Set Helium as default browser
- `update.bat` — Auto-update to the latest Helium release
- `bypass_windows_defender.bat` — Add/remove Windows Defender exclusion for the whole portable folder

### Usage
1. Download the latest release zip
2. Extract to any folder
3. Run `Helium\chrome.exe` to start

### Update from the old (flat) layout
1. Extract the new zip to a fresh folder
2. Copy `Data\` and `Cache\` from the old folder into the new folder's root (paths are unchanged — nothing else to migrate)
3. Run `Helium\chrome.exe`; re-run `Helium\default-apps-multi-profile.bat` if you had registered default-browser shortcuts
````

- [ ] **Step 2: Verify**

```bash
grep -q 'Helium\\chrome.exe' README.md && \
grep -q 'Update from the old (flat) layout' README.md && \
grep -q 'bypass_windows_defender.bat' README.md && \
echo "GREEN: README documents layout, migration, new script"
```

Expected: `GREEN: README documents layout, migration, new script`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(README): new hibbiki-style layout + migration guide"
```

---

### Task 6: End-to-end verification — local harness, push, CI, rebuild, zip probe

**Files:**
- Create: none (verification only; fixes only if a check fails)
- Test: runs all `validate.yml` steps locally, then the real CI pipeline, then probes the release zip's central directory

**Interfaces:**
- Consumes: Tasks 1–5 all committed.
- Produces: evidence — local harness pass, Validate workflow green, build workflow green (x64 + arm64), probe output showing the new layout inside the published zips.

- [ ] **Step 1: Run the full local validate harness (replicates CI)**

```bash
python3 - <<'EOF'
import yaml, subprocess, sys
wf = yaml.safe_load(open('.github/workflows/validate.yml'))
rc_all = 0
for s in wf['jobs']['validate']['steps']:
    if 'run' not in s:
        continue
    name = s.get('name', '?')
    r = subprocess.run(['bash', '-eo', 'pipefail', '-c', s['run']],
                       capture_output=True, text=True)
    print(f"--- step '{name}': {'OK' if r.returncode == 0 else 'FAIL'}")
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        rc_all = 1
        break
print("ALL VALIDATE STEPS PASSED" if rc_all == 0 else "VALIDATE FAILED")
sys.exit(rc_all)
EOF
```

Expected: every step prints `OK`, final line `ALL VALIDATE STEPS PASSED`. (Requires `jq`; if missing: `apt-get install -y jq`. Requires `pyyaml`: `pip install --break-system-packages pyyaml` if import fails.)

- [ ] **Step 2: Push and watch the Validate workflow**

```bash
git push origin master
for i in $(seq 1 12); do
  RUN_ID=$(gh run list --workflow=validate.yml --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
  sleep 5
done
echo "validate run: $RUN_ID"
gh run watch "$RUN_ID" --exit-status
```

Expected: run completes with conclusion `success`.

- [ ] **Step 3: Dispatch the build and watch both arch jobs**

```bash
gh workflow run main.yml
for i in $(seq 1 12); do
  RUN_ID=$(gh run list --workflow=main.yml --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
  sleep 5
done
echo "build run: $RUN_ID"
gh run watch "$RUN_ID" --exit-status
```

Expected: run conclusion `success` (x64 + arm64 matrix). `workflow_dispatch` forces rebuild (`EXISTS_*` hardcoded false, main.yml:48-51) and softprops overwrites same-named release assets — no tag deletion needed. If the Release step fails on pre-existing assets, delete the two release assets (NOT the tags) with `gh release delete-asset` and re-dispatch.

- [ ] **Step 4: Probe both release zips (HTTP Range over central directory)**

```bash
python3 - <<'EOF'
import urllib.request, json, struct, re, sys

def gh(url):
    return urllib.request.urlopen(urllib.request.Request(
        url, headers={"User-Agent": "probe"})).read()

def rg(url, a, b=None):
    h = {"User-Agent": "probe", "Range": f"bytes={a}-" + (str(b) if b is not None else "")}
    return urllib.request.urlopen(urllib.request.Request(url, headers=h)).read()

rel = json.loads(gh("https://api.github.com/repos/hoangxg4/helium_browser_portable/releases/latest"))
fail = 0
for asset in rel["assets"]:
    url, size = asset["browser_download_url"], asset["size"]
    data = rg(url, size - 65557, size - 1)
    e = data.rfind(b"PK\x05\x06")
    _,_,_,n,_,cds,cdo,_ = struct.unpack("<IHHHHIIH", data[e:e+22])
    if cdo == 0xFFFFFFFF:
        loc = data.rfind(b"PK\x06\x07", 0, e)
        off = struct.unpack("<Q", data[loc+8:loc+16])[0]
        z = rg(url, off, off + 56)
        cds, cdo = struct.unpack("<Q", z[40:48])[0], struct.unpack("<Q", z[48:56])[0]
    cd = rg(url, cdo, cdo + cds - 1)
    names, p = [], 0
    while p < len(cd) and cd[p:p+4] == b"PK\x01\x02":
        fl, el, cl = struct.unpack("<HHH", cd[p+28:p+34])
        names.append(cd[p+46:p+46+fl].decode("utf-8", "replace"))
        p += 46 + fl + el + cl
    H = "Helium_Portable/"
    must = [H + "Helium/" + f for f in [
        "chrome.exe", "version.dll", "chrome++.ini", "update.bat",
        "default-apps-multi-profile.bat", "bypass_windows_defender.bat",
        "debloater.reg", "version.txt"]]
    cdm = re.compile(re.escape(H + "Helium/") + r"[^/]+/WidevineCdm/manifest\.json")
    top = {x[len(H):].split("/")[0] for x in names if x.startswith(H) and x[len(H):]}
    checks = [
        ("all fixed files under Helium/", all(m in names for m in must)),
        ("versioned WidevineCdm", any(cdm.match(x) for x in names)),
        ("root children == {Helium}", top == {"Helium"}),
        ("no flat chrome.exe at root", H + "chrome.exe" not in names),
        ("no flat version.dll at root", H + "version.dll" not in names),
    ]
    print(asset["name"], "->", len(names), "entries")
    for label, ok in checks:
        print(f"  {'PASS' if ok else 'FAIL'}: {label}")
        fail |= (not ok)
print("PROBE: ALL PASS" if not fail else "PROBE: FAILURES", file=sys.stdout)
sys.exit(fail)
EOF
```

Expected: for BOTH assets — `all fixed files under Helium/ PASS`, `versioned WidevineCdm PASS`, `root children == {Helium} PASS`, `no flat chrome.exe at root PASS`, `no flat version.dll at root PASS`, final `PROBE: ALL PASS`.

- [ ] **Step 5: Report evidence + final local sanity**

```bash
git log --oneline -6
```

Report to the operator: commit list, Validate run URL/conclusion, build run URL/conclusion, probe output (per-asset entry count + check lines). Note that smoke-testing on Windows (launch `Helium\chrome.exe`, confirm `Helium_Portable\Data` appears, optional Netflix DRM check) remains a manual operator step — do not claim it passed.

---

## Self-Review Notes (written at plan time)

- **Spec coverage:** §1.1 layout → Task 4; §1.2 ini → Task 1, main.yml → Task 4, default-apps → Task 3, bypass bat → Task 2, update.bat unchanged → no task (constraint), debloater unchanged → no task; §1.3 policy_key disclosure → in ini + spec; §2.1 README → Task 5; §2.2 validate changes → Tasks 1/2/4; §2.4 verification (local/CI/dispatch/probe/smoke) → Task 6 (smoke explicitly delegated to operator). Gaps found: none.
- **Placeholder scan:** all tasks contain full file content or exact old/new edit strings + runnable commands (grep scan clean).
- **Consistency:** `Helium_Portable\Helium\` (backslash) used in all workflow greps; `%app%\..\Data` (single backslash) identical across ini, validate checks, and default-apps `PROFILE_PATH`; `$heliumVer` matches main.yml:103 definition.
- **Bugs found & fixed during self-review:** (a) Task 3 Step 1 originally listed the `--user-data-dir` check as red although it already passes on the current file — replaced with a real red-check on `PROFILE_PATH=%app%..\Data` plus an explicit "already green, must remain" guard; (b) Task 6 probe originally double-counted nested paths into the root-children set (would have failed `root children == {Helium}` spuriously) — rewritten as a single `split("/")[0]` expression with strict equality; (c) `gh run watch` steps gained a retry loop so a slow run-listing can't produce a null run id.
