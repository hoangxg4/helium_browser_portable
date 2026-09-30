# Issue #1 claims — empirical findings (feature `yandex-issue1-claims-test`)

**Status: RUN COMPLETE (Task 1)** — every `T<n> verdict:` line below is copied
verbatim from the successful `claims.yml` run log (run 36664258871, 2026-09-30).
The §1–§8 verdict column and the Corrections/Owner-decisions sections stay
`PENDING` until Task 3 aggregates T1–T9 into issue verdicts.

- Repo: `hcdbp24c3/yandex-browser-portable`, branch `main`
- Workflow: `.github/workflows/claims.yml`, dispatch input `test=all` (T1–T8; T9 = launcher, Task 2)
- Source run: https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36664258871
  (`completed success`, 26 `T[1-8] verdict:` lines in the log, ≥8 required)
- Probe-development runs: 36661822112 and 36663223628 (both `success`) — these
  exposed two probe defects which were fixed test-first: T6 `File.Replace($null)`
  empty-path binding, and T8's wrong `navigator.language in (en*)` expectation
  (negotiated `lang=ru` on an en-US-only tree with a fully rendered page; the
  judge now assesses the render, not the language tag). The final run contains
  the corrected probes.
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

Run 36664258871, `Verify verdicts` step (probe-side copies are identical):

```
T2 verdict: 5 of 9 claimed names fabricated; 461 policies; all class=Both
T3 verdict: SAFE - group A; broken=(); saved=2872078 bytes of 515092109; dump OK->OK; webgl OK->OK; eme OK (baseline OK); deleted=D:\a\_temp\claims\trees\gA\Yandex\clidmgr.exe,D:\a\_temp\claims\trees\gA\Yandex\browser_proxy.exe,D:\a\_temp\claims\trees\gA\Yandex\clids_yandex_second.xml,D:\a\_temp\claims\trees\gA\Yandex\clids_yandex.xml; absent=none
T3 verdict: BROKEN - group B; broken=(Dump,Webgl,Eme); saved=14936976 bytes of 515092109; dump OK->BROKEN; webgl OK->BROKEN; eme NO_RESULT (baseline OK); deleted=D:\a\_temp\claims\trees\gB\Yandex\26.8.4.893\widgets; absent=none
T3 verdict: SAFE - group C; broken=(); saved=1427748 bytes of 515092109; dump OK->OK; webgl OK->OK; eme OK (baseline OK); deleted=D:\a\_temp\claims\trees\gC\Yandex\26.8.4.893\voiceactivation; absent=none
T3 verdict: SAFE - group D; broken=(); saved=934475 bytes of 515092109; dump OK->OK; webgl OK->OK; eme OK (baseline OK); deleted=D:\a\_temp\claims\trees\gD\Yandex\26.8.4.893\web_app_config; absent=none
T3 verdict: SAFE - group E; broken=(); saved=8826180 bytes of 515092109; dump OK->OK; webgl OK->OK; eme OK (baseline OK); deleted=cs_FEMININE.pak,cs_MASCULINE.pak,cs_NEUTER.pak,cs.pak,de_FEMININE.pak,de_MASCULINE.pak,de_NEUTER.pak,de.pak,en-US_FEMININE.pak,en-US_MASCULINE.pak,en-US_NEUTER.pak,es_FEMININE.pak,es_MASCULINE.pak,es_NEUTER.pak,es.pak,fr_FEMININE.pak,fr_MASCULINE.pak,fr_NEUTER.pak,fr.pak,it_FEMININE.pak,it_MASCULINE.pak,it_NEUTER.pak,it.pak,ja_FEMININE.pak,ja_MASCULINE.pak,ja_NEUTER.pak,ja.pak,kk_FEMININE.pak,kk_MASCULINE.pak,kk_NEUTER.pak,kk.pak,pt-BR_FEMININE.pak,pt-BR_MASCULINE.pak,pt-BR_NEUTER.pak,pt-BR.pak,pt-PT_FEMININE.pak,pt-PT_MASCULINE.pak,pt-PT_NEUTER.pak,pt-PT.pak,ru_FEMININE.pak,ru_MASCULINE.pak,ru_NEUTER.pak,ru.pak,tr_FEMININE.pak,tr_MASCULINE.pak,tr_NEUTER.pak,tr.pak,uk_FEMININE.pak,uk_MASCULINE.pak,uk_NEUTER.pak,uk.pak,uz_FEMININE.pak,uz_MASCULINE.pak,uz_NEUTER.pak,uz.pak,zh-CN_FEMININE.pak,zh-CN_MASCULINE.pak,zh-CN_NEUTER.pak,zh-CN.pak,zh-TW_FEMININE.pak,zh-TW_MASCULINE.pak,zh-TW_NEUTER.pak,zh-TW.pak; absent=none
T3 verdict: BROKEN - groups B broke a capability vs baseline; per-group lines above; saved: A=2872078B, B=14936976B, C=1427748B, D=934475B, E=8826180B; baselineBytes=515092109
T4 verdict: PUBLIC-ENDPOINT https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx (HTTP 200)
T5 verdict: neuro_question=ABSENT, video_button_enabled=ABSENT, show_ya_button=PRESEEDED, app_side_promo_service_enabled=PRESEEDED, alissenger=PRESEEDED, default_apps_installed=PRESEEDED; first-run: 6 EXIST (0 materialized, 4 preseeded, 0 lost, 2 absent)
T6 verdict: PASS - atomic .tmp+File.Replace accepted: probe key read back after relaunch, JSON valid, no leftovers (dir Preferences files: Preferences)
T7 verdict: PASS - rule: relaunch ok + >=1 dir recreated + no missing GPUCache/Default\Cache (event-driven dirs reported only); relaunch=ok; recreated=ShaderCache,GrShaderCache,Default\Cache,Default\Code Cache,Crashpad; missing=none; event-driven=none; critical-missing=none
T8 verdict: PASS - rendered with lang=ru (negotiation is profile/OS-level; en-US-only pak trim keeps the render); domBytes=722 (source=reused T3-E tree; Locales=[en-US.pak])
T1 verdict: IGNORED - YandexAliceMsgDisable, Telemetry absent from chrome://policy after HKCU reg add (via=uia bytes=10269)
```

All lines above are byte-identical to the run log (the T3 group-E line alone
carries the 63 deleted non-en-US paks: `en-US.pak` is kept, the three
`en-US_{FEMININE,MASCULINE,NEUTER}.pak` variants and 15 other languages x
(base + 3 gender variants) are removed).

---

## T1 — HKCU policy honored at runtime (issue §5)

**Verdict: IGNORED** — after `reg add` of `YandexAliceMsgDisable=1` and
`Telemetry=1` under `HKCU\Software\Policies\YandexBrowser`, neither name
appeared in `chrome://policy/` (UIA dump 10269 bytes; the `finally` cleanup
removed both values and the key). The probe does not claim why — chrome://policy
may refresh asynchronously or the page may list only a subset — but the issue §5
"HKCU values are honored at runtime" claim was NOT observed for these two keys.

Procedure: fresh tree → `reg add HKCU\Software\Policies\YandexBrowser` with
`YandexAliceMsgDisable=1` and `Telemetry=1` (REG_DWORD) → headed launch with
`chrome://policy/` as the startup URL and `--force-renderer-accessibility` →
Windows UIA dump (`probe/uia-dump.ps1`, spike H4/H5 path; CDP is Forbidden on
WebUI targets) → `HONORED` when both names are listed, `IGNORED` when absent →
`finally`: delete both values and the key, log proof of removal.

## T2 — ADMX audit of issue §5 key names (Discovery re-run in CI)

**Verdict: `5 of 9 claimed names fabricated; 461 policies; all class=Both`** —
independently re-confirmed in CI (same result as local Discovery).

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

**Verdict: BROKEN — group B (`widgets\`) broke a capability vs baseline;
groups A, C, D, E SAFE.** Per-group results (baseline 515,092,109 bytes):

| Group | Trim | Verdict | Broken | Saved |
|---|---|---|---|---|
| A | `clidmgr.exe`, `browser_proxy.exe`, `clids_*.xml` | SAFE | — | 2,872,078 B |
| B | `widgets\` | **BROKEN** | Dump, WebGL, EME (NO_RESULT) | 14,936,976 B |
| C | `voiceactivation\` | SAFE | — | 1,427,748 B |
| D | `web_app_config\` | SAFE | — | 934,475 B |
| E | `Locales\` keep `en-US.pak` | SAFE | — | 8,826,180 B |

Group E is kept for T8. This MEASURES safety only; adopting a trim step into the
builder is a separate owner decision (plan Non-Goals).

Baseline capability capture on a throwaway copy (page capture, WebGL, EME vs the
spike-P4 `CDM_FAIL` baseline), then one fresh copy per group —
A: `clidmgr.exe`+`browser_proxy.exe`+`clids_*.xml`, B: `widgets\`,
C: `voiceactivation\`, D: `web_app_config\`, E: `Locales` keep only `en-US.pak` —
each trimmed, re-probed and compared to baseline (`SAFE`/`BROKEN` + bytes saved).
Group E is kept for T8. This MEASURES safety only; adopting a trim step into the
builder is a separate owner decision (plan Non-Goals).

## T4 — Corporate availability (issue §2)

**Verdict: `PUBLIC-ENDPOINT https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx (HTTP 200)`** —
the ADMX template is publicly fetchable; the MSI/exe candidates returned 404 and
the support landing page 404'd (as locally observed). A 404 alone is never
stated as proof of login-gating.

Probes 3 corporate CDN candidates under `download.cdn.yandex.net/browser/corporate/`
plus the public landing page `https://yandex.com/support/browser/business/en/`
(HEAD, GET fallback, installer-like hrefs grepped from the landing page).
A 404 alone is **never** stated as proof of login-gating; the verdict only records
what was observed, alongside prior research (Corporate MSI is login-gated).

## T5 — Preseed key existence after first run (issue §6)

**Verdict: `6 EXIST (0 materialized, 4 preseeded, 0 lost, 2 absent)`** —
`show_ya_button`, `app_side_promo_service_enabled`, `alissenger`,
`default_apps_installed` PRESEEDED (written by our preseed, survived first run);
`neuro_question`, `video_button_enabled` ABSENT (never seen before or after the
launch); nothing MATERIALIZED on its own, nothing LOST.

Fresh builder layout → headed launch so the first-run NTP opens naturally →
graceful close → diff `Data\Default\Preferences` + `Data\Local State` before vs
after for the exact issue-named keys: `neuro_question`, `video_button_enabled`,
`show_ya_button`, `app_side_promo_service_enabled`, `alissenger`,
`default_apps_installed` (status `ABSENT`/`PRESEEDED`/`MATERIALIZED`/`LOST`).

## T6 — Atomic write acceptance (issue §6/#7 support)

**Verdict: PASS** — probe key written via `.tmp` + `File.Replace` was read back
after relaunch, JSON valid, and no Preferences-derived leftovers remained.

Corruption leftovers are scoped to names derived from `Preferences` itself
(`Preferences.tmp`/`.bak`/`-journal`): the browser's own SQLite sidecars
(`History-journal`, `Web Data-journal`, …) in the same folder are normal and are
not treated as corruption (run 1/2 learned this the hard way — T6's first green
run flagged every sqlite journal as a false FAIL).

## T7 — Cache prune safety (issue §7)

**Verdict: PASS** — relaunch ok, `ShaderCache`, `GrShaderCache`,
`Default\Cache`, `Default\Code Cache`, `Crashpad` recreated; no missing
launch-critical dirs; event-driven dirs reported only.

Warm-up launch → delete `GPUCache`, `ShaderCache`, `GrShaderCache`, `DawnCache`,
`Default\Cache`, `Default\Code Cache`, `Default\Service Worker\CacheStorage`,
`Crashpad`, `BrowserMetrics-*` → relaunch + dump. Rule: PASS needs relaunch OK,
≥1 dir recreated and no missing launch-critical dir (`GPUCache`, `Default\Cache`);
event-driven dirs (`Crashpad`, `BrowserMetrics-*`) are reported but never fail the
probe by themselves.

## T8 — Locale trim render check (issue §1)

**Verdict: PASS** — `rendered with lang=ru (negotiation is profile/OS-level;
en-US-only pak trim keeps the render); domBytes=722` on the reused T3-E tree
(`Locales=[en-US.pak]`).

The probe judges the RENDER (body marker + readable `navigator.language` + the
en-US-only precondition), not the language tag: run 1 showed `lang=ru` with a
fully rendered page and no `accept_languages` preseed — the negotiated language
comes from profile/OS, unaffected by pak trimming.

---

## Evidence / run links

Source run for every row: [claims run 36664258871](https://github.com/hcdbp24c3/yandex-browser-portable/actions/runs/36664258871)
(`completed success`, workflow `.github/workflows/claims.yml`, input `test=all`).

| Probe | Run | Log evidence |
|---|---|---|
| T1 | 36664258871 | `T1 verdict: IGNORED - ... (via=uia bytes=10269)` |
| T2 | 36664258871 | `T2 verdict: 5 of 9 claimed names fabricated; 461 policies; all class=Both` |
| T3 | 36664258871 | `T3 verdict: BROKEN - group B; ...` + 4 `SAFE` group lines + summary |
| T4 | 36664258871 | `T4 verdict: PUBLIC-ENDPOINT .../YandexBrowser.admx (HTTP 200)` |
| T5 | 36664258871 | `T5 verdict: neuro_question=ABSENT, ... 6 EXIST (0 materialized, 4 preseeded, 0 lost, 2 absent)` |
| T6 | 36664258871 | `T6 verdict: PASS - atomic .tmp+File.Replace accepted: ...` |
| T7 | 36664258871 | `T7 verdict: PASS - rule: relaunch ok + ...` |
| T8 | 36664258871 | `T8 verdict: PASS - rendered with lang=ru ...; domBytes=722 ...` |

Probe-development runs (probe defects found and fixed test-first, same workflow):
36661822112 (T6 `File.Replace($null)` binding crash, T8 `lang=ru` misjudged as
FAIL), 36663223628 (T6 sqlite-journal false positive).

## Corrections to issue #1 (probe-backed)

PENDING (Task 3 aggregates after T1–T9).

## Owner decisions

PENDING (Task 3 asks and records; adoptions are implemented in a follow-up feature).
