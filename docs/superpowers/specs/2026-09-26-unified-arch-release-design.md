# Unified Per-Version Release — Design

Date: 2026-09-26
Status: approved by operator (design decisions recorded inline); pending spec review

**Execution status (2026-09-27):** Operator answered "Không xóa" — phase-3
deletion of the 73 per-arch releases was **DECLINED**. Final state is
**coexistence: 127 releases = 73 old per-arch retained + 54 unified**;
phase 3 must NOT run without a new explicit operator request. The notes at
decision 2, Phase 3, and §7 are retained as historical but superseded.

## 1. Discovery

### Original request

The operator observed that the two architectures are published on **separate
releases** (one release per arch per version), so when a new build exists for
one arch the other release is not updated — the two arches are not unified.

### Investigation findings

- Upstream `imputnet/helium-windows` publishes **both arch zips in a single
  release** per version (verified across the 8 most recent releases: every tag
  contains `*_x64-windows.zip` and `*_arm64-windows.zip`). Version skew does
  not originate upstream.
- Current `main.yml` resolves upstream's single `releases/latest`, then runs a
  matrix build where **each arch job publishes to its own per-arch tag**
  (`helium-portable-{arch}_{heliumVer}_{plusVer}`) via softprops.
- Real asymmetries that remain:
  - GitHub's **"Latest" marker** points at only one of the two releases.
  - Each version spans **two release pages**; users must pick the right one.
  - Failure semantics are **per-arch**: if one arch job fails while the other
    publishes, the releases skew until the hourly cron heals them (or forever,
    if the combo's tag is superseded before the failed arch retries).
  - Historical skew already exists: 35 combos are x64-only (pre-arm64 era).
- Inventory at design time (repo `hoangxg4/helium_browser_portable`):
  **73 releases / 54 unique combos** (54 x64, 19 arm64; 35 x64-only combos,
  19 dual-arch combos), **all release bodies empty, zero prereleases**.

### Operator decisions (recorded)

1. **One release per version combo containing both arch zips** (chosen over
   keeping two releases with sync guarantees).
2. **Migrate the full history**: create unified releases for all 54 combos,
   then delete the 73 per-arch releases (historical URLs may change).
   *[Superseded 2026-09-27: deletion declined, the 73 per-arch releases are retained — see Execution status.]*
3. **Approach 1 — artifact bridge**: matrix jobs build and upload artifacts; a
   single final `release` job publishes both zips to one tag (chosen over
   concurrent same-tag publishing and over a single sequential build job).

## 2. Release contract

| Aspect | Rule |
|---|---|
| Tag | `helium-portable_{heliumVer}_{plusVer}` (single tag, no arch segment) |
| Release name | `Helium {heliumVer} + Chrome++ {plusVer}` (no arch suffix) |
| Assets | `helium-portable-x64_{heliumVer}_{plusVer}.zip` **and** `helium-portable-arm64_{heliumVer}_{plusVer}.zip` — asset names unchanged (self-describing, never collide) |
| Body | empty (matches current state; no auto-notes) |
| Latest marker | exactly one Latest release: the newest combo |
| Failure semantics | **all-or-nothing**: if either arch build fails, nothing is published |
| Self-repair | existence check passes only if the unified tag exists **and contains both zip assets**; a tag with a missing zip counts as "not released" → rebuild → softprops `overwrite: true` adds/overwrites the zip in the same release |
| Manual dispatch | forces a full rebuild; both zips are overwritten in place in the same unified release |

## 3. Workflow design (`main.yml`)

Pipeline: `check → build (matrix) → release`.

### 3.1 `check` job (modified)

- Keeps upstream version/URL resolution unchanged (single
  `releases/latest` from `imputnet/helium-windows`, Chrome++ latest).
- Replaces the two per-arch existence checks with **one** check: the release
  with tag `helium-portable_{heliumVer}_{plusVer}` exists **and** both zip
  assets are present (API `releases/tags/{tag}` + asset-name count).
  Output: `exists` (`true`/`false`).
- `workflow_dispatch` → `exists=false` (force rebuild), same as today.

### 3.2 `build` matrix job (modified tail only)

- **All build steps from download through `Compress-Archive` stay byte-identical**
  (issue #7 guards, hibbiki layout assembly, pre-package assertions — all
  untouched and still pinned by validate.yml).
- The zip filename keeps the arch segment
  (`helium-portable-{arch}_{heliumVer}_{plusVer}.zip` = asset name).
- The `Release` step (softprops) is **removed from the matrix** and replaced by
  `actions/upload-artifact@v4` uploading the zip as artifact `zip-{arch}`.
- Job-level `if:` becomes `needs.check.outputs.exists == 'false'`.

### 3.3 `release` job (new)

```yaml
release:
  needs: [check, build]   # build failed or skipped → release skipped (all-or-nothing)
  runs-on: ubuntu-latest
  steps:
    - actions/download-artifact@v4 (both zip-*)
    - softprops/action-gh-release@v2:
        tag_name: helium-portable_{heliumVer}_{plusVer}
        name: Helium {heliumVer} + Chrome++ {plusVer}
        files: both zips
        overwrite: true
```

- Default `needs` success semantics give all-or-nothing for free.
- On schedule, when `exists=true` the build job is skipped → release job is
  skipped (no-op run stays quiet).
- On force dispatch with an existing release, the job overwrites both assets
  in place (rebuild-in-place, same behavior the fix waves relied on).

### 3.4 `schedule`

Hourly cron unchanged; logic becomes simpler (one tag instead of two).

### 3.5 `validate.yml` updates

Add pins to the `Validate build workflow` step:

- unified tag scheme present: `tag_name: helium-portable_${{` (no arch in the
  release tag);
- exactly one `action-gh-release` reference in `main.yml` (release job only);
- `upload-artifact` present in `main.yml`;
- `needs: [check, build]` gating present for the release job.

Existing pins stay as-is (matrix/arch, `\\\\App\\\\` rejection, version.dll
selection + assertions, hibbiki layout greps, `Compress-Archive` line, issue
#7 guards).

### 3.6 Explicitly unchanged

- Zip layout / build steps / issue #7 regression guards.
- `README.md`: contains no hardcoded release URLs (verified) — no edits needed.
- `update.bat`: queries **upstream** `imputnet/helium-windows` only (verified
  `update.bat:14`) — unaffected by this repo's release restructure.
- `debloater.reg`, `Skip=11` preamble constraint.

## 4. History migration

One committed script: `scripts/migrate-unified-releases.sh` (audit trail for a
destructive operation). Three phases; **phase 3 cannot run without explicit
operator approval after phase 2 output is reviewed**.

### Phase 1 — create (idempotent)

For each of the 54 combos, ascending by original release creation time:

1. Skip if unified tag already exists **and** contains every asset the combo's
   old releases hold (safe to re-run at any point).
2. `gh release create helium-portable_{combo}`
   `--title "Helium {h} + Chrome++ {p}"`
   `--target <target_commitish copied from an existing per-arch release>`
   (empty body, matching current state).
3. Download the combo's existing per-arch zip(s) and `gh release upload` them
   under their original asset names (x64-only combos upload just x64).
4. Record per-asset `size` for verification.

### Phase 2 — verify (no writes)

Re-query the API and require **all** of:

- 54 unified releases exist with the exact expected tags;
- total assets across unified releases = **73** (54 x64 + 19 arm64 zips);
- every asset **the script uploaded in phase 1** has a byte size equal to its
  source per-arch asset's size; assets that already existed before migration
  (e.g. `0.18.1.1` rebuilt by the e2e verification) are verified present with
  the exact expected name and non-zero size instead of size equality;
- newest combo `helium-portable_0.18.1.1_1.18.2` is marked **Latest**
  (explicit `gh release edit --latest` applied in phase 1's last iteration);
- zero unified release is a draft or prerelease.

### Phase 3 — delete (gated on operator approval)

*[Superseded 2026-09-27 — retained as historical procedure; do NOT run without a new explicit operator request. See Execution status.]*

Only after phase 2 is green and the operator approves:

1. Delete the 73 per-arch releases (`gh release delete --yes`).
2. Delete the 73 orphaned git tags (`git push origin --delete {tag}`).
3. Re-verify: release list = exactly the 54 unified tags; Latest marker intact.

Any failure before phase 3 leaves the repo untouched (phase separation is the
rollback story: nothing is deleted until everything is proven).

### Note on historical content

Migrated old releases keep their **original zips byte-for-byte** (old flat
layout for pre-restructure versions). Rebuilding history is a non-goal.

## 5. Verification plan

1. Local: run every `validate.yml` step under `bash -e` (Task 6 harness
   pattern) → `ALL VALIDATE STEPS PASSED`; parse both workflow YAMLs.
2. Push → Validate workflow green.
3. `gh workflow run main.yml` → Build workflow green → assert:
   - exactly one release `helium-portable_0.18.1.1_1.18.2` carries **both**
     fresh zips (assets' `updated_at` moved; still 2 assets, correct names);
   - no new per-arch release appeared;
   - Latest marker on the unified release.
4. Zip probe (Task 6 logic) on **both** assets: 91 entries, layout assertions
   (nested Widevine, no flat `data_dir`, no `Data`/`Cache`, policy_key comment).
5. Migration dry-run output reviewed → operator approval → phase 3 →
   post-deletion verification (54 releases, 73 assets, Latest correct).

## 6. Non-goals

- No changes to the zip layout, build steps, or issue #7 guards.
- No changes to `update.bat`, `debloater.reg`, `bypass_windows_defender.bat`,
  `default-apps-multi-profile.bat`, `chrome++.ini`.
- No rebuild/backport of historical zips.
- No automatic cleanup policy for future releases.
- No changes to README (no hardcoded release links exist).

## 7. Risks

- **Destructive phase** (deleting 73 releases + tags) is gated on explicit
  approval after verification; phase separation prevents partial rollouts.
- Hotlinked/old release URLs break after phase 3 — accepted by the operator.
  *[Superseded 2026-09-27: phase 3 declined; URLs remain stable — retained as historical.]*
- softprops `overwrite: true` replaces same-name assets only; asset names
  differ per arch, so no accidental cross-arch overwrite is possible.
- Concurrent hourly cron vs. manual dispatch racing the release job: both
  target the same tag with the same asset names; worst case is a redundant
  overwrite of identical content (same as today's behavior).
