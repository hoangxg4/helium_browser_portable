# Unified Per-Version Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One GitHub release per Helium+Chrome++ version combo containing both arch zips (x64 + arm64), replacing the two-per-arch-release scheme, including full history migration.

**Architecture:** Matrix build jobs stop publishing; they upload zips as workflow artifacts. A single new `release` job (gated `needs: [check, build]`) publishes both zips to one unified tag `helium-portable_{heliumVer}_{plusVer}` with all-or-nothing semantics. A three-phase migration script consolidates the 73 existing per-arch releases into 54 unified releases; the destructive delete phase is operator-gated.

**Tech Stack:** GitHub Actions (softprops/action-gh-release@v2, upload/download-artifact@v4), bash/jq/gh CLI, Python (pyyaml harness, zipfile probe).

**Spec:** `docs/superpowers/specs/2026-09-26-unified-arch-release-design.md`

## Global Constraints

- Repo: `/root/repos/helium_browser_portable`, branch `master`, direct commits explicitly consented by the operator.
- Release tag scheme: `helium-portable_{heliumVer}_{plusVer}` — **never** an arch segment. Zip/asset names **keep** the arch segment (`helium-portable-x64_{heliumVer}_{plusVer}.zip`).
- All-or-nothing publishing: if either arch build fails, nothing is published (release job must be gated on both `check` and `build`).
- issue #7 regression guards must stay byte-intact: `-like "*\${arch}\App\*"` selection + `Write-Error`/`exit 1`, `validate.yml` `\\\\App\\\\` rejection, `Test-Path` pre-package assertions, `Compress-Archive Helium_Portable "$tag.zip" -Force`.
- Files that MUST NOT change: `update.bat`, `debloater.reg`, `bypass_windows_defender.bat`, `default-apps-multi-profile.bat`, `chrome++.ini`, `README.md` (contains no release URLs).
- Build steps in main.yml from download through `Compress-Archive` stay byte-identical; only the workflow plumbing changes.
- Migration never rebuilds historical zips — old release assets move byte-for-byte.
- The delete phase (phase 3) must not run without explicit operator approval recorded after phase 2 verification output.
- Local harness pattern + expectations: see reference evidence in `.superpowers/sdd/2026-09-25-portable-layout-restructure/task-6-report.md` (Step 1 harness, Step 4 probe).

### File structure

| File | Responsibility | Tasks |
|---|---|---|
| `.github/workflows/main.yml` (Modify) | unified existence check, artifact upload, single release job | 1 |
| `.github/workflows/validate.yml` (Modify) | pin the unified release scheme | 2 |
| `scripts/migrate-unified-releases.sh` (Create) | three-phase history migration (create/verify/delete) | 4 |
| (no repo files) e2e evidence | push + CI + probe + gated delete evidence under `.superpowers/sdd/2026-09-26-unified-arch-release/` | 3, 5 |

---

### Task 1: main.yml — unified check, artifact upload, single release job

**Files:**
- Modify: `.github/workflows/main.yml:10-18` (check outputs), `:44-71` (existence logic), `:73-94` (build job head + remove skip step), `:176-178` (env echoes), `:180-189` (Release step → upload), append new `release` job after the build job.

**Interfaces:**
- Consumes: existing build step content (unchanged), upstream outputs `helium_ver`/`plus_ver`/`plus_url`/`helium_url_*` (unchanged names).
- Produces: check output `exists` (replaces `exists_x64`/`exists_arm64`); artifacts named `zip-x64`/`zip-arm64` each containing one `helium-portable-{arch}_{h}_{p}.zip`; release job publishing to `helium-portable_{h}_{p}` — Task 2's validate pins grep for exactly these strings (`TAG="helium-portable_${HELIUM_VER}_${PLUS_VER}"`, `tag_name: helium-portable_${{`, `upload-artifact@v4`, `needs: [check, build]`, exactly one `action-gh-release`).

- [ ] **Step 1: Replace the check job outputs block (lines 10-18)**

```yaml
    outputs:
      helium_ver: ${{ steps.check.outputs.helium_ver }}
      plus_ver: ${{ steps.check.outputs.plus_ver }}
      plus_url: ${{ steps.check.outputs.plus_url }}
      helium_url_x64: ${{ steps.check.outputs.helium_url_x64 }}
      helium_url_arm64: ${{ steps.check.outputs.helium_url_arm64 }}
      exists: ${{ steps.check.outputs.exists }}
```

- [ ] **Step 2: Replace the existence-check section (current lines 44-71, from `# Check existing releases` through the `exists_arm64=` output line) with unified logic**

```bash
        # Check existing unified release: tag exists AND both zip assets present.
        # A tag with a missing arch zip counts as NOT released (self-repair:
        # rebuild + softprops overwrite adds the missing zip to the same tag).
        TAG="helium-portable_${HELIUM_VER}_${PLUS_VER}"

        if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
          EXISTS="false"
          echo "Manual dispatch — forcing rebuild"
        else
          REL=$(curl -sSL \
            -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}" \
            "https://api.github.com/repos/${{ github.repository }}/releases/tags/$TAG")
          ASSET_COUNT=$(echo "$REL" | jq '[.assets[]? | select(.name | test("helium-portable-(x64|arm64)_.*\\.zip$"))] | length' 2>/dev/null || echo 0)
          case "$ASSET_COUNT" in
            ''|*[!0-9]*) ASSET_COUNT=0 ;;
          esac
          if echo "$REL" | jq -e '.tag_name' >/dev/null 2>&1 && [ "$ASSET_COUNT" -ge 2 ]; then
            EXISTS="true"
          else
            EXISTS="false"
          fi
        fi

        echo "Unified tag: $TAG"
        echo "exists: $EXISTS"

        # Outputs
        echo "helium_ver=$HELIUM_VER" >> $GITHUB_OUTPUT
        echo "plus_ver=$PLUS_VER" >> $GITHUB_OUTPUT
        echo "plus_url=$PLUS_URL" >> $GITHUB_OUTPUT
        echo "helium_url_x64=$HELIUM_URL_X64" >> $GITHUB_OUTPUT
        echo "helium_url_arm64=$HELIUM_URL_ARM64" >> $GITHUB_OUTPUT
        echo "exists=$EXISTS" >> $GITHUB_OUTPUT
```

- [ ] **Step 3: Simplify the build job head (lines 73-94): new `if:`, delete the whole `Skip if already released` step, make checkout unconditional**

```yaml
  build:
    needs: check
    if: needs.check.outputs.exists == 'false'
    runs-on: windows-latest
    strategy:
      matrix:
        arch: [x64, arm64]
    steps:
    - uses: actions/checkout@v4

    - name: Build (${{ matrix.arch }})
      run: |
```

(Keep the `Build` step's `run:` body byte-identical from `$arch = ...` down to `Compress-Archive Helium_Portable "$tag.zip" -Force`.)

- [ ] **Step 4: Trim the build step's trailing env echoes (lines 176-178) to ZIP only**

```powershell
        echo "ZIP=$tag.zip" >> $env:GITHUB_ENV
```

(`TAG` and `ARCH` env vars are no longer consumed anywhere; `env.ZIP` is consumed by the upload step below.)

- [ ] **Step 5: Replace the matrix Release step (lines 180-189) with artifact upload**

```yaml
    - name: Upload build artifact
      uses: actions/upload-artifact@v4
      with:
        name: zip-${{ matrix.arch }}
        path: ${{ env.ZIP }}
        if-no-files-found: error
```

- [ ] **Step 6: Append the new release job after the build job (end of file)**

```yaml
  release:
    needs: [check, build]
    runs-on: ubuntu-latest
    steps:
    - uses: actions/download-artifact@v4
      with:
        pattern: zip-*
        merge-multiple: true

    - uses: softprops/action-gh-release@v2
      with:
        files: helium-portable-*.zip
        tag_name: helium-portable_${{ needs.check.outputs.helium_ver }}_${{ needs.check.outputs.plus_ver }}
        name: Helium ${{ needs.check.outputs.helium_ver }} + Chrome++ ${{ needs.check.outputs.plus_ver }}
        overwrite: true
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 7: Verify**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/main.yml')); yaml.safe_load(open('.github/workflows/validate.yml')); print('YAML OK')"
grep -c 'action-gh-release' .github/workflows/main.yml        # expect 1
grep -qF 'needs: [check, build]' .github/workflows/main.yml && echo "gating OK"
grep -qF 'tag_name: helium-portable_${{' .github/workflows/main.yml && echo "unified tag OK"
grep -qF 'TAG="helium-portable_${HELIUM_VER}_${PLUS_VER}"' .github/workflows/main.yml && echo "check-side tag OK"
grep -qF 'upload-artifact@v4' .github/workflows/main.yml && echo "artifact OK"
grep -qF '\\\\App\\\\' .github/workflows/validate.yml && echo "issue#7 guard OK"
git diff --stat   # only main.yml changed
```
Expected: `YAML OK`; count `1`; all echoes print; diff shows only `.github/workflows/main.yml`.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/main.yml
git commit -m "feat(release): unify per-version releases (artifact bridge + single publish job)"
```

---

### Task 2: validate.yml — pin the unified release scheme

**Files:**
- Modify: `.github/workflows/validate.yml:117-143` (`Validate build workflow` step — append pins after the `hibbiki layout assembly: OK` line; do not touch existing pins).

**Interfaces:**
- Consumes: Task 1's main.yml strings (exact literals listed in Task 1's Interfaces).
- Produces: a `Validate build workflow` step that fails CI if the scheme regresses (Task 3 gates on this passing locally and in CI).

- [ ] **Step 1: Append the unified-scheme pins inside the `Validate build workflow` step**

```bash
        # Unified release scheme: one tag per version, single publish point
        # (spec: docs/superpowers/specs/2026-09-26-unified-arch-release-design.md §3.5)
        grep -qF 'TAG="helium-portable_${HELIUM_VER}_${PLUS_VER}"' .github/workflows/main.yml || { echo "  ERROR: check job does not build the unified release tag"; exit 1; }
        grep -qF 'tag_name: helium-portable_${{' .github/workflows/main.yml || { echo "  ERROR: release job tag_name is not the unified scheme"; exit 1; }
        grep -qF 'upload-artifact@v4' .github/workflows/main.yml || { echo "  ERROR: matrix builds must upload artifacts (no direct publish)"; exit 1; }
        grep -qF 'needs: [check, build]' .github/workflows/main.yml || { echo "  ERROR: release job must gate on both check and build"; exit 1; }
        SOFTPROPS_COUNT=$(grep -c 'action-gh-release' .github/workflows/main.yml || true)
        [ "$SOFTPROPS_COUNT" -eq 1 ] || { echo "  ERROR: expected exactly 1 action-gh-release publish point, found $SOFTPROPS_COUNT"; exit 1; }
        echo "  Unified release scheme: OK"
```

- [ ] **Step 2: Run the full local harness (replicates CI)**

```bash
python3 - <<'EOF'
import yaml, subprocess, sys
wf = yaml.safe_load(open('.github/workflows/validate.yml'))
rc_all = 0
for s in wf['jobs']['validate']['steps']:
    if 'run' not in s:
        continue
    name = s.get('name', '?')
    r = subprocess.run(['bash', '-e', '-c', s['run']],
                       capture_output=True, text=True)
    print(f"--- step '{name}': {'OK' if r.returncode == 0 else 'FAIL'}")
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        rc_all = 1
        break
print("ALL VALIDATE STEPS PASSED" if rc_all == 0 else "VALIDATE FAILED")
sys.exit(rc_all)
EOF
```
Expected: every step `OK`, `Validate build workflow` output ends with `  Unified release scheme: OK`, final line `ALL VALIDATE STEPS PASSED`. (Requires `jq` — present; `pyyaml` — present.)

- [ ] **Step 3: Verify YAML + scope**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml')); print('YAML OK')"
git diff --stat   # only validate.yml changed
```
Expected: `YAML OK`; diff = `.github/workflows/validate.yml` only.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "validate(ci): pin unified release scheme (single tag, single publish point)"
```

---

### Task 3: End-to-end — push, CI, unified release creation, overwrite re-dispatch, probes

**Files:**
- Create: none in git (evidence report under `.superpowers/sdd/2026-09-26-unified-arch-release/task-3-report.md`).
- Test: real Validate + Build workflows, then zip probes of the published unified release.

**Interfaces:**
- Consumes: Tasks 1-2 committed (HEAD = Task 2 commit). Before this task: exactly **73** releases, latest = `helium-portable-arm64_0.18.1.1_1.18.2`.
- Produces: unified release `helium-portable_0.18.1.1_1.18.2` with both fresh zips, Latest marker on it, total release count **74**; probe evidence for both assets.

**Hard rule:** verification only. If any gate fails → stop, capture full output, report BLOCKED. No fixes, no workarounds (fixes route back through the controller's review loop). Release/tag count invariants must hold: no new per-arch release may appear at any point.

- [ ] **Step 1: Push and watch Validate**

```bash
git push origin master
for i in $(seq 1 12); do
  RUN_ID=$(gh run list --workflow=validate.yml --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
  sleep 5
done
echo "validate run: $RUN_ID"
gh run watch "$RUN_ID" --exit-status
```
Expected: conclusion `success` (proves Task 2's pins pass in real CI).

- [ ] **Step 2: Record pre-state**

```bash
gh api "repos/hoangxg4/helium_browser_portable/releases?per_page=100" \
  > /tmp/opencode/e2e-pre.json
echo "total: $(jq length /tmp/opencode/e2e-pre.json)"                       # expect 73
echo "latest: $(jq -r 'map(select(.prerelease==false and .draft==false)) | .[0].tag_name' /tmp/opencode/e2e-pre.json)"
gh api "repos/hoangxg4/helium_browser_portable/releases/latest" --jq .tag_name   # expect helium-portable-arm64_0.18.1.1_1.18.2
```

- [ ] **Step 3: Dispatch the build (first run → creates the unified release) and watch**

```bash
gh workflow run main.yml
sleep 10
BUILD_ID=$(gh run list --workflow=main.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "build run: $BUILD_ID"
gh run watch "$BUILD_ID" --exit-status
```
Expected: conclusion `success` (check + build(x64) + build(arm64) + release all green).

- [ ] **Step 4: Assert the unified release contract**

```bash
REL=$(gh api "repos/hoangxg4/helium_browser_portable/releases/tags/helium-portable_0.18.1.1_1.18.2")
echo "$REL" | jq -e '.assets | length == 2' || echo "FAIL: not exactly 2 assets"
echo "$REL" | jq -e '[.assets[].name] | sort == ["helium-portable-arm64_0.18.1.1_1.18.2.zip","helium-portable-x64_0.18.1.1_1.18.2.zip"]' || echo "FAIL: asset names"
echo "$REL" | jq -r '.name'          # expect: Helium 0.18.1.1 + Chrome++ 1.18.2  (no arch suffix)
echo "$REL" | jq -r '.assets[] | .name + " " + (.size|tostring) + " updated=" + .updated_at'
gh api "repos/hoangxg4/helium_browser_portable/releases/latest" --jq .tag_name
   # expect: helium-portable_0.18.1.1_1.18.2
gh api "repos/hoangxg4/helium_browser_portable/releases?per_page=100" | jq length
   # expect: 74 (73 old + 1 unified) — anything else means a per-arch release was touched
```
Save both assets' `updated_at` values — Step 7 compares them.

- [ ] **Step 5: Probe both zips (download + central directory + ini content)**

```bash
mkdir -p /tmp/opencode/e2e-probe
rm -f /tmp/opencode/e2e-probe/*.zip
gh release download helium-portable_0.18.1.1_1.18.2 \
  -R hoangxg4/helium_browser_portable -D /tmp/opencode/e2e-probe -p '*.zip'
ls -la /tmp/opencode/e2e-probe
python3 - <<'EOF'
import sys, zipfile, re, os
D = "/tmp/opencode/e2e-probe"
fail = 0
for fname in sorted(os.listdir(D)):
    if not fname.endswith(".zip"):
        continue
    path = os.path.join(D, fname)
    z = zipfile.ZipFile(path)
    names = z.namelist()
    errs = []
    if len(names) != 91:
        errs.append(f"entry count {len(names)} != 91")
    H = "Helium_Portable/"
    must = [H + "Helium/" + f for f in [
        "chrome.exe", "version.dll", "chrome++.ini", "update.bat",
        "default-apps-multi-profile.bat", "bypass_windows_defender.bat",
        "debloater.reg", "version.txt"]]
    for m in must:
        if m not in names:
            errs.append(f"missing {m}")
    if not re.match(r"^Helium_Portable/Helium/[^/]+/WidevineCdm/manifest\.json$",
                    next((n for n in names if n.endswith("WidevineCdm/manifest.json")), "")):
        errs.append("versioned WidevineCdm/manifest.json missing")
    if any(n.startswith(H + "Helium/WidevineCdm") for n in names):
        errs.append("stray flat Helium/WidevineCdm")
    top = {n[len(H):].split("/")[0] for n in names if n.startswith(H) and n[len(H):]}
    if top != {"Helium"}:
        errs.append(f"zip root children {top} != {{'Helium'}} (Data/Cache must not ship)")
    ini = z.read(H + "Helium/chrome++.ini").decode("utf-8", "replace")
    if r"data_dir=%app%\Data" in ini:
        errs.append("flat data_dir present")
    if "data_dir=%app%\\..\\Data" not in ini and "data_dir=%app%\..\Data" not in ini:
        errs.append("portable-root data_dir missing")
    if "policy_key is a no-op" not in ini:
        errs.append("policy_key no-op comment missing")
    print(f"{fname}: {len(names)} entries ->", "ALL PASS" if not errs else f"FAIL: {'; '.join(errs)}")
    fail |= bool(errs)
print("PROBE: ALL PASS" if not fail else "PROBE: FAILURES")
sys.exit(fail)
EOF
```
Expected: both zips print `ALL PASS`; final line `PROBE: ALL PASS`.

- [ ] **Step 6: Second dispatch — prove rebuild-in-place overwrite**

```bash
gh workflow run main.yml
sleep 10
BUILD2_ID=$(gh run list --workflow=main.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$BUILD2_ID" --exit-status
gh api "repos/hoangxg4/helium_browser_portable/releases?per_page=100" | jq length
   # STILL expect 74 — overwrite must not create a duplicate release
gh api "repos/hoangxg4/helium_browser_portable/releases/tags/helium-portable_0.18.1.1_1.18.2" \
  --jq '.assets[] | .name + " updated=" + .updated_at'
   # expect both updated_at LATER than the Step 4 values
```

- [ ] **Step 7: Write the evidence report**

Write `.superpowers/sdd/2026-09-26-unified-arch-release/task-3-report.md`: validate run ID/conclusion, pre-state capture, first build run ID/conclusion, Step 4 assertion outputs (asset list, name, latest, count 74), probe output for both zips, second build run ID/conclusion + overwrite evidence (counts, updated_at before/after), `git log --oneline -4`.

Then reply with only: **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED, one-line per gate (push/validate/build1/contract/probe/build2), concerns, report path.

---

### Task 4: Migration script — create + verify phases (no deletion)

**Files:**
- Create: `scripts/migrate-unified-releases.sh` (executable).

**Interfaces:**
- Consumes: 73 existing per-arch releases via `gh` API; Task 3's already-complete unified `0.18.1.1` release (create phase must skip it).
- Produces: subcommands `create` / `verify` / `delete [--dry-run]`; manifest at `/tmp/opencode/unified-migration/manifest.tsv` (format `unified_tag<TAB>asset_name<TAB>size`) used by `verify` for size-equality checks; Task 5 consumes a green `verify` + the operator approval to run `delete`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Three-phase migration to one unified release per version combo.
#   scripts/migrate-unified-releases.sh create
#   scripts/migrate-unified-releases.sh verify
#   scripts/migrate-unified-releases.sh delete [--dry-run]
# delete is destructive (releases + git tags) and requires operator approval
# AFTER a green verify — the script itself re-runs verify before deleting.
set -euo pipefail

REPO="hoangxg4/helium_browser_portable"
WORK="${WORK:-/tmp/opencode/unified-migration}"
MANIFEST="$WORK/manifest.tsv"
mkdir -p "$WORK"

rels() { gh api --paginate "repos/$REPO/releases?per_page=100"; }

# combos.json: per-arch releases grouped by combo, oldest first.
# combo = tag minus the "helium-portable-{arch}_" prefix, e.g. "0.18.1.1_1.18.2"
build_combos() {
  rels > "$WORK/rels.json"
  jq '[ .[]
        | select(.tag_name | test("^helium-portable-(x64|arm64)_"))
        | { combo: (.tag_name | sub("^helium-portable-(x64|arm64)_"; "")),
            tag: .tag_name,
            created: .created_at,
            target: (.target_commitish // "master"),
            assets: [.assets[] | {name: .name, size: .size}] } ]
      | group_by(.combo)
      | map({ combo: .[0].combo,
              created: (map(.created) | min),
              target: (map(.target) | first),
              sources: map({tag, assets}) })
      | sort_by(.created)' "$WORK/rels.json" > "$WORK/combos.json"
}

download_sources() { # $1=combo, $2=dest dir
  local combo="$1" dir="$2" stag
  rm -rf "$dir"; mkdir -p "$dir"
  while read -r stag; do
    [ -z "$stag" ] && continue
    gh release download "$stag" --repo "$REPO" --dir "$dir" -p '*.zip'
  done < <(jq -r --arg c "$combo" '.[] | select(.combo==$c) | .sources[].tag' "$WORK/combos.json")
}

phase_create() {
  build_combos
  : > "$MANIFEST"
  local total i=0 combo created target utag helium plus dir f bn
  total=$(jq 'length' "$WORK/combos.json")
  while IFS=$'\t' read -r combo created target; do
    i=$((i+1))
    utag="helium-portable_${combo}"
    helium="${combo%%_*}"; plus="${combo#*_}"
    if gh release view "$utag" --repo "$REPO" >/dev/null 2>&1; then
      local have missing=0 an
      have=$(gh release view "$utag" --repo "$REPO" --json assets --jq '.assets[].name')
      while read -r an; do
        [ -z "$an" ] && continue
        grep -qxF "$an" <<<"$have" || missing=1
      done < <(jq -r --arg c "$combo" '[.[] | select(.combo==$c) | .sources[].assets[].name] | unique | .[]' "$WORK/combos.json")
      if [ "$missing" -eq 0 ]; then
        echo "[$i/$total] SKIP $utag (complete)"
        continue
      fi
      echo "[$i/$total] REPAIR $utag (missing assets)"
      download_sources "$combo" "$WORK/zips-$combo"
      for f in "$WORK/zips-$combo"/*.zip; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        if ! grep -qxF "$bn" <<<"$have"; then
          gh release upload "$utag" "$f" --repo "$REPO"
          echo -e "$utag\t$bn\t$(stat -c%s "$f")" >> "$MANIFEST"
        fi
      done
      rm -rf "$WORK/zips-$combo"
      continue
    fi
    download_sources "$combo" "$WORK/zips-$combo"
    local files=()
    for f in "$WORK/zips-$combo"/*.zip; do
      [ -e "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -ge 1 ] || { echo "ERROR: no source zips for $combo"; exit 1; }
    gh release create "$utag" "${files[@]}" \
      --repo "$REPO" \
      --title "Helium ${helium} + Chrome++ ${plus}" \
      --target "$target" \
      --notes ""
    for f in "${files[@]}"; do
      echo -e "$utag\t$(basename "$f")\t$(stat -c%s "$f")" >> "$MANIFEST"
    done
    rm -rf "$WORK/zips-$combo"
    echo "[$i/$total] CREATED $utag (${#files[@]} assets)"
  done < <(jq -r '.[] | [.combo, .created, .target] | @tsv' "$WORK/combos.json")

  local newest
  newest=$(jq -r 'last | .combo' "$WORK/combos.json")
  gh release edit "helium-portable_${newest}" --repo "$REPO" --latest
  echo "Latest -> helium-portable_${newest}"
}

phase_verify() {
  build_combos
  local fail=0 expected_combos expected_assets unified_count asset_total
  expected_combos=$(jq 'length' "$WORK/combos.json")
  expected_assets=$(jq '[.[] | .sources[].assets[]] | length' "$WORK/combos.json")
  unified_count=$(jq '[.[] | select(.tag_name | test("^helium-portable_"))] | length' "$WORK/rels.json")
  asset_total=$(jq '[.[] | select(.tag_name | test("^helium-portable_")) | .assets[]? | select(.name | test("helium-portable-(x64|arm64)_.*\\.zip$"))] | length' "$WORK/rels.json")

  [ "$unified_count" -eq "$expected_combos" ] || { echo "FAIL: $unified_count unified releases, expected $expected_combos"; fail=1; }
  [ "$asset_total" -eq "$expected_assets" ] || { echo "FAIL: $asset_total unified zip assets, expected $expected_assets"; fail=1; }
  jq -e '[.[] | select(.tag_name | test("^helium-portable_")) | select(.draft or .prerelease)] | length == 0' "$WORK/rels.json" >/dev/null || { echo "FAIL: draft/prerelease unified release found"; fail=1; }

  declare -A msizes=()
  if [ -f "$MANIFEST" ]; then
    while IFS=$'\t' read -r mt mname msize; do
      msizes["$mname"]="$msize"
    done < "$MANIFEST"
  fi

  local combo utag expected have an entry name size
  while read -r combo; do
    utag="helium-portable_${combo}"
    expected=$(jq -r --arg c "$combo" '[.[] | select(.combo==$c) | .sources[].assets[].name] | unique | .[]' "$WORK/combos.json")
    have=$(gh release view "$utag" --repo "$REPO" --json assets --jq '.assets[] | .name + "\t" + (.size|tostring)' 2>/dev/null || true)
    while read -r an; do
      [ -z "$an" ] && continue
      entry=$(grep -Fx "$an" <<<"$have" | head -1 || true)
      if [ -z "$entry" ]; then
        echo "FAIL: $utag missing asset $an"; fail=1; continue
      fi
      size=${entry##*$'\t'}
      if [ -n "${msizes[$an]:-}" ]; then
        [ "$size" -eq "${msizes[$an]}" ] || { echo "FAIL: $an size $size != source ${msizes[$an]}"; fail=1; }
      else
        [ "$size" -gt 0 ] || { echo "FAIL: $an has zero size"; fail=1; }
      fi
    done <<<"$expected"
  done < <(jq -r '.[].combo' "$WORK/combos.json")

  local newest latest
  newest=$(jq -r 'last | .combo' "$WORK/combos.json")
  latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
  [ "$latest" = "helium-portable_${newest}" ] || { echo "FAIL: Latest = $latest, expected helium-portable_${newest}"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    echo "VERIFY: ALL PASS ($expected_combos unified releases, $expected_assets assets, Latest OK)"
  else
    echo "VERIFY: FAILURES"
  fi
  return "$fail"
}

phase_delete() {
  local dry="${1:-}"
  phase_verify || { echo "ABORT: verify not green — nothing deleted"; exit 1; }
  build_combos
  local tags count expect t leaked left uni
  tags=$(jq -r '.[] | select(.tag_name | test("^helium-portable-(x64|arm64)_")) | .tag_name' "$WORK/rels.json")
  count=$(printf '%s\n' "$tags" | grep -c . || true)
  expect=$(jq '[.[] | .sources[].assets[]] | length' "$WORK/combos.json")
  [ "$count" -eq "$expect" ] || { echo "ABORT: $count per-arch releases but expected $expect"; exit 1; }
  if [ "$dry" = "--dry-run" ]; then
    printf '%s\n' "$tags" | sed 's/^/WOULD DELETE: /'
    echo "dry-run only: $count releases + tags listed, nothing deleted"
    return 0
  fi
  echo "Deleting $count verified per-arch releases + git tags..."
  while read -r t; do
    [ -z "$t" ] && continue
    gh release delete "$t" --repo "$REPO" --yes
    git push origin --delete "$t"
    echo "deleted $t"
  done <<<"$tags"
  left=$(rels | jq '[.[] | select(.tag_name | test("^helium-portable-(x64|arm64)_"))] | length')
  uni=$(rels | jq '[.[] | select(.tag_name | test("^helium-portable_"))] | length')
  leaked=$(git ls-remote --tags origin | grep -c 'helium-portable-\(x64\|arm64\)_' || true)
  [ "$left" -eq 0 ] || { echo "FAIL: $left per-arch releases remain"; exit 1; }
  [ "$leaked" -eq 0 ] || { echo "FAIL: $leaked old tags remain on remote"; exit 1; }
  [ "$uni" -gt 0 ] || { echo "FAIL: no unified releases found after delete"; exit 1; }
  echo "DELETE PHASE COMPLETE (per-arch=0, unified=$uni, leaked tags=0)"
}

case "${1:-}" in
  create) phase_create ;;
  verify) phase_verify ;;
  delete) phase_delete "${2:-}" ;;
  *) echo "usage: $0 create|verify|delete [--dry-run]" >&2; exit 2 ;;
esac
```

- [ ] **Step 2: Static checks**

Run:
```bash
chmod +x scripts/migrate-unified-releases.sh
bash -n scripts/migrate-unified-releases.sh && echo "bash -n OK"
shellcheck -S error scripts/migrate-unified-releases.sh && echo "shellcheck OK"
```
Expected: both OK (warnings below severity error are acceptable if justified in the report).

- [ ] **Step 3: Run create phase (real API — creates unified releases; idempotent, deletes nothing)**

```bash
scripts/migrate-unified-releases.sh create 2>&1 | tee /tmp/opencode/migration-create.log
```
Expected: lines `SKIP helium-portable_0.18.1.1_1.18.2 (complete)` (Task 3 already made it), `CREATED` for the other 53 combos, final `Latest -> helium-portable_0.18.1.1_1.18.2`. Zero deletions.

- [ ] **Step 4: Run verify phase**

```bash
scripts/migrate-unified-releases.sh verify 2>&1 | tee /tmp/opencode/migration-verify.log
```
Expected: final line `VERIFY: ALL PASS (54 unified releases, 73 assets, Latest OK)` and exit 0. If not → STOP, report BLOCKED with the log.

- [ ] **Step 5: Dry-run the delete phase (read-only listing)**

```bash
scripts/migrate-unified-releases.sh delete --dry-run 2>&1 | tee /tmp/opencode/migration-delete-dry.log
```
Expected: verify runs green first, then 73 `WOULD DELETE:` lines, final `dry-run only ... nothing deleted`. Confirm via `gh api .../releases?per_page=100 | jq length` → still 74.

- [ ] **Step 6: Commit the script**

```bash
git add scripts/migrate-unified-releases.sh
git commit -m "chore(migration): three-phase script for unified-release history migration"
```

- [ ] **Step 7: Write the evidence report**

Write `.superpowers/sdd/2026-09-26-unified-arch-release/task-4-report.md`: bash -n/shellcheck output, create log (count CREATED/SKIP), verify log (ALL PASS line), dry-run summary (73 listed, count still 74), manifest path + line count (expect 71 lines: 73 source assets minus 2 already-complete from Task 3).

Then reply with only: **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED, one-line per phase (static/create/verify/dry-run), concerns, report path. **Do not run the delete phase.**

---

### Task 5: Gated delete phase + post-deletion verification

**Files:**
- Create: none in git (evidence report `.superpowers/sdd/2026-09-26-unified-arch-release/task-5-report.md`).

**Interfaces:**
- Consumes: **Task 4 green** (`verify: ALL PASS`) **AND explicit operator approval** (the controller must have asked via a structured question and recorded the answer before dispatching this task — if that approval is not stated in this prompt, report BLOCKED and do nothing).
- Produces: final state = 54 releases (all unified), 0 per-arch releases, 0 old tags on remote, Latest = `helium-portable_0.18.1.1_1.18.2`.

**Hard rule:** destructive. Only the script's `delete` phase may delete anything; never delete releases/tags ad hoc. Any failure → stop, report BLOCKED with output (partial deletion state must be described exactly).

- [ ] **Step 1: Pre-flight re-check (before touching anything)**

```bash
scripts/migrate-unified-releases.sh verify
gh api "repos/hoangxg4/helium_browser_portable/releases?per_page=100" | jq length   # expect 74
```
Expected: `VERIFY: ALL PASS`, count 74. Any mismatch → BLOCKED.

- [ ] **Step 2: Run the gated delete**

```bash
scripts/migrate-unified-releases.sh delete 2>&1 | tee /tmp/opencode/migration-delete.log
```
Expected: `DELETE PHASE COMPLETE (per-arch=0, unified=54, leaked tags=0)` and exit 0.

- [ ] **Step 3: Independent post-deletion verification (not the script's own output)**

```bash
gh api "repos/hoangxg4/helium_browser_portable/releases?per_page=100" > /tmp/opencode/post.json
echo "total: $(jq length /tmp/opencode/post.json)"                                # 54
echo "per-arch: $(jq '[.[] | select(.tag_name|test("helium-portable-(x64|arm64)_"))] | length' /tmp/opencode/post.json)"   # 0
echo "assets: $(jq '[.[] | .assets[]? | select(.name|test("helium-portable-(x64|arm64)_"))] | length' /tmp/opencode/post.json)"  # 73
echo "latest: $(gh api repos/hoangxg4/helium_browser_portable/releases/latest --jq .tag_name)"   # helium-portable_0.18.1.1_1.18.2
OLD_TAGS=$(git ls-remote --tags origin | grep -c 'helium-portable-\(x64\|arm64\)_' || true)
echo "old tags on remote: $OLD_TAGS"   # expect 0
```
Expected: 54 / 0 / 73 / unified latest / 0 old tags. Also sanity-download one asset from an old combo (e.g. `helium-portable_0.15.1.1_1.18.1`) to prove migrated history is intact: `gh release download helium-portable_0.15.1.1_1.18.1 -p '*.zip' -D /tmp/opencode/hist-check` → file present, non-zero size.

- [ ] **Step 4: Write the evidence report**

Write `.superpowers/sdd/2026-09-26-unified-arch-release/task-5-report.md`: approval reference (who/when), delete log, independent post-verification outputs, history-download sanity check, `git log --oneline -6`.

Then reply with only: **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED, one-line per check (verify/delete/post-verify/history), concerns, report path.
