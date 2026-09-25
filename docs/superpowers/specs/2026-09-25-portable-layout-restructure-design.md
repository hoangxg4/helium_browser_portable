# Design: Restructure Portable Layout (hibbiki-style)

- **Date**: 2026-09-25
- **Status**: Approved (design review done in-chat; awaiting spec review → plan)
- **Repo**: hoangxg4/helium_browser_portable
- **Reference**: bibicadotnet/chromium-hibbiki-portable

## Context

The release zip currently ships a **flat layout**: ~50 browser files,
scripts, config, and runtime `Data`/`Cache` all mixed at one root level.
The goal is to restructure the zip to mirror
`chromium-hibbiki-portable`, so the root stays clean.

Current (flat):

```
Helium_Portable/
├── chrome.exe + ~40 DLLs/files
├── version.dll, chrome++.ini, update.bat, debloater.reg,
│   default-apps-multi-profile.bat, version.txt
├── WidevineCdm/
├── Data/            ← runtime, mixed among browser files
└── Cache/
```

Reference (hibbiki):

```
Chromium_Portable/
├── Chromium/        ← ALL fixed files: binaries, scripts, config
│   ├── chrome.exe, version.dll, chrome++.ini, *.bat, debloater.reg
│   └── <chromium_ver>/WidevineCdm/
├── Data/            ← runtime, clean at root
└── Cache/
```

`chrome++.ini` uses `data_dir=%app%\..\Data` (`%app%` = dir of
`chrome.exe`), so `Data`/`Cache` land at the portable **root**.

## Goals

1. Zip root contains exactly: `Helium/` (+ runtime `Data/`, `Cache/`).
2. All fixed files (binaries, scripts, config, Widevine) live under
   `Helium/`.
3. **Zero data migration**: `Data`/`Cache` keep their current absolute
   path (`Helium_Portable\Data`, `Helium_Portable\Cache`).
4. Adopt three hibbiki extras: `bypass_windows_defender.bat`, upgraded
   `default-apps-multi-profile.bat`, `policy_key=Portable` in the ini.
5. CI validation enforces the new layout (no regression back to flat).

## Non-Goals

- Changing the Chrome++ provider (stays `bibicadotnet/Chromium_SetDLL`
  = `Bush2021/chrome_plus` v1.18.2). Switching to `chrome-next-mini`
  (hibbiki's fork) is out of scope.
- Changing `debloater.reg` policy contents.
- Changing `update.bat` behavior or its PowerShell extraction preamble
  (Skip=11 stays valid because the batch preamble is untouched).
- Rebuilding historical release tags (only the latest tag is rebuilt
  after merge, same as the previous fix).
- Porting hibbiki's `index.html` landing page or repo `LICENSE`.

## Target Layout (zip contents)

```
Helium_Portable/
├── Helium/
│   ├── chrome.exe, *.dll, version.dll
│   ├── chrome++.ini
│   ├── debloater.reg
│   ├── update.bat
│   ├── default-apps-multi-profile.bat
│   ├── bypass_windows_defender.bat
│   ├── version.txt
│   └── <helium_ver>/WidevineCdm/
│       ├── manifest.json, LICENSE
│       └── _platform_specific/win_x64/widevinecdm.dll(.sig)
├── Data/          (runtime, created on first run)
└── Cache/         (runtime, created on first run)
```

Repo (source) layout is unchanged except one new file:
`bypass_windows_defender.bat` at repo root.

## Detailed Changes

### 1. `chrome++.ini`

```ini
[general]
data_dir=%app%\..\Data
cache_dir=%app%\..\Cache
command_line=--no-first-run --no-default-browser-check --disable-component-update
policy_key=Portable
win32k=0
ignore_policies=0
...
```

- `data_dir`/`cache_dir`: `%app%\\Data` → `%app%\..\Data` (matches
  hibbiki; Windows `GetFullPathNameW` resolves it; **same final path**
  as today's flat layout because `%app%` moves into `Helium/`).
- Add `policy_key=Portable`.
- **Disclosure (verified)**: `chrome_plus` v1.18.2 has no `policy_key`
  option — grepped `config.cc`, `policies.cc`, `policies.h`, and the
  upstream `src/chrome++.ini`; only `ignore_policies` exists. The key
  will be parsed as an unknown ini entry and **ignored (no-op)**. It is
  a documented option of `chrome-next-mini`, which hibbiki uses. Added
  for structural parity; harmless.

### 2. `.github/workflows/main.yml` (build assembly)

Inside the existing `Build (${{ matrix.arch }})` step, after Helium
files are extracted:

```powershell
New-Item -Force -Type Directory Helium_Portable\Helium | Out-Null

# Browser files → Helium/
$heliumDir = Get-ChildItem helium_extracted -Directory | Select-Object -First 1
Copy-Item "$($heliumDir.FullName)\*" Helium_Portable\Helium\ -Recurse -Force

# Chrome++ DLL (unchanged selection logic: -like "*\${arch}\App\*",
# hard-fail when missing)
Copy-Item $dll.FullName Helium_Portable\Helium\ -Force

# Scripts + config → Helium/
Copy-Item chrome++.ini,debloater.reg,default-apps-multi-profile.bat,update.bat,bypass_windows_defender.bat `
  Helium_Portable\Helium\ -Force

# WidevineCdm → versioned subdir (hibbiki style)
Copy-Item WidevineCdm "Helium_Portable\Helium\$heliumVer\" -Recurse -Force

# version marker → Helium/
Set-Content -Path "Helium_Portable\Helium\version.txt" -Value "$heliumVer"

# Assertions before packaging (fail the build on violation)
if (-not (Test-Path "Helium_Portable\Helium\chrome.exe"))   { Write-Error "..."; exit 1 }
if (-not (Test-Path "Helium_Portable\Helium\version.dll"))  { Write-Error "..."; exit 1 }
if (-not (Test-Path "Helium_Portable\Helium\$heliumVer\WidevineCdm\manifest.json")) { Write-Error "..."; exit 1 }

Compress-Archive Helium_Portable "$tag.zip" -Force
```

- The existing `-like` DLL selection and pre-package
  `Test-Path ... version.dll` hard-fail remain, with paths updated to
  `Helium_Portable\Helium\`.
- Why versioned Widevine: mirrors hibbiki (proven working layout);
  Chromium checks the versioned CDM dir. Verified upstream
  `imputnet/helium-windows` zip does **not** ship WidevineCdm (78
  entries, none matching), so `update.bat` can never overwrite it.

### 3. `update.bat` — unchanged

- `%~dp0` resolves to `Helium\` after the restructure; every internal
  path (APP_DIR, `version.txt`, process-kill filter `"$appDir*"`,
  protected paths) already behaves correctly relative to the script's
  own directory.
- Protected paths stay: `chrome++.ini`, `default-apps-multi-profile.bat`,
  `update.bat`, `WidevineCdm\` (upstream zip ships none of these;
  protection is belt-and-braces).

### 4. `default-apps-multi-profile.bat` — port hibbiki version

Keep hibbiki's structure verbatim, adapted:

- `BROWSER_NAME=Helium Portable`, `BROWSER_ID=HeliumPortable`,
  `BROWSER_DESC=Helium Portable default browser with custom profile`.
- `CHROMIUM_PATH=%app%chrome.exe` (bat sits in `Helium/`, next to
  chrome.exe — correct).
- Gains hibbiki's improvements: dedicated `BROWSER_ID` registry keys,
  `Application`/`ApplicationName`/`ApplicationIcon` declarations for
  Settings UI, cleanup of stale `RegisteredApplications` entries,
  `chcp 65001`.

**Deliberate deviation from hibbiki**: keep
`--user-data-dir="%app%..\Data"` in the registered shell/file/URL
commands (hibbiki omits it). Rationale: if `version.dll` is blocked by
AV, registered launches still stay portable. Chrome++ replaces the
switch with the same effective value when it loads, so there is no
conflict.

### 5. `bypass_windows_defender.bat` — port from hibbiki

- Port as-is (menu, UAC elevation, Add/Remove exclusion logic).
- **Deliberate deviation**: exclude the **portable root**
  (`%~dp0..` → `Helium_Portable\`) instead of the script's own dir
  (`%~dp0` → `Helium\`). `Data`/`Cache` live at root, so excluding only
  `Helium\` would leave user data scanned.

### 6. `debloater.reg` — unchanged

Structure-only scope. (`Policies\Helium` key confirmed correct by
closed issue #3.)

### 7. `.github/workflows/validate.yml`

- **Invert the `..\` check** for `chrome++.ini`: today it warns when
  `..\` is present; after the restructure `%app%\..\Data` is required.
  New checks: `data_dir=%app%\..\Data` present,
  `cache_dir=%app%\..\Cache` present; reject the old flat form
  `data_dir=%app%\Data`.
- `REQUIRED` file list: add `bypass_windows_defender.bat`.
- Build-workflow checks: keep the version.dll checks (broken-regex
  rejection, assertion, hard-fail); add asserts that `main.yml`
  references `Helium_Portable\Helium` assembly and the versioned
  Widevine path (`\$heliumVer\WidevineCdm`).
- update.bat checks unchanged (preamble untouched → Skip=11 still
  matches; the pre-existing cosmetic `-oP '\d+'` multi-match warning is
  out of scope).

### 8. `README.md`

- Replace the Files/Usage sections with the new layout diagram.
- Add **Migration (user cũ)**:
  1. Download & extract the new zip to a fresh folder.
  2. Copy the old `Data\` and `Cache\` folders into the new root
     (same paths as before — nothing else to move).
  3. Launch `Helium\chrome.exe`.

## Migration & Compatibility Matrix

| Scenario | Result |
|---|---|
| New user, new zip | Extract → root has `Helium/`; `Data/`, `Cache/` appear on first run |
| Existing user (flat install), new zip | Extract new zip, copy old `Data\`+`Cache\` → root; identical absolute paths, zero data loss |
| Existing user runs old `update.bat` on old layout | Unchanged behavior (still flat, still works) |
| Existing user runs new `update.bat` | Must be inside `Helium/` (fresh extract); updates browser files in place |
| Shortcuts registered by old default-apps bat | Point at old path with `--user-data-dir` → user should re-run the new default-apps bat after migrating |

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Versioned Widevine path not honored by Helium | Mirrors hibbiki exactly (same upstream Chromium mechanism); flat fallback documented as contingency (`Helium/WidevineCdm`) if DRM breaks in smoke test |
| DLL selection/pre-package assertions forgotten during edit | validate.yml hard-checks both remain in main.yml |
| `policy_key` sets false expectations | Disclosed as no-op in this spec + comment in ini |
| Old flat installs keep working while looking "restructured" | README migration section; old layout remains functional (no forced break) |

## Verification Plan

1. **Local**: run every `validate.yml` step in bash; YAML-parse both
   workflows.
2. **CI**: push → `Validate` workflow green.
3. **Rebuild**: `gh workflow run main.yml` → build x64 + arm64 green
   (hard-fail assertions must pass, proving files landed).
4. **Zip probe** (HTTP Range over release asset central directory):
   - root children == `Helium_Portable/Helium/` only
   - `Helium/chrome.exe`, `Helium/version.dll`,
     `Helium/chrome++.ini` (contains `%app%\..`),
     `Helium/update.bat`, `Helium/default-apps-multi-profile.bat`,
     `Helium/bypass_windows_defender.bat`, `Helium/debloater.reg`,
     `Helium/version.txt`
   - `Helium/<helium_ver>/WidevineCdm/manifest.json` and
     `.../widevinecdm.dll` present
   - no browser DLLs at zip root
5. **Manual smoke (user, Windows)**: run `Helium\chrome.exe` →
   `Helium_Portable\Data` created; copy folder to another machine →
   profile follows; optional DRM page check (Netflix) for Widevine.

## Decisions Log

| # | Decision | Rationale |
|---|---|---|
| 1 | Exact hibbiki layout (scripts inside `Helium/`) | User choice |
| 2 | Widevine nested `Helium/<ver>/WidevineCdm` | User choice; hibbiki-proven |
| 3 | Scope = structure + 3 hibbiki extras | User choice |
| 4 | Keep `--user-data-dir` in default-apps registrations | AV-blocked-DLL redundancy; no conflict with Chrome++ |
| 5 | Defender exclusion targets portable root | `Data`/`Cache` live at root |
| 6 | Keep `Chromium_SetDLL` provider | Proven working with Helium; `chrome-next-mini` switch out of scope |
