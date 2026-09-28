# Yandex Browser Portable — Design

**Date:** 2026-09-27 · **Status:** validated with owner (section-by-section) · **Origin:** issue https://github.com/hoangxg4/helium_browser_portable/issues/8

Build a self-contained, debloated, portable **Yandex Browser** package (targeting the
Corporate/enterprise feature set where reachable), in the same spirit as the Helium
portable pipeline (https://github.com/hoangxg4/helium_browser_portable) but in this
separate repo.

## 1. Decisions (validated with owner)

| # | Decision | Rationale |
|---|---|---|
| 1 | **New standalone repo** (`yandex-browser-portable`, public) | Separate branding/issue tracker from Helium; only CI *patterns* are borrowed, no code dependency |
| 2 | **Distribution = CI-built releases** (zip published on GitHub Releases) | Owner's explicit choice over the lower-risk "builder-only" model. **Accepted risk: EULA §4.1/§4.2 prohibit distributing modified builds** (https://yandex.ru/legal/browser_agreement/en/; PortableApps precedent: https://portableapps.com/node/37163). If Yandex objects, releases are taken down — no code impact. Owner decision 2026-09-27. |
| 3 | **Debloat depth = safe-first, ~10 policies** | Every key verifiable via `browser://policy`; no undocumented/domain-only keys in MVP |
| 4 | **Full update flow in MVP** (`update.bat` Yandex-flavored) | Not deferred; modeled on Helium's #5 lessons (protected paths + EME re-verify post-update) |
| 5 | **Spike (Task 0) gates implementation** | Two unverified assumptions must be proven on a real Windows runner first (§5) |
| 6 | x64 only, one version line | YAGNI: no arm64, no sync/console integration, no Linux/macOS in MVP |

## 2. Architecture

```
[build.yml]  check (resolve latest public Yandex version)
     ↓
 build (windows-latest)
   1. Download official Yandex.exe (public CDN URL)
   2. Extract payload 7z (installer chain: Yandex.exe → setup.exe
      --install-archive=BROWSER.PACKED.7Z; installed tree ships
      Installer\browser.7z — classic Chromium mini_installer pattern)
   3. Arrange portable layout: browser.exe + Chrome++ version.dll
      → portable Data\, Cache\ (chrome++.ini relative paths)
   4. Apply debloater.reg (~10 policies) + Preferences/Local State preseed
   5. Strip updater (service_update.exe, UpdateAllowed=0)
   6. Compress → yandex-portable_<ver>.zip
     ↓
 release (softprops/action-gh-release, unified tag scheme)

[validate.yml]  bash harness pinning structure (same pattern as Helium)
[smoke.yml]     windows-latest: layout asserts → browser://policy verify
                (10 keys applied) → EME/Widevine probe → update-flow e2e
                → verdict step (summary.md + exit code)
```

Repo layout: `build-yandex.ps1` (extractor — runs in CI and locally),
`debloater.reg`, `chrome++.ini`, `update.bat`, `README.md`, `.github/workflows/*`.

## 3. Builder stages (`build-yandex.ps1`, idempotent)

1. **Resolve source** — `-Installer <path>` (user-supplied) or `-Download` (CI, public
   URL); verify version string from the binary.
2. **Extract** — two detection branches: outer exe resource archive, or post-silent-install
   `Installer\browser.7z`; hard-fail with a clear message when neither matches.
3. **Layout** — output `Yandex_Portable\{Yandex\..., Data\, Cache\}`; patch `chrome++.ini`
   (relative data/cache dirs, launcher targets `browser.exe` — NOT chrome.exe); copy
   `version.dll`.
4. **Debloat** — merge `debloater.reg` into `HKLM\SOFTWARE\Policies\YandexBrowser`
   (official policy branch — Yandex does NOT read Chromium's `Policies\Chromium`) +
   preseed `Local State` / `Default\Preferences` with Yandex-specific keys and an empty
   `First Run` sentinel (required, else Yandex discards hand-made profile files).
5. **Strip updater** — remove `service_update.exe` / `yupdate-exec.exe`, set
   `UpdateAllowed=0`, `BackgroundUpdateAllowed=0`.

### Debloat set (~10 keys, safe-first)

`StatisticsReporting=0`, `CrashesReporting=0`, `BackgroundModeEnabled=0`,
`YandexAutoLaunchMode=never`, `YandexAliceMsgDisable=1`, `NeuroNtpTools=0`,
`NtpNotificationsDisable=0`, `YandexButtonDisable=1`, `SearchSuggestEnabled=0`,
`UpdateAllowed=0`, `BackgroundUpdateAllowed=0`.

**Never disable (documented in reg comments + enforced by validate pins):**
SafeBrowsing lookups (`SafeBrowsingProtectionLevel` untouched),
`ComponentUpdatesEnabled` (Widevine/DRM), security updates beyond `UpdateAllowed`
rationale. Per policy reference: https://browser.yandex.ru/support/browser-corporate/ru/policy/list-en
(ADMX: https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx).

## 4. Update flow (`update.bat`)

Helium-#5 lessons applied directly: stop `browser.exe` → fetch latest official
`Yandex.exe` → re-extract to a fresh dir → **copy-over with `protectedPaths`**
(`chrome++.ini`, `update.bat`, `debloater.reg`, `Data\`, `Cache\`) → re-apply migration
if layout changed → verify EME/CDD afterwards. Profile (Data\) survives version bumps;
policies re-applied from `debloater.reg` if the update overwrote registry. Smoke asserts
CDM resolution **after** update (flat exe-dir rule — Helium Chrome-154 lesson: Chrome
family registers the preinstalled CDM only from the exe-dir flat path).

## 5. Task 0 spike (gates everything)

Single `spike.yml` (workflow_dispatch, windows-latest) answering, with log evidence:

1. **Chrome++ compat:** does `version.dll` load into `browser.exe` and relocate
   Data/Cache? Fallback if no: `--user-data-dir` launcher (Tensionix precedent
   https://github.com/Tensionix/yandex-portable).
2. **Policy honoring:** does the *consumer* build (CI cannot log in to the Corporate
   console to fetch the MSI) read `HKLM\SOFTWARE\Policies\YandexBrowser`?
   Dump `browser://policy` after applying test keys. Fallback if no: prefs-preseed-only
   debloat, or require user-supplied Corporate MSI.
3. **Extract mechanics:** confirm which of the two extraction branches works on the
   current public installer; record the exact installed file tree.
4. **EME baseline:** `navigator.requestMediaKeySystemAccess('com.widevine.alpha')`
   probe (title/pre anchored parsing, as in Helium) to establish Widevine works before
   any debloat touches component settings.

If (1) or (2) fails hard, stop and re-plan with the owner — do not build on assumptions.

## 6. Risks

| Risk | Handling |
|---|---|
| EULA §4.1/§4.2 (redistribute modified build) | **Accepted risk (owner, 2026-09-27)**; documented here + README; takedown = drop releases only |
| Russian state CA trust (nixpkgs `knownVulnerabilities`) | Do NOT bundle any certs; README note that users may opt in themselves |
| Disabling security/DRM surfaces | 3-don't-touch list (§3) enforced by validate pins |
| Consumer edition ignores policies | Spike Task 0 gate → fallback branch decided with owner |
| Chrome++ incompatible with `browser.exe` | Spike Task 0 gate → `--user-data-dir` launcher fallback |
| Telemetry stops only honor-system | One-time packet capture during smoke hardening (post-MVP) |

## Evidence index (research, 2026-09-27)

- Installer 7z chain: ANY.RUN reports (`setup.exe --install-archive=BROWSER.PACKED.7Z`)
- Prior art (extraction + Chrome++ launcher): https://github.com/Tensionix/yandex-portable
- Debloat prior art: https://github.com/wtxsu/yandex-browser-debloat, https://github.com/awesome-windows11/yandex
- Policy list / registry path: browser.yandex.ru/support/browser-corporate (`HKLM\SOFTWARE\Policies\YandexBrowser`)
- EULA: https://yandex.ru/legal/browser_agreement/en/
- Chromium base: 150 (Yandex 26.x, 2026); main exe is `browser.exe`, versioned app dir
- Corporate MSI/exe require management-console login (not scriptable from CI)
