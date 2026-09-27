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

source_size() { # $1=combo, $2=asset name -> source asset size (empty if unknown)
  jq -r --arg c "$1" --arg n "$2" \
    '[.[] | select(.combo==$c) | .sources[].assets[] | select(.name==$n) | .size][0] // empty' \
    "$WORK/combos.json"
}

phase_create() {
  build_combos
  : > "$MANIFEST"
  local total i=0 combo target utag helium plus f bn have an missing upload_fail
  local -a files failed=()
  total=$(jq 'length' "$WORK/combos.json")
  echo "create: $total combos, manifest $MANIFEST"
  while IFS=$'\t' read -r combo _created target; do
    i=$((i+1))
    utag="helium-portable_${combo}"
    helium="${combo%%_*}"; plus="${combo#*_}"
    if gh release view "$utag" --repo "$REPO" >/dev/null 2>&1; then
      missing=0
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
      if ! download_sources "$combo" "$WORK/zips-$combo"; then
        echo "[$i/$total] FAILED $utag (source download)"
        rm -rf "$WORK/zips-$combo"
        failed+=("$combo")
        continue
      fi
      upload_fail=0
      for f in "$WORK/zips-$combo"/*.zip; do
        [ -e "$f" ] || continue
        bn=$(basename "$f")
        if ! grep -qxF "$bn" <<<"$have"; then
          if gh release upload "$utag" "$f" --repo "$REPO"; then
            echo -e "$utag\t$bn\t$(stat -c%s "$f")" >> "$MANIFEST"
          else
            echo "[$i/$total] FAILED $utag (upload $bn)"
            upload_fail=1
          fi
        fi
      done
      rm -rf "$WORK/zips-$combo"
      if [ "$upload_fail" -ne 0 ]; then
        failed+=("$combo")
      fi
      continue
    fi
    if ! download_sources "$combo" "$WORK/zips-$combo"; then
      echo "[$i/$total] FAILED $utag (source download)"
      rm -rf "$WORK/zips-$combo"
      failed+=("$combo")
      continue
    fi
    files=()
    for f in "$WORK/zips-$combo"/*.zip; do
      [ -e "$f" ] && files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
      echo "[$i/$total] FAILED $utag (no source zips)"
      rm -rf "$WORK/zips-$combo"
      failed+=("$combo")
      continue
    fi
    if gh release create "$utag" "${files[@]}" \
      --repo "$REPO" \
      --title "Helium ${helium} + Chrome++ ${plus}" \
      --target "$target" \
      --notes ""; then
      for f in "${files[@]}"; do
        echo -e "$utag\t$(basename "$f")\t$(stat -c%s "$f")" >> "$MANIFEST"
      done
      rm -rf "$WORK/zips-$combo"
      echo "[$i/$total] CREATED $utag (${#files[@]} assets)"
    else
      echo "[$i/$total] FAILED $utag (release create)"
      rm -rf "$WORK/zips-$combo"
      failed+=("$combo")
    fi
  done < <(jq -r '.[] | [.combo, .created, .target] | @tsv' "$WORK/combos.json")

  local newest
  newest=$(jq -r 'last | .combo' "$WORK/combos.json")
  gh release edit "helium-portable_${newest}" --repo "$REPO" --latest
  echo "Latest -> helium-portable_${newest}"
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "CREATE: ${#failed[@]} FAILED combo(s): ${failed[*]}"
    exit 1
  fi
  echo "CREATE: done ($(wc -l < "$MANIFEST") manifest rows)"
}

phase_verify() {
  build_combos
  local fail=0 expected_combos expected_assets unified_count asset_total
  local combo utag expected have an rn rs size srcsize mname msize
  expected_combos=$(jq 'length' "$WORK/combos.json")
  expected_assets=$(jq '[.[] | .sources[].assets[]] | length' "$WORK/combos.json")
  unified_count=$(jq '[.[] | select(.tag_name | test("^helium-portable_"))] | length' "$WORK/rels.json")
  asset_total=$(jq '[.[] | select(.tag_name | test("^helium-portable_")) | .assets[]? | select(.name | test("helium-portable-(x64|arm64)_.*\\.zip$"))] | length' "$WORK/rels.json")

  [ "$unified_count" -eq "$expected_combos" ] || { echo "FAIL: $unified_count unified releases, expected $expected_combos"; fail=1; }
  [ "$asset_total" -eq "$expected_assets" ] || { echo "FAIL: $asset_total unified zip assets, expected $expected_assets"; fail=1; }
  jq -e '[.[] | select(.tag_name | test("^helium-portable_")) | select(.draft or .prerelease)] | length == 0' "$WORK/rels.json" >/dev/null || { echo "FAIL: draft/prerelease unified release found"; fail=1; }

  declare -A msizes=()
  if [ -f "$MANIFEST" ]; then
    while IFS=$'\t' read -r _ mname msize; do
      [ -z "${mname:-}" ] && continue
      msizes["$mname"]="$msize"
    done < "$MANIFEST"
  fi

  while read -r combo; do
    utag="helium-portable_${combo}"
    expected=$(jq -r --arg c "$combo" '[.[] | select(.combo==$c) | .sources[].assets[].name] | unique | .[]' "$WORK/combos.json")
    have=$(gh release view "$utag" --repo "$REPO" --json assets --jq '.assets[] | .name + "\t" + (.size|tostring)' 2>/dev/null || true)
    declare -A relsizes=()
    while IFS=$'\t' read -r rn rs; do
      [ -z "$rn" ] && continue
      relsizes["$rn"]="$rs"
    done <<<"$have"
    while read -r an; do
      [ -z "$an" ] && continue
      size="${relsizes[$an]:-}"
      if [ -z "$size" ]; then
        echo "FAIL: $utag missing asset $an"; fail=1; continue
      fi
      srcsize=$(source_size "$combo" "$an")
      if [ -n "$srcsize" ]; then
        [ "$size" -eq "$srcsize" ] || { echo "FAIL: $an size $size != source $srcsize"; fail=1; }
      elif [ "$size" -le 0 ]; then
        echo "FAIL: $an has zero size"; fail=1
      fi
      if [ -n "${msizes[$an]:-}" ]; then
        [ "${msizes[$an]}" -eq "$size" ] || { echo "FAIL: manifest $an ${msizes[$an]} != release $size"; fail=1; }
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
  if [ "${DELETE_CONFIRM:-}" != "yes" ]; then
    echo "REFUSED: real delete requires DELETE_CONFIRM=yes." >&2
    echo "Note: the operator DECLINED phase 3 on 2026-09-27 (coexistence is the" >&2
    echo "final state) — run this only on a NEW explicit operator request." >&2
    exit 1
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
  *) echo "usage: $0 create|verify|delete [--dry-run]  (real delete also needs DELETE_CONFIRM=yes)" >&2; exit 2 ;;
esac
