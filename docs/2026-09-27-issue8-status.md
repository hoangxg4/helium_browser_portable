# Issue #8 status — Yandex Browser Corporate (portable, debloated)

**Issue**: https://github.com/hoangxg4/helium_browser_portable/issues/8
**Outcome**: **FEASIBLE — delivered** as a standalone repo, not a Helium branch.
**Repo**: https://github.com/hcdbp24c3/yandex-browser-portable
**Status date**: 2026-09-29 (plan tasks 1–8 of 8 complete)

## Verdict

The request in issue #8 — *"package a debloated portable Yandex Browser that strips
built-in advertising, telemetry and AI integrations"* — was proven feasible by an
evidence-first spike and then shipped end-to-end through CI. The one hard gate
(consumer editions honoring `HKLM\SOFTWARE\Policies\YandexBrowser`) passed under a
headed measurement after headless CI proved unable to read `chrome://policy` at all.

## Shipped scope

Delivered in https://github.com/hcdbp24c3/yandex-browser-portable (release
`yandex-portable_26.8.4.893`):

- **Portable packaging** — official public `Yandex.exe` payload extracted in CI (7z
  branch, silent-install fallback), wrapped with Chrome++ `version.dll` so `Data\` and
  `Cache\` live at the package root. Entry point is `browser.exe`, not `chrome.exe`.
- **Debloat, safe-first** — exactly **11** policy keys under
  `HKLM\SOFTWARE\Policies\YandexBrowser`, each with a per-key purpose comment in
  `debloater.reg` and each verifiable on `chrome://policy` (`source = Platform`,
  `level = Mandatory`). Covers telemetry/crash reporting, background mode, auto-start,
  Alice prompts, NTP notifications/AI NTP tools, the Yandex button, search suggestions
  and both updater switches.
- **No-admin path** — profile preseed (`Local State`, `Default\Preferences`, empty
  `First Run` sentinel) ships in the package, so a non-elevated install is debloated
  through preferences even though the HKLM policies cannot be written.
- **Update flow** — `update.bat` (11-line bat + embedded PS) re-resolves the winget
  `PackageVersion`, stops the browser, rebuilds via the shipped `build-yandex.ps1`,
  copy-over with **protected-path hash asserts** (`chrome++.ini`, `update.bat`,
  `debloater.reg`, `version.txt`), **never touches `Data\`/`Cache\`**, migrates a
  versioned `WidevineCdm` folder to the flat exe-dir path, strips any reintroduced
  `service_update.exe`, and re-imports `debloater.reg`.
- **CI** — `validate.yml` (pins on every push), `build.yml` (check → build → release,
  fail-closed exists-gate, no duplicate publishes), `smoke.yml` (layout + 11-key policy
  check + EME probe + `update.bat` e2e → `Result: PASSED`), `spike.yml` (feasibility
  probe, kept for re-runs).
- **Tests** — `tests/build-yandex.tests.ps1` (70 assertions) and
  `tests/update.tests.ps1` (83 assertions), both green.

**Not** shipped, by explicit decision: no Corporate-MSI automation (login-gated), no
Yandex ID/sync, no Management Console integration, no bundled certificates, no
arm64/other-OS builds, no AI-feature integration.

## Accepted risk (EULA) — owner decision 2026-09-27

Yandex's browser agreement §4.1/§4.2
(https://yandex.ru/legal/browser_agreement/en/) prohibits distributing modified builds.
The owner **accepted this risk knowingly** when choosing CI-built releases over a
builder-only model: releases are published from this repository's CI, and **if Yandex
objects, only the releases are taken down — no code impact**. This is documented in the
repo README and in the design doc §6. Users remain responsible for compliance in their
own jurisdiction.

## 3-don't-touch (never disabled)

Enforced by `.github/workflows/validate.yml` pins, not by convention:

1. `SafeBrowsingProtectionLevel` — phishing/malware protection stays on.
2. `ComponentUpdatesEnabled` / `--disable-component-update` — disabling breaks
   Widevine/DRM; the literal string `--disable-component-update` must not appear in
   `chrome++.ini` or `build-yandex.ps1`.
3. Security updates — `UpdateAllowed=0` only stops the browser overwriting this
   portable tree in place (re-install deliberately from releases, pinned by
   `version.txt`); component updates keep running.

No state CA or any other certificate is bundled (nixpkgs `knownVulnerabilities`
rationale); trusting an extra root is left to the user.

## Spike evidence summary

Workflow `spike.yml`, findings in
[`docs/spike-findings.md`](https://github.com/hcdbp24c3/yandex-browser-portable/blob/main/docs/spike-findings.md):

| Gate | Verdict | Evidence |
|---|---|---|
| P1 extract | **PASS** | Branch A: winget payload is a 7z archive (`7z list exit=0`), nested `browser.7z` extracted; `PackageVersion=26.8.4.893`, `InstallerUrl` from the winget manifest; `WidevineCdm` ABSENT from the payload (registered at runtime by the component updater) |
| P2 Chrome++ | **PASS** | `version.dll` from `bibicadotnet/Chromium_SetDLL` 1.18.2 loads into `browser.exe`; portable `Data\`/`Cache\` created at `%app%\..`; `chrome++.ini` without `--disable-component-update` accepted. No `--user-data-dir` fallback needed |
| P3 policy (gate) | **HONORED** (headed) | Run H5 `36392580458`: with `HKLM\SOFTWARE\Policies\YandexBrowser\YandexAliceMsgDisable=1` set, `chrome://policy` lists the key `true / Platform / Machine / Mandatory` (Windows UI Automation, 2650 B); baseline 4497 B correctly absent; `Page.printToPDF` artifacts corroborate (72 592 B → 85 756 B); cleanup verified |
| P4 EME | **FAIL → WARN** | `NotSupportedError: Unsupported keySystem` in headless CI; component-installer *StartRegistration / FinishRegistration for Widevine* lines observed. Per plan decision rules this degrades the smoke assertion to WARN and never fails the verdict |

Headless `P3 = IGNORED` (10 runs) was a **measurement artifact**, not a policy
rejection: `--dump-dom` returns 0 bytes on this build, headless never commits navigation
to `chrome://`/`browser://`, and CDP on WebUI targets returns `Forbidden -32000` for 19
of 20 probed domains. Only `Page.printToPDF` and Windows UI Automation could read the
rendered page — both agree the key is honored.

Final gate line: `GO-NO-GO: GO — headed P3 HONORED, P1 PASS, P2 PASS, P4 degraded per plan`.

## CI status (all green)

| Workflow | Latest run | Conclusion |
|---|---|---|
| `validate.yml` | [36511952198](https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36511952198) | success |
| `build.yml` | [36511977961](https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36511977961) | success |
| `smoke.yml` | [36512151691](https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36512151691) | success — `Result: PASSED` |
| `spike.yml` | [36392580458](https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36392580458) | success |

Smoke verdict detail: all 16 assertions PASS — forced `version.txt = 0.0.0.0` bumped to
`26.8.4.893`, protected files byte-identical before/after, `Data\` intact, **11/11 keys
present pre- and post-update**, EME reported WARN per the spike-P4 rule, exit code 0.

## Remaining risks / open items

1. **Telemetry capture verification (honor-system).** A green `browser://policy` proves
   the *keys are honored*; it does **not** prove no packets leave the machine. The
   debloat is currently honor-system — a one-time packet capture during smoke hardening
   is scheduled as post-MVP work (design §6). Until then, treat "telemetry disabled" as
   "policy applied", not "traffic proven absent".
2. **Consumer-vs-corporate edition note.** CI builds from the public **consumer**
   `Yandex.exe`, because the Corporate MSI/exe requires a management-console login and
   is not scriptable from CI. The consumer build does load the corporate policy
   infrastructure — spike logs show `[CORP] YandexAntiTracking. Status: This policy is
   disabled.` and `Cloud management controller initialization aborted as CBCM is not
   enabled.` — so local HKLM policies are honored (P3 HONORED), but **cloud management
   (CBCM) / Management Console enrollment is inert and untested**. Features that only
   exist behind Corporate licensing are out of scope.
3. **Owner-transfer option.** The repo was created under a automation account
   (`hcdbp24c3`) because the transfer to `hoangxg4` failed; **the owner can transfer it
   at any time via GitHub → Settings → General → Transfer ownership** (UI action, no
   code change; the badge/links above only need the repository name to be updated
   afterwards). Until then the repo lives at
   https://github.com/hcdbp24c3/yandex-browser-portable.
4. **EULA takedown exposure** — accepted (see above); mitigation is that a takedown
   removes releases only, and `build-yandex.ps1` can rebuild locally from the official
   payload.
5. **DRM/Widevine never proven.** Spike P4 baseline was `CDM_FAIL`
   (`NotSupportedError: Unsupported keySystem` in headless CI), and the smoke EME rule
   deliberately degrades to **WARN** — so CI stays green even if Widevine never works.
   Users who need Netflix/DRM should verify Widevine on first run
   (`chrome://components` → *Widevine Content Decryption Module* → up to date, then a
   DRM test stream) before relying on this package for streaming.
6. **The package-root builder never refreshes.** `update.bat`'s copy-over scope is
   `Yandex\` only, so fixes to the package-root `build-yandex.ps1` never reach existing
   installs — an old install keeps rebuilding with its shipped (old) builder
   (chicken-and-egg; by design, since `update.bat` calls `$APP_DIR\..\build-yandex.ps1`
   from the package root). Re-extracting a fresh release picks up builder fixes.
7. **End-user update path calls the GitHub API unauthenticated.**
   `Get-LatestPackageVersion` hits `api.github.com` without a token unless one is set,
   which is limited to **60 requests/hour per IP** — users behind a shared/corporate NAT
   may see update failures from rate limiting. Mitigation: set a `GITHUB_TOKEN`
   environment variable before running `Yandex\update.bat` (the updater honors it).

## Links

- Repo: https://github.com/hcdbp24c3/yandex-browser-portable
- Latest release: https://github.com/hcdbp24c3/yandex-browser-portable/releases/latest
- Design doc: [`docs/plans/2026-09-27-yandex-browser-portable-design.md`](https://github.com/hcdbp24c3/yandex-browser-portable/blob/main/docs/plans/2026-09-27-yandex-browser-portable-design.md)
- Spike findings: [`docs/spike-findings.md`](https://github.com/hcdbp24c3/yandex-browser-portable/blob/main/docs/spike-findings.md)
- Original issue: https://github.com/hoangxg4/helium_browser_portable/issues/8
