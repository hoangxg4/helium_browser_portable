# Yandex Browser Portable

[![Validate](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/validate.yml/badge.svg)](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/validate.yml)
[![Build](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/build.yml/badge.svg)](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/build.yml)
[![Smoke](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/smoke.yml/badge.svg)](https://github.com/hcdbp24c3/yandex-browser-portable/actions/workflows/smoke.yml)

A self-contained, debloated, **portable Yandex Browser**: no installer, no background
service, no self-update — profile and cache live next to the app, so the whole package is
a folder you can move, copy or delete.

Built in CI from the official public `Yandex.exe` payload and wrapped with Chrome++
(`version.dll`) so `Data\` and `Cache\` stay at the package root.

**Docs**: [design](docs/plans/2026-09-27-yandex-browser-portable-design.md) ·
[spike findings](docs/spike-findings.md) ·
[issue #8 status](docs/2026-09-27-issue8-status.md) ·
[releases](https://github.com/hcdbp24c3/yandex-browser-portable/releases/latest)

Origin: https://github.com/hoangxg4/helium_browser_portable/issues/8

### Features

- Portable: everything under one folder, nothing written outside it
- Safe-first debloat: exactly 11 documented policies, every one verifiable on `chrome://policy`
- Telemetry, crash reporting, background mode, auto-start, Alice prompts, AI new-tab tools
  and search suggestions disabled
- Updater stripped; version is pinned in `version.txt` and refreshed by `update.bat`
- Widevine/DRM and SafeBrowsing deliberately left untouched

## Accepted EULA risk (read this)

Yandex's browser agreement (§4.1/§4.2, https://yandex.ru/legal/browser_agreement/en/)
prohibits redistributing modified builds. The owner accepted this risk on 2026-09-27:
releases are published from this repository's CI and **if Yandex objects, only the
releases are taken down — no code impact**. You are responsible for complying with the
agreement in your jurisdiction.

## Layout

```
yandex-portable_<ver>/
├── build-yandex.ps1        builder/extractor (also kept at package root)
├── chrome++.ini            Chrome++ config: Data\ and Cache\ at package root
├── debloater.reg           11 safe-first policies (HKLM\SOFTWARE\Policies\YandexBrowser)
├── update.bat              updater (re-installs from GitHub Releases)
├── version.txt             version = winget PackageVersion (sole source of truth)
├── Yandex/                 browser tree
│   ├── browser.exe         entry point (NOT chrome.exe)
│   ├── version.dll         Chrome++ launcher (or launch.bat fallback — spike P2)
│   └── WidevineCdm/        flat exe-dir CDM path, only if the CDM was shipped/registered
├── Data/                   profile (created on first run)
└── Cache/                  cache (created on first run)
```

## Usage

1. Download the latest release zip from
   [Releases](https://github.com/hcdbp24c3/yandex-browser-portable/releases/latest)
   (`yandex-portable_<ver>.zip`, currently **26.8.4.893**) and extract it anywhere
   (no admin needed to extract).
2. Start `Yandex\browser.exe`.

### Applying the debloat policies

`debloater.reg` writes to `HKLM\SOFTWARE\Policies\YandexBrowser`, which is a
machine-wide (HKLM) key:

- **With admin rights** — double-click `debloater.reg` and confirm, or from an
  elevated prompt run `reg import debloater.reg`. Verify afterwards on
  `chrome://policy`: each key shows `source = Platform`, `level = Mandatory`
  (proven in spike P3, headed run H5).
- **Without admin rights** — the registry policies cannot be applied (HKLM write is
  denied). The build's **preseeded preferences debloat still applies automatically**
  from `Data\` (`Local State` / `Default\Preferences` + `First Run` sentinel), so the
  no-admin install is debloated too, just through prefs instead of policies.

> Note: CI's smoke job runs `reg import debloater.reg` only to prove the file parses;
> it **never applies policies to end users** — applying them is your explicit step.

### Debloat set (11 keys)

`StatisticsReporting=0`, `CrashesReporting=0`, `BackgroundModeEnabled=0`,
`YandexAutoLaunchMode=2 (never)`, `YandexAliceMsgDisable=1`, `NeuroNtpTools=0`,
`NtpNotificationsDisable=1`, `YandexButtonDisable=1`, `SearchSuggestEnabled=0`,
`UpdateAllowed=0`, `BackgroundUpdateAllowed=0`.

### 3-don't-touch (never disabled here)

- `SafeBrowsingProtectionLevel` — phishing/malware protection stays on
- `ComponentUpdatesEnabled` / `--disable-component-update` — disabling breaks Widevine/DRM
- Security updates beyond the `UpdateAllowed` rationale — `UpdateAllowed=0` only stops the
  browser overwriting this portable tree in place; you re-install deliberately from the
  releases (pinned by `version.txt`). Component updates keep running.

These are pinned by `.github/workflows/validate.yml`.

## State CA note

**We bundle no certificates** — no state CA, no custom roots, nothing added to the trust
store. If you want to trust an extra CA (corporate proxy, national root), do it yourself
and know the risk (see nixpkgs `knownVulnerabilities` for why shipping state roots is a
bad default).

## Update

Run `update.bat` — it fetches the latest official release of this package, stops
`browser.exe`, copies over the protected files (`chrome++.ini`, `update.bat`,
`debloater.reg`, `version.txt` — `Data\` and `Cache\` are never touched), migrates a
versioned `WidevineCdm` folder to the flat exe-dir path, re-applies policies and
re-checks EME/Widevine.

## Building

`build-yandex.ps1` is the CI/local builder: it extracts the official `Yandex.exe`
payload (7z branch, silent-install fallback), lays out the package, seeds the
preseeded profile, strips the self-updater and writes `layout-manifest.txt`. It ships
at the package root so `update.bat` can reuse it for rebuilds.

CI lives in `.github/workflows/`:

| Workflow | Purpose |
|---|---|
| `validate.yml` | Pins on every push: required files, 11-key + exact-count debloater pins, never-touch guards, `chrome++.ini` portability, workflow-file pins |
| `build.yml` | check → build → release: resolves winget `PackageVersion`, publishes `yandex-portable_<ver>.zip` only when that tag has no release yet (hourly + manual) |
| `smoke.yml` | Verdict job on `windows-latest`: layout asserts, 11/11 keys on `browser://policy`, EME probe (WARN on the known baseline), full `update.bat` e2e with protected-hash asserts → `Result: PASSED` |
| `spike.yml` | One-off feasibility probe (kept for re-runs) — evidence in [`docs/spike-findings.md`](docs/spike-findings.md) |

Local test suites: `pwsh -NoProfile -File tests/build-yandex.tests.ps1` (70 assertions)
and `pwsh -NoProfile -File tests/update.tests.ps1` (83 assertions).
