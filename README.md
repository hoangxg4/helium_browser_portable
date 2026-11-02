# Helium Portable

Helium Browser Portable - Chromium-based browser by [imputnet](https://github.com/imputnet/helium-windows), packaged as a portable version with Chrome++ for local data storage and debloating.

### Features
- Helium Portable with all data stored locally, no installation required
- Chrome++ integration for portable data directory and cache
- Debloated with privacy-focused policies (disabled AI, tracking, telemetry)
- Widevine CDM support for DRM content
- Auto-update script to fetch latest Helium releases

### Downloads
Releases are published **per version pair** on the [Releases page](https://github.com/hoangxg4/helium_browser_portable/releases):
- One release per Helium + Chrome++ combination, tagged `helium-portable_{Helium}_{Chrome++}` (e.g. `helium-portable_0.18.1.1_1.18.2`), containing both arch zips when both were built:
  - `helium-portable-x64_{Helium}_{Chrome++}.zip` — Intel/AMD 64-bit
  - `helium-portable-arm64_{Helium}_{Chrome++}.zip` — ARM64
- Grab the newest pair; pick the zip matching your CPU
- Older per-arch releases (`helium-portable-x64_...` / `helium-portable-arm64_...` tags) are retained alongside for history

### Layout
```
Helium_Portable/
├── Helium Browser.bat          ← double-click this to start the browser
├── Update Helium.bat           update to the latest Helium build
├── Set Default Browser.bat     register Helium in Windows Settings
├── Apply Debloat Policies.bat  import debloater.reg (privacy + update policies)
├── Defender Exclusion.bat      add/remove a Defender exclusion for this folder
├── README-FIRST.txt            short quick-start note (plain text)
├── Helium/                     browser + fixed files (must stay here)
│   ├── chrome.exe
│   ├── version.dll, chrome++.ini
│   ├── update.bat
│   ├── default-apps-multi-profile.bat
│   ├── bypass_windows_defender.bat
│   ├── debloater.reg
│   ├── version.txt
│   └── WidevineCdm/            x64 build only
├── Data/                       runtime profile (created on first run)
└── Cache/                      runtime cache (created on first run)
```

The launchers at the package root are plain `.bat` files, not shortcuts, on purpose: they resolve
everything from their own location, so the package keeps working after being moved or extracted
anywhere (a `.lnk` stores an absolute path and breaks). They call into `Helium\` for you —
`Helium\chrome.exe` cannot move to the root, because Chrome++ (`version.dll`) must sit next to
`chrome.exe` and the profile/cache paths in `chrome++.ini` are resolved relative to it.

### Files (inside `Helium/`)
- `chrome++.ini` — Chrome++ configuration (data at `../Data`, cache at `../Cache`, Crashpad at `../Data/Crashpad`)
- `debloater.reg` — Disable unnecessary Chromium features (import once; also the switch that keeps component updates off)
- `default-apps-multi-profile.bat` — Set Helium as default browser
- `update.bat` — Auto-update to the latest Helium release
- `bypass_windows_defender.bat` — Add/remove Windows Defender exclusion for the whole portable folder

### Widevine / DRM notes
- The CDM ships at `Helium\WidevineCdm` (flat, next to `chrome.exe`). That is the only path Chrome 154+
  registers a preinstalled CDM from — a versioned `Helium\<ver>\WidevineCdm` nesting is ignored.
- `chrome++.ini` must **not** carry `--disable-component-update`: it also disables registration of *preinstalled*
  components, so the shipped CDM would never be found. Component updates stay disabled through the
  `ComponentUpdatesEnabled=0` policy in `debloater.reg` instead.
- **x64 only.** The CDM is Google's build redistributed by
  [`macchrome/winchrome`](https://github.com/macchrome/winchrome) (x64 only, `update-widevine.yml` keeps it
  current and refuses to downgrade or to commit a broken payload). No arm64 Widevine CDM exists for Windows, so
  the **arm64 build ships no CDM at all** — it cannot play DRM-protected streams. Shipping the x64 module in the
  arm64 zip only created a package that looked DRM-enabled and silently failed.
- Playback security level is decided by the CDM and the license server, not by this package. Hardware-backed
  levels (`HW_SECURE_*`, i.e. L1) need OEM-provisioned hardware; nothing in a portable zip can add them.

### Usage
1. Download the latest release zip
2. Extract to any folder (keep the structure intact)
3. Run `Helium Browser.bat` in the extracted folder to start

> Shortcut tip: point any shortcut you create at `Helium\chrome.exe` and set its **Start in** field
> to the `Helium\` folder. Launching `chrome.exe` with an unrelated working directory can make the
> relative profile/cache/Crashpad paths resolve elsewhere.

### Update from an older release of this package
- If your folder does not have the `.bat` launchers at the root, re-extract the new zip and copy your
  `Data\`/`Cache\` (and, if present, `Helium\WidevineCdm`) into it — or simply pick the launchers up
  from the new zip and drop them next to your existing `Helium\` folder.

### Update from the old (flat) layout
1. Extract the new zip to a fresh folder
2. Copy `Data\` and `Cache\` from the old folder into the new folder's root (paths are unchanged — nothing else to migrate)
3. Run `Helium\chrome.exe`; re-run `Helium\default-apps-multi-profile.bat` if you had registered default-browser shortcuts
