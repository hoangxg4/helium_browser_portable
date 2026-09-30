# yandex-launcher (T9 MVP)

Single-instance launcher for the portable Yandex Browser package — issue #1
§4/§7/§8, plan §2. No GUI framework, no third-party dependency besides
`golang.org/x/sys` (Windows registry/pipe/mutex primitives).

## Build and test

```sh
cd launcher
go vet ./...
go test ./...
go build -o yandex-launcher.exe .
```

CI runs the same three commands on `windows-latest` (`T9 Go checks` step in
`.github/workflows/claims.yml`) and hands the exe to `probe/claims/t9-launcher.ps1`.

## CLI

| Flag | Meaning |
|------|---------|
| `--selftest` | run the T9 selftest: never spawn `browser.exe`, print `T9 verdict: FAIL — <reason>` and exit non-zero on any fatal error |
| `--dry-run` | do everything except spawning `browser.exe` (mutex, policy, prune, plan all still run) |
| `--settings` | print the resolved configuration (language, hkcu-mode, paths) and exit 0 |
| `--lang en\|ru` | output language; default is the OS UI culture, then the POSIX locale |
| `--app-dir` | package root or `Yandex\` dir (default: next to the launcher exe) |
| `--findings` | findings doc carrying the T1 verdict (default `docs/issue1-claims-findings.md`) |
| `--debloater` | `debloater.reg` with the shipped policy values (default: beside `browser.exe`) |
| `--prune-days` | age in days after which `Data\` is pruned (default 7) |
| `--hold-ms` | `--selftest` only: keep the forward channel open this long |
| *(positional URL)* | forwarded to the running instance by a second invocation |

## What one run does

1. **Single instance** — takes the named mutex
   `Global\YandexPortable_SingleInstance`. A second invocation never opens a
   second browser: it hands its argv URL to the primary over the forward
   channel, or logs `forward: no forwarding target (no window handle)` and
   exits 0. If the mutex cannot be created, `--selftest` fails with
   `T9 verdict: FAIL — mutex create error: <err>` — there is deliberately **no
   `Local\` fallback**, because a fallback would fake the claim under test.
2. **Mode** — parses the single `T1 verdict:` line from the findings doc.
   `HONORED` → HKCU mode; anything else (`IGNORED`, `FAIL`, missing file) →
   policy skipped and the exact reason is logged as
   `mode: skip - T1 verdict: ...`.
3. **Ephemeral policy** (HKCU mode only) — applies the 11 dword values parsed
   from `debloater.reg` to `HKCU\Software\Policies\YandexBrowser`, reads them
   back, and on exit removes exactly what it created (pre-existing user values
   are recorded first and restored). A deferred sweep runs even on the fatal
   paths, so no value this run created outlives it. The 3-don't-touch keys are
   never written.
4. **Prune** — when `state.json` at the package root is at least
   `--prune-days` old (or missing) and no `browser.exe` is running, deletes the
   T7 volatile dirs under `Data\` (`GPUCache`, `ShaderCache`, `GrShaderCache`,
   `DawnCache`, `Default/Cache`, `Default/Code Cache`,
   `Default/Service Worker/CacheStorage`, `Crashpad`, plus `BrowserMetrics*`)
   and stamps `state.json`. A fresh `state.json` is the fast skip path.
5. **Launch plan** — prefers `version.dll` next to `browser.exe` (portable
   `Data`/`Cache` redirection); when the DLL is missing it falls back to
   `--user-data-dir <root>\Data --disk-cache-dir <root>\Cache`. The browser's
   exit code is propagated.

## Package layout

Accepts either the package root or the `Yandex\` dir:

```
<pkg>/Yandex/browser.exe        (required)
<pkg>/Yandex/version.dll        (preferred)
<pkg>/Yandex/debloater.reg      (policy single source of truth)
<pkg>/Data/  <pkg>/Cache/       (prune target)
<pkg>/state.json                (prune stamp)
```

## Out of scope

The launcher is **not** added to the `build.yml` zip — packaging is Task 3's
owner decision.
