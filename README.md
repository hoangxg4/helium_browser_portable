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
