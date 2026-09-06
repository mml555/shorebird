#!/usr/bin/env bash
# cspell:words gcs semantic linker dartaotruntime aot dill localsend wonderous
# freeze.sh -- SEMANTIC-LINKER-1 / G0. Freeze the selfhost-v1.1.1 baseline and
# the ACTUAL source bytes that produced it, and make the freeze falsifiable.
#
# WHY THIS IS NOT verify_supported_state.sh. That script checks the SUPPORTED
# record against the artifacts it names, and this lane runs it unchanged (see
# evidence/verify_supported_state.txt). It stops at the artifacts. This one asks
# the question the next gate depends on: can the source those artifacts were
# built from be RECONSTRUCTED, byte for byte, from something other than one
# disk? G1 has to rebuild that lineage twice, with Dynamic Modules off and on,
# so "the commit is recorded" is not enough -- a commit that exists nowhere but
# a working checkout is not a lineage anyone can build from.
#
# It found two things the supported record does not carry, and both are recorded
# in FREEZE.md rather than smoothed over:
#
#   1. The producing Dart tree is DIRTY. A 15-line uncommitted guard in
#      pkg/front_end/lib/src/source/source_loader.dart is compiled into the
#      SHIPPED dart2bytecode.aot -- proven by finding the guard's own message
#      string in the published archive, against positive controls that show the
#      probe can fail. So `dart_revision: 9e8c898a...` does not identify the
#      source that produced the cell, and provenance may not be claimed from
#      that commit alone.
#   2. That Dart lineage is LOCAL-DISK-ONLY. 9e8c898a is on no remote -- not
#      even in the clone its own checkout names as `origin`.
#
# Both are why banked_source/dart/ exists. The bank is checked by REPLAY, not by
# assertion: the series is applied to a fresh checkout of the vanilla base and
# the resulting git TREE OBJECT is compared to the producer's. Tree objects are
# the bytes; ancestry and commit messages are not ([[ancestry-is-not-identity]]).
#
#   freeze.sh [--verify | --emit]
#
# --verify (default) re-checks freeze_manifest.json against reality and fails on
# any drift. --emit rewrites the manifest; use it only when a recorded identity
# has legitimately moved, and say why in FREEZE.md.
#
# Exit: 0 clean · 1 one or more checks failed · 2 environment error
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
MANIFEST="$HERE/freeze_manifest.json"
BANK="$HERE/banked_source"

# THE FROZEN BASELINE. These are the tracker's (#36/#37) expected identities,
# written here so the script can refuse a baseline that is not the one this lane
# was authorised against, rather than freezing whatever it happens to find.
EXPECT_TAG=selfhost-v1.1.1
EXPECT_COMMIT=bdb234ab938fc0570e499d800928a0c3d640bfe1
EXPECT_CLI=46ee70af56c3814d079cc2466b092481c7904e76
EXPECT_SELECTOR=5b180d224df04a267a19888c3f344474e243b382
EXPECT_CELL=f85251f344600ae08196925a174e9cff8f0ff18e
EXPECT_ENGINE=dfa2b24ac38477f3705ff0357530f33fe09474b8
EXPECT_DART=9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c

# The producing source, as measured by this gate. DART_BASE is the vanilla
# commit the engine's own DEPS pins; DART_EFFECTIVE_TREE is the git tree of
# HEAD plus the uncommitted guard, which is what actually built the cell.
DART_BASE=d684a576a6aa954ae107a03b2b4e1d61c3bebe93
DART_HEAD_TREE=aa55ff960f07682fd098195e4884f2cbcb4f5f27
DART_EFFECTIVE_TREE=7b04b01bdc10ec990143257f0d28580571c2122f
DART_DIRTY_FILE=pkg/front_end/lib/src/source/source_loader.dart
ENGINE_TREE=26acc7f47d809563a08212c8264516aae64f10d5

# Where the producing checkouts live on this machine. They are INPUTS to the
# freeze, not part of it: the whole point of the bank is that the freeze
# survives their loss. Absent, the source checks report UNAVAILABLE (not a pass)
# and the replay check still runs, because it needs only the bank and a vanilla
# base.
ENGINE_SRC=${ENGINE_SRC:-/Volumes/build/route-b/flutter}
DART_SRC=${DART_SRC:-$ENGINE_SRC/engine/src/flutter/third_party/dart}
# A repository that carries the vanilla Dart base, for the replay check.
DART_BASE_REPO=${DART_BASE_REPO:-/Volumes/build/ios-engine/dart-sdk}
OVERLAY=${OVERLAY:-$REPO/selfhost/cdn/overlay}

MODE=verify
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) MODE=verify; shift ;;
    --emit)   MODE=emit;   shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fails=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  FAILED  %s\n' "$*"; fails=$((fails+1)); }
cmp_v(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected $2, got ${3:-<none>}"; fi; }
sha()  { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

echo "freeze.sh ($MODE) -- SEMANTIC-LINKER-1 G0"
echo "  repo    : $REPO"

# ---------------------------------------------------------------- distribution
TAGOBJ=$(git -C "$REPO" rev-parse "$EXPECT_TAG" 2>/dev/null)
TAGCOMMIT=$(git -C "$REPO" rev-parse "$EXPECT_TAG^{commit}" 2>/dev/null)
cmp_v "tag $EXPECT_TAG resolves to the expected commit" "$EXPECT_COMMIT" "$TAGCOMMIT"
[[ "$(git -C "$REPO" cat-file -t "$EXPECT_TAG" 2>/dev/null)" == tag ]] \
  && ok "the tag is annotated (immutable intent, not a moved branch)" \
  || bad "$EXPECT_TAG is not an annotated tag"
COMMIT_TREE=$(git -C "$REPO" rev-parse "$EXPECT_COMMIT^{tree}" 2>/dev/null)

# The RECORD AT THE TAG, read from the committed blob rather than the working
# tree -- the working copy has moved on, and that is exactly the drift this
# check exists to survive.
STATE=$(git -C "$REPO" show "$EXPECT_COMMIT:selfhost/engine/route_b/SUPPORTED_STATE.yaml" 2>/dev/null)
[[ -n "$STATE" ]] || { echo "cannot read SUPPORTED_STATE.yaml at $EXPECT_COMMIT" >&2; exit 2; }
rval() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" <<<"$STATE" | head -1; }

cmp_v "record at the tag names the expected cli_revision"   "$EXPECT_CLI"      "$(rval cli_revision)"
cmp_v "record at the tag names the expected flutter_selector" "$EXPECT_SELECTOR" "$(rval flutter_selector)"
cmp_v "record at the tag names the expected cell_address"   "$EXPECT_CELL"     "$(rval cell_address)"
cmp_v "record at the tag names the expected producer engine" "$EXPECT_ENGINE"  "$(rval producer_engine_revision)"
cmp_v "record at the tag names the expected dart_revision"  "$EXPECT_DART"     "$(rval dart_revision)"

TREE_CLI=$(git -C "$REPO" rev-parse "$EXPECT_COMMIT:packages/shorebird_cli" 2>/dev/null)
TREE_BIN=$(git -C "$REPO" rev-parse "$EXPECT_COMMIT:bin/internal" 2>/dev/null)
cmp_v "product tree packages/shorebird_cli at the tag" "$(rval packages_shorebird_cli)" "$TREE_CLI"
cmp_v "product tree bin/internal at the tag"           "$(rval bin_internal)"           "$TREE_BIN"

# ----------------------------------------------------------------------- cell
ZIP="$OVERLAY/download.shorebird.dev/shorebird/$EXPECT_CELL/route-b-compiler-darwin-arm64.zip"
ARCHIVE_SHA=""; ARCHIVE_BYTES=""
if [[ -f "$ZIP" ]]; then
  ARCHIVE_SHA=$(sha "$ZIP")
  ARCHIVE_BYTES=$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")
  cmp_v "compiler archive digest" "$(rval compiler_archive_sha256)" "$ARCHIVE_SHA"
  cmp_v "compiler archive size"   "$(rval compiler_archive_bytes)"  "$ARCHIVE_BYTES"
else
  bad "no published compiler archive at $ZIP (the overlay is untracked; hydrate it)"
fi
MAN="$REPO/selfhost/engine/route_b/cell_manifests/$EXPECT_CELL.v2"
MAN_SHA=""
if [[ -f "$MAN" ]]; then
  MAN_SHA=$(sha "$MAN")
  cmp_v "v2 address manifest recomputes to the cell address" "$EXPECT_CELL" "${MAN_SHA:0:40}"
else
  bad "no v2 address manifest for $EXPECT_CELL"
fi

# THE UNCOMMITTED GUARD IS IN THE SHIPPED BYTES. This is the finding the freeze
# turns on, so it is re-proved on every run rather than cited -- and it is proved
# WITH POSITIVE CONTROLS. A probe that cannot find a string known to be there
# says nothing when it fails to find the one under test
# ([[vacuous-checks-are-worse-than-missing]]); the first cut of this check used
# `grep -F` straight at the binary, found neither, and would have "cleared" the
# tree. Strings are extracted, and a control must hit before the subject counts.
GUARD_NEEDLE='which is a platform library. This option may only name an'
CONTROL_NEEDLE='resolvePrivateNamesInLibrary'
GUARD_IN_SHIPPED=unknown
if [[ -f "$ZIP" ]]; then
  U=$(mktemp -d)
  if unzip -qo "$ZIP" dart2bytecode.aot -d "$U" 2>/dev/null; then
    S=$(strings -n 6 "$U/dart2bytecode.aot")
    if grep -qF "$CONTROL_NEEDLE" <<<"$S"; then
      ok "string probe is live (positive control '$CONTROL_NEEDLE' found in dart2bytecode.aot)"
      if grep -qF "$GUARD_NEEDLE" <<<"$S"; then
        GUARD_IN_SHIPPED=true
        ok "the uncommitted guard IS compiled into the shipped dart2bytecode.aot"
      else
        GUARD_IN_SHIPPED=false
        bad "the guard string is absent from the shipped artifact — the freeze's central finding no longer holds; re-derive it before trusting this manifest"
      fi
    else
      bad "string probe is VACUOUS: the positive control is missing, so absence of the guard would prove nothing"
    fi
  else
    bad "cannot extract dart2bytecode.aot from the published archive"
  fi
  rm -rf "$U"
fi

# ------------------------------------------------------- producing engine tree
if git -C "$ENGINE_SRC" rev-parse --git-dir >/dev/null 2>&1; then
  cmp_v "producing engine checkout HEAD" "$EXPECT_ENGINE" "$(git -C "$ENGINE_SRC" rev-parse HEAD 2>/dev/null)"
  cmp_v "producing engine tree object"   "$ENGINE_TREE"   "$(git -C "$ENGINE_SRC" rev-parse 'HEAD^{tree}' 2>/dev/null)"
else
  echo "  --      producing engine checkout absent at $ENGINE_SRC (the bank does not depend on it)"
fi

# --------------------------------------------------------- producing dart tree
# The bank is what this gate delivers, so it is checked FIRST and independently
# of whether the producing checkout still exists.
BANK_OK=1
for p in "$BANK"/dart/0001-*.patch "$BANK"/dart/0002-*.patch "$BANK"/dart/9999-worktree-uncommitted.patch; do
  [[ -f "$p" ]] || { bad "banked patch missing: $p"; BANK_OK=0; }
done

if [[ "$BANK_OK" == 1 ]]; then
  if [[ -d "$DART_BASE_REPO" ]] && git -C "$DART_BASE_REPO" cat-file -e "$DART_BASE^{commit}" 2>/dev/null; then
    R=$(mktemp -d)/replay
    if git clone -q --shared --no-checkout "$DART_BASE_REPO" "$R" 2>/dev/null \
       && git -C "$R" checkout -q --detach "$DART_BASE" 2>/dev/null; then
      if git -C "$R" am -q "$BANK"/dart/0001-*.patch "$BANK"/dart/0002-*.patch 2>/dev/null; then
        cmp_v "banked series replays to the producer's committed Dart tree" \
          "$DART_HEAD_TREE" "$(git -C "$R" rev-parse 'HEAD^{tree}')"
        if git -C "$R" apply "$BANK/dart/9999-worktree-uncommitted.patch" 2>/dev/null; then
          IDX=$(mktemp)
          GIT_INDEX_FILE=$IDX git -C "$R" read-tree HEAD
          GIT_INDEX_FILE=$IDX git -C "$R" add -- "$DART_DIRTY_FILE"
          cmp_v "bank + worktree delta replays to the EFFECTIVE producing tree" \
            "$DART_EFFECTIVE_TREE" "$(GIT_INDEX_FILE=$IDX git -C "$R" write-tree)"
          rm -f "$IDX"
        else
          bad "the banked worktree delta does not apply to the replayed tree"
        fi
      else
        bad "the banked Dart series does not apply to $DART_BASE"
      fi
    else
      bad "could not stand up a replay checkout from $DART_BASE_REPO"
    fi
    rm -rf "$(dirname "$R")"
  else
    bad "no repository carrying the vanilla Dart base $DART_BASE — the replay check cannot run, and an unreplayed bank is an unverified one"
  fi
fi

# DURABILITY OF THE DART LINEAGE. Recorded as a finding, and re-measured, because
# it is the one identity in the frozen stack that no remote carries
# ([[branches-are-not-provenance]] cuts both ways: a commit with no ref anywhere
# is not provenance either).
DART_DURABLE=false
for R in ${DART_REMOTES:-https://github.com/shorebirdtech/dart-sdk.git}; do
  if git ls-remote "$R" 2>/dev/null | awk -v r="$EXPECT_DART" '$1==r{f=1} END{exit !f}'; then
    DART_DURABLE=true; ok "the producing Dart revision is advertised on $R"
  fi
done
[[ "$DART_DURABLE" == true ]] || echo "  note    the producing Dart revision $EXPECT_DART is on NO remote — the bank in banked_source/dart/ is the only durable form of it"

# ------------------------------------------------------------------- manifest
if [[ "$MODE" == emit ]]; then
  P1=$(ls "$BANK"/dart/0001-*.patch); P2=$(ls "$BANK"/dart/0002-*.patch)
  P9="$BANK/dart/9999-worktree-uncommitted.patch"
  cat > "$MANIFEST" <<JSON
{
  "schema": "semantic-linker-1/g0-freeze/1",
  "gate": "SL1-G0",
  "tracker": 36,
  "issue": 37,
  "frozen": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "distribution": {
    "tag": "$EXPECT_TAG",
    "tag_object": "$TAGOBJ",
    "tag_is_annotated": true,
    "commit": "$EXPECT_COMMIT",
    "commit_tree": "$COMMIT_TREE"
  },
  "record_at_tag": {
    "cli_revision": "$(rval cli_revision)",
    "cli_contains": "$(rval cli_contains)",
    "flutter_selector": "$(rval flutter_selector)",
    "cell_address": "$(rval cell_address)",
    "producer_engine_revision": "$(rval producer_engine_revision)",
    "fallback_engine_revision": "$(rval fallback_engine_revision)",
    "dart_revision": "$(rval dart_revision)",
    "updater_revision": "$(rval updater_revision)",
    "packages_shorebird_cli": "$TREE_CLI",
    "bin_internal": "$TREE_BIN"
  },
  "cell": {
    "address": "$EXPECT_CELL",
    "v2_manifest_sha256": "$MAN_SHA",
    "compiler_archive_sha256": "$ARCHIVE_SHA",
    "compiler_archive_bytes": $ARCHIVE_BYTES,
    "analyzer_sha256": "$(rval analyzer_sha256)",
    "uncommitted_guard_in_shipped_dart2bytecode": $GUARD_IN_SHIPPED
  },
  "producing_source": {
    "engine": {
      "revision": "$EXPECT_ENGINE",
      "tree": "$ENGINE_TREE",
      "clean": true,
      "untracked_build_inputs": {
        ".gcs_entries": "engine/src/flutter/prebuilts/macos-arm64/dart-sdk <- db98bdaa9d8f8e2250ff83d24abcaf775807244c/dart-sdk-darwin-arm64.tar.gz"
      },
      "durable_remote": "https://github.com/mml555/shorebird-flutter.git",
      "durable_refs": ["refs/heads/route-b-2c-candidate", "refs/tags/acs2-macos-ios-producer"]
    },
    "dart": {
      "revision": "$EXPECT_DART",
      "head_tree": "$DART_HEAD_TREE",
      "effective_tree": "$DART_EFFECTIVE_TREE",
      "effective_tree_note": "HEAD plus the uncommitted guard; THIS is what built the cell",
      "deps_pinned_base": "$DART_BASE",
      "dirty_paths": ["$DART_DIRTY_FILE"],
      "durable_remote": null,
      "durability": "LOCAL-DISK-ONLY — banked here as patches",
      "bank": {
        "$(basename "$P1")": "$(sha "$P1")",
        "$(basename "$P2")": "$(sha "$P2")",
        "$(basename "$P9")": "$(sha "$P9")"
      }
    }
  },
  "qualification_references": {
    "ios": "SUPPORTED_STATE.yaml physical_device_qualification — iPhone 7 / iOS 15.8.8, 2026-09-03, release 142, patch 106/1",
    "android": "evidence/android-final-stack-2/RESULT.md — wired CPH2551, 2026-09-04",
    "note": "referenced, not rewritten; this lane measures neither"
  },
  "producer_demand_baseline": {
    "wonderous": "50.00%",
    "localsend": "92.67%",
    "source": "selfhost/engine/route_b/evidence/producer_demand_2.md"
  },
  "corpus_pins": {
    "wonderous_window_sha256": "$(sha "$REPO/selfhost/engine/route_b/coverage/demand1/wonderous.window.txt")",
    "localsend_window_sha256": "$(sha "$REPO/selfhost/engine/route_b/coverage/demand1/localsend.window.txt")",
    "replay_is_optional": true,
    "rule": "a fresh replay must never substitute newer app revisions"
  },
  "excluded": {
    "coverage/baseline_a.json": "VOID — minted from an engine tree carrying 18 uncommitted files; retracted in COMPATIBILITY_STUDY.md. Must not be used as a baseline."
  }
}
JSON
  ok "wrote $MANIFEST"
else
  [[ -f "$MANIFEST" ]] && ok "manifest present: $MANIFEST" || bad "no manifest — run with --emit"
fi

echo
if [[ "$fails" -eq 0 ]]; then echo "G0 FREEZE VERIFIED"; else echo "G0 FREEZE FAILED: $fails check(s)"; fi
exit $(( fails > 0 ))
