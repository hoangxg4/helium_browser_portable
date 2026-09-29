# Spike findings — Yandex Browser portable (headless run 10, `36376731954`; headed P3 re-runs H1–H5)

Workflow: `.github/workflows/spike.yml` (repo `hcdbp24c3/yandex-browser-portable`, branch `main`, commit `3117994`).
Verdict lines scraped from run log (4 of 4):

```
P1 verdict: PASS - branch=A (7z payload extract); version=26.8.4.893; WidevineCdm=ABSENT; tree=26.8.4.893/, browser_proxy.exe, browser.exe, clidmgr.exe, clids_yandex_second.xml, clids_yandex.xml
P2 verdict: PASS - version.dll loads into browser.exe; portable Data=True Cache=True at %app%\..; dump bytes withDLL=0 vs withoutDLL=0
P3 verdict: IGNORED - YandexAliceMsgDisable absent from browser://policy after reg add (dump bytes=0)
P4 verdict: FAIL - eme=CDM_FAIL:NotSupportedError:Unsupported keySystem or supportedConfigurations. (domBytes=683)
```

---

## P1 — Extract

- **Verdict: PASS.**
- **Branch: A** (winget payload = 7z archive). `7z list exit=0 isArchive=True`; nested `browser.7z` extract `exit=0`; app root `D:\a\_temp\spike\extractA\x_browser\Browser-bin`.
- **Version**: winget manifests 121 entries, latest `PackageVersion=26.8.4.893`, `InstallerUrl=https://download.cdn.yandex.net/browser/int/26_8_4_893_117525/en/Yandex.exe`. `version.txt` candidate = `26.8.4.893` (winget PackageVersion); source dir name = `Browser-bin`.
- **Tree (top level)**: `26.8.4.893/`, `browser_proxy.exe`, `browser.exe`, `clidmgr.exe`, `clids_yandex_second.xml`, `clids_yandex.xml`.
- **Flags**: `browser.exe=True version.dll=False service_update.exe=False yupdate-exec.exe=False Installer=False WidevineCdm(appdir)=False nestedCdm=`.
- **WidevineCdm location: ABSENT** — not in payload tree, not in `26.8.4.893/` (local verification of the same payload: `browser.dll` 299,536,328 B, `browser.exe` 6,241,736 B; no `WidevineCdm/` directory anywhere). CDM is only registered at runtime by the component updater (see P4).
- Binary strings (local `browser.dll`): `chrome://policy/` registered; **no `browser://policy` string** (also `Migrating chrome://policy to mojo!`).

## P2 — Chrome++ compat

- **Verdict: PASS** (version.dll path viable; no FALLBACK needed).
- **Asset URL used**: `https://github.com/bibicadotnet/Chromium_SetDLL/releases/download/1.18.2/Chrome.2B.2B_v1.18.2_x86_x64_arm64.7z` (release `1.18.2`, resolved via pinned `releases/latest`).
- **version.dll behavior**: `D:\a\_temp\spike\cpp\x64\App\version.dll` side-by-side; `P2 with-dll exit=0 outBytes=0 stderr=[]`; `P2 no-dll exit=killed@60s outBytes=0`. Portable launch: `alive=False exit=0 Data=True Cache=True parent=D:\a\_temp\spike\pkg` — `Data\`/`Cache\` created at `%app%\..`.
- **ini verdict (P2b)**: `chrome++.ini` copied next to `browser.exe` (WITHOUT `--disable-component-update`), `no-disable-component-update=True`; relaunch → `%app%\..\Data exists=True (resolved path=D:\a\_temp\spike\pkg\Data)`.
- Note: `dump bytes withDLL=0 vs withoutDLL=0` — `--dump-dom` produces 0 bytes on this build regardless of the DLL (see P0 note below); the DLL verdict rests on process exit + portable dirs, not dump output.

## P3 — Policy honoring (gate)

- **Verdict: IGNORED** (emitted): `YandexAliceMsgDisable absent from browser://policy after reg add (dump bytes=0)`.
  > **Superseded** by the headed H5 result (see the H1–H5 section below): gate = **GO** (headless IGNORED was a measurement artifact).
- Procedure order preserved: baseline **before** reg add → `P3a baseline dom bytes=0; present=False (expected False)` → `reg add HKLM\SOFTWARE\Policies\YandexBrowser YandexAliceMsgDisable=1 (REG_DWORD)` (`policy key existed before the test: False`) → dump → `key not present in the browser://policy dump` → cleanup `test value removed=True; whole key removed=True`.
- **Enum evidence**: `YandexAutoLaunchMode absent from the dump (browser://policy only lists registered keys)`; `ADMX has no YandexAutoLaunchMode entry`. Also runtime stderr: `[CORP] YandexAntiTracking. Status: This policy is disabled.` / `Cloud management controller initialization aborted as CBCM is not enabled.` — policy infrastructure initializes but is inert headless.
- **Why IGNORED, not HONORED — measurement is unverifiable in headless CI.** Across all channels, the policy page never renders:
  1. `--dump-dom` on `browser://policy/`: `P3a/P3b dump exceeded 45s and was killed`, 0 bytes.
  2. CDP `Page.navigate` from a live `about:blank` renderer (run 10 final attempt): navigation issued for all 3 URL forms, **never committed** —
     - `error: navigation to browser://policy/ did not commit (location.href=about:blank)`
     - `error: navigation to browser://policy did not commit (location.href=about:blank)`
     - `error: navigation to chrome://policy/ did not commit (location.href=)`
     - `P3a cdp extraction produced no dom` / `P3b policy dump bytes=0; exit=killed@45s; matching lines=0`.
  3. Run 9 (DriveNav to a policy-launched tab): attached to dead renderer — `Runtime.enable attempt 1/2: ws receive timeout (15s)` → `Runtime.enable failed after 2 attempts` → `exit=1`.
  4. Run 7 (Find-Target URL match): page URLs empty (`urls=[]`) — the policy tab never exposes a URL.
- **Implication**: the emitted `IGNORED` reflects an empty dump, not a confirmed policy rejection; but per spec decision rules `P3 = IGNORED` ⇒ **NO-GO** (policy path unverifiable headless → design re-plan required before Tasks 3–7). The registry write itself succeeded and was cleaned up; ADMX absence confirms `YandexAutoLaunchMode` has no documented ADMX entry either way.

## P4 — EME

- **Verdict: FAIL** — `eme=CDM_FAIL:NotSupportedError:Unsupported keySystem or supportedConfigurations. (domBytes=683)`.
- Probe ran with `file:///D:/a/yandex-browser-portable/yandex-browser-portable/probe/eme-probe.html`; `P4 no WidevineCdm shipped next to browser.exe (CDM_SRC unset)`; dump `exceeded 60s and was killed`, parsed via CDP (683-byte DOM).
- **CDM stderr lines** (component updater registers CDM at runtime, but requestConfig fails in this headless session):
  - `[component_installer.cc:580] StartRegistration for Widevine Content Decryption Module`
  - `[component_installer.cc:658] FinishRegistration for Widevine Content Decryption Module`
- Per decision rules, P4 = FAIL → proceed; Task 7 EME assertion degrades to WARN (Widevine not shipped in payload; runtime registration observed but `requestMediaKeySystemAccess` returned `NotSupportedError` in headless CI).

## P0 context (measurement caveat)

`--dump-dom` is broken on this build in headless CI regardless of URL or flags: `P0 chosen DUMP_BASE=--headless=new --disable-gpu --no-first-run --no-default-browser-check --disable-crash-reporter --enable-logging=stderr --v=1 (heliumBytes=0 plainBytes=0)`, yet `P0 CDP path AVAILABLE (P0_CDP=ok)` — all DOM evidence above comes from the CDP fallback, which works for `about:blank`/`file://` but cannot commit navigation to `chrome://`/`browser://` internal pages.

## Attempt history (spec cap 3 → 10; each run fixed one evidenced defect)

| Run | ID | Outcome / defect fixed |
|---|---|---|
| 1 | 36363766780 | P0 crash (`$null` string replace); dump-dom 0 B |
| 2 | 36365625965 | P0 fixed; CDP proven (`about:blank` dom); P0_CDP threshold kept |
| 3 | 36367022300 | Threshold fixed; P3 dump still 0 B |
| 4 | 36367915346 | CANCELLED — unbounded ADMX fetch, 30-min cap |
| 5 | 36370602341 | Timeouts bounded; P4 measured 683 B |
| 6 | 36371584872 | P3a `$app` binding fix; empty-target attach |
| 7 | 36372506501 | 3-URL chain; all `exit=3 urls=[]` |
| 8 | 36373370012 | `$driveNav`/`$DriveNav` case-insensitive clobber — DriveNav never engaged |
| 9 | 36374948471 | DriveNav engaged; attached to **dead** policy tab (`Runtime.enable` timeout ×2) |
| 10 | 36376731954 | Live `about:blank` attach + `Page.navigate`; **navigation never commits** (definitive) |

---

---

## Headed P3 re-run (operator decision A) — runs H1–H5, `mode=p3h`

Headed re-run of the P3 gate on `windows-latest` (`--force-renderer-accessibility` added to the headed launch args). Procedure unchanged: baseline dump **before** `reg add` → `reg add HKLM\SOFTWARE\Policies\YandexBrowser YandexAliceMsgDisable=1 (REG_DWORD)` → policy dump → verdict → cleanup. `policy key existed before the test: False`; cleanup `test value removed=True; whole key removed=True`.

| Run | ID | Outcome / defect found |
|---|---|---|
| H1 | 36382487294 | First `mode=p3h`: IGNORED — page never rendered (`domBytes=0`, window title `about:blank`, policy-cache hits=0) |
| H2 | 36385320007 | `ERR_ABORTED` on `browser://policy`, devtools session lost across relaunch; baseline stage3 DID show window title `Policies — Yandex Browser`; `s3` relaunch timing races |
| H3 | 36388486304 | **Root cause found**: every CDP command on the `chrome://policy` target returns `{"code":-32000,"message":"Forbidden"}` (Chromium WebUI inspection guard; target-based, not session-based — `about:blank` attach evaluates `1+1`→`value=2` fine). Verdict `IGNORED-never-rendered` was misleading: the page renders, CDP just cannot read it |
| H4 | 36391370587 | 20-domain CDP scanner: **all 20 domains Forbidden**, except **`Page.printToPDF` → OK** (content channel; artifact saved). Windows UI Automation probe (`probe/uia-dump.ps1`) works: baseline extracted **2507 bytes** of the rendered page (key correctly absent pre-reg-add). Policy-phase UIA failed only because it ran AFTER the destructive stage-3 relaunch had replaced the window (empty title, frame text 297 B < 600 rejected) → verdict again misleading `IGNORED` |
| H5 | 36392580458 | **HONORED** — UIA re-run both phases before the stage-3 relaunch. Baseline: window `Policies — Yandex Browser`, 4497 B, `YandexAliceMsgDisable present=False (expected False)`, cache hits=0. Policy: 2650 B (`via=uia`), key **present**: `YandexAliceMsgDisable ... true Platform Machine Mandatory` (DWORD `1` rendered as `true`, source `Platform`, level `Mandatory`), cache hits=0. `Page.printToPDF` artifacts corroborate: baseline 72 592 B vs policy 85 756 B PDF. `devtools /json/version = Chrome/150.0.7871.893`. Verdict line count = 1 |

**Headed P3 verdict: HONORED — with `HKLM\SOFTWARE\Policies\YandexBrowser YandexAliceMsgDisable=1` set, headed Yandex Browser lists `YandexAliceMsgDisable` on `chrome://policy/` with source `Platform` and level `Mandatory`; baseline (pre-reg-add) correctly shows it absent.**

Extraction chain that produced the evidence (all in `.github/workflows/spike.yml` `Invoke-HeadedDump` + `probe/cdp-dump.ps1`):

1. CDP `Runtime.evaluate` outerHTML → `DOM.getOuterHTML` → `Page.captureSnapshot` (mhtml) → `Accessibility.getFullAXTree` — all Forbidden on WebUI targets.
2. `Page.printToPDF` (the one allowed domain) → base64-decoded PDF artifact saved for the report (size delta baseline vs policy corroborates the extra row).
3. Windows UI Automation walk (`probe/uia-dump.ps1`, run under `powershell.exe` 5.1 with `UIAutomationClient`): Name + ValuePattern text, accepted when ≥600 B, shown URL policy-gated (`Test-Usable`), marker `via=uia` recorded.

**Why the earlier headless runs could not see this**: headless CI never committed navigation to `chrome://`/`browser://` (run 10, see P3 above), and headed CDP is blocked by the WebUI inspection guard — only `printToPDF` and UIA survive. The headless `IGNORED` was a measurement artifact, not a policy rejection.

GO-NO-GO: GO — headed P3 HONORED, P1 PASS, P2 PASS, P4 degraded per plan
