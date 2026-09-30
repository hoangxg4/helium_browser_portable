# Issue #1 claims — empirical findings (feature `yandex-issue1-claims-test`)

**Status: PENDING** — this is the Task 1 skeleton. Every `T<n> verdict:` line below is
copied verbatim from the `.github/workflows/claims.yml` run log once the first run
completes (Task 1 Step 4); until then each line says `PENDING - not run yet`.

- Repo: `hcdbp24c3/yandex-browser-portable`, branch `main`
- Workflow: `.github/workflows/claims.yml`, dispatch input `test=all` (T1–T8; T9 = launcher, Task 2)
- First run: PENDING
- Method: one `windows-latest` job, ordered T2 → T3 → T4 → T5 → T6 → T7 → T8 → T1
  (T1 writes HKCU and must run last so a leak cannot contaminate the others).
  A probe `FAIL` is a finding, not a workflow failure: the job only fails when a
  selected probe emitted no verdict line or the shared source install failed.

## Verdict table (issue sections §1–§8)

| Issue section | Claim (short) | Verdict | Probes |
|---|---|---|---|
| §1 Global multi-language support | bilingual (EN/RU) everywhere | PENDING | T8 |
| §2 Upstream base → Corporate/Enterprise | switch to Corporate edition | PENDING | T4 |
| §3 Radical payload trimming (~26 files) | strip to 26 essential files | PENDING | T3 |
| §4 Portable DLL redirection (`version.dll`) | side-by-side DLL relocates Data/Cache | PENDING | spike P2 (prior evidence) |
| §5 Non-admin HKCU policies | HKCU\Software\Policies honored | PENDING | T1, T2 |
| §6 Deep profile preseed | preseeded `Preferences`/`Local State` keys exist | PENDING | T5, T6 |
| §7 Automated profile & cache maintenance | cache/crashpad pruning is safe | PENDING | T7 |
| §8 Native Go launcher, bilingual | mutex + HKCU lifecycle + prune (MVP mechanics) | PENDING | T9 (Task 2) |

Verdict vocabulary for the final table (Task 3): `CONFIRMED` / `PARTIALLY-TRUE` /
`REFUTED` / `SCOPE-REJECTED`.

## Verdict lines (verbatim from the run log)

```
T1 verdict: PENDING - not run yet
T2 verdict: PENDING - not run yet
T3 verdict: PENDING - not run yet
T4 verdict: PENDING - not run yet
T5 verdict: PENDING - not run yet
T6 verdict: PENDING - not run yet
T7 verdict: PENDING - not run yet
T8 verdict: PENDING - not run yet
```

---

## T1 — HKCU policy honored at runtime (issue §5)

**Verdict: PENDING.**

Procedure: fresh tree → `reg add HKCU\Software\Policies\YandexBrowser` with
`YandexAliceMsgDisable=1` and `Telemetry=1` (REG_DWORD) → headed launch with
`chrome://policy/` as the startup URL and `--force-renderer-accessibility` →
Windows UIA dump (`probe/uia-dump.ps1`, spike H4/H5 path; CDP is Forbidden on
WebUI targets) → `HONORED` when both names are listed, `IGNORED` when absent →
`finally`: delete both values and the key, log proof of removal.

## T2 — ADMX audit of issue §5 key names (Discovery re-run in CI)

**Verdict: PENDING.**

Local Discovery evidence (2026-09-29, re-verified by T2 in CI for reproducibility):
`https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx` is UTF-16LE,
**461 `<policy>` elements, all `class="Both"`** (both Machine + User, i.e. HKCU is
plausible — runtime proof is T1). Issue §5 cites exactly 9 key names:
**4 EXIST** (`SpellCheckServiceEnabled`, `AutofillCreditCardEnabled`,
`AutofillAddressEnabled`, `DefaultSearchProviderEnabled`) and **5 are fabricated**
(`MetricsReportingEnabled`, `YandexAliceEnabled`, `FeedbackAllowed`,
`PromotionalTabsEnabled`, `BrowserAddPersonEnabled`). All 11 shipped names
(`StatisticsReporting`, `CrashesReporting`, `BackgroundModeEnabled`,
`YandexAutoLaunchMode`, `YandexAliceMsgDisable`, `NeuroNtpTools`,
`NtpNotificationsDisable`, `YandexButtonDisable`, `SearchSuggestEnabled`,
`UpdateAllowed`, `BackgroundUpdateAllowed`) are present. Real counterparts:
telemetry → `StatisticsReporting`/`Telemetry`/`TelemetrySelective`; Alice → only
`YandexAliceMsgDisable`.

## T3 — Trim-group safety (issue §3)

**Verdict: PENDING.**

Baseline capability capture on a throwaway copy (page capture, WebGL, EME vs the
spike-P4 `CDM_FAIL` baseline), then one fresh copy per group —
A: `clidmgr.exe`+`browser_proxy.exe`+`clids_*.xml`, B: `widgets\`,
C: `voiceactivation\`, D: `web_app_config\`, E: `Locales` keep only `en-US.pak` —
each trimmed, re-probed and compared to baseline (`SAFE`/`BROKEN` + bytes saved).
Group E is kept for T8. This MEASURES safety only; adopting a trim step into the
builder is a separate owner decision (plan Non-Goals).

## T4 — Corporate availability (issue §2)

**Verdict: PENDING.**

Probes 3 corporate CDN candidates under `download.cdn.yandex.net/browser/corporate/`
plus the public landing page `https://yandex.com/support/browser/business/en/`
(HEAD, GET fallback, installer-like hrefs grepped from the landing page).
A 404 alone is **never** stated as proof of login-gating; the verdict only records
what was observed, alongside prior research (Corporate MSI is login-gated).

## T5 — Preseed key existence after first run (issue §6)

**Verdict: PENDING.**

Fresh builder layout → headed launch so the first-run NTP opens naturally →
graceful close → diff `Data\Default\Preferences` + `Data\Local State` before vs
after for the exact issue-named keys: `neuro_question`, `video_button_enabled`,
`show_ya_button`, `app_side_promo_service_enabled`, `alissenger`,
`default_apps_installed` (status `ABSENT`/`PRESEEDED`/`MATERIALIZED`/`LOST`).

## T6 — Atomic write acceptance (issue §6/#7 support)

**Verdict: PENDING.**

Benign probe key written via `.tmp` + `File.Replace` → relaunch → assert the value
is read back, `Preferences` is still valid JSON, and no corruption leftovers
(`*.tmp`, `*.journal`, `*.bak`) remain.

## T7 — Cache prune safety (issue §7)

**Verdict: PENDING.**

Warm-up launch → delete `GPUCache`, `ShaderCache`, `GrShaderCache`, `DawnCache`,
`Default\Cache`, `Default\Code Cache`, `Default\Service Worker\CacheStorage`,
`Crashpad`, `BrowserMetrics-*` → relaunch + dump. Rule: PASS needs relaunch OK,
≥1 dir recreated and no missing launch-critical dir (`GPUCache`, `Default\Cache`);
event-driven dirs (`Crashpad`, `BrowserMetrics-*`) are reported but never fail the
probe by themselves.

## T8 — Locale trim render check (issue §1)

**Verdict: PENDING.**

Reuses the T3 group-E tree (`Locales` trimmed to `en-US.pak`; builds its own trim
if T3-E is unavailable), launches, captures a local page and asserts real text
rendered (non-empty body + `navigator.language` in the title, `en*`).

---

## Evidence / run links

| Probe | Run | Log evidence |
|---|---|---|
| T1 | PENDING | PENDING |
| T2 | PENDING | PENDING |
| T3 | PENDING | PENDING |
| T4 | PENDING | PENDING |
| T5 | PENDING | PENDING |
| T6 | PENDING | PENDING |
| T7 | PENDING | PENDING |
| T8 | PENDING | PENDING |

## Corrections to issue #1 (probe-backed)

PENDING (Task 3 aggregates after T1–T9).

## Owner decisions

PENDING (Task 3 asks and records; adoptions are implemented in a follow-up feature).
