#!/usr/bin/env bash
# verify_supported_state.sh -- re-check the DEPLOYABLE IDENTITY claims in
# SUPPORTED_STATE.yaml against the artifacts themselves.
#
# The record is only worth having if it can be falsified. Each check below reads
# the artifact rather than the record, then compares. A drifted stack fails here
# instead of being discovered during an upgrade.
#
# COVERED: cli_revision and its ancestry, cli_contains, the selector chain on
# both links from COMMITTED blobs, cell_address, compiler archive digest and
# size, analyzer digest (from the published archive, mandatorily),
# producer_engine_revision, dart_revision, fallback_engine_revision,
# updater_revision against the committed compatibility pin, every addressed cell
# member against the bytes served, and the deeper compiler/runtime audit.
#
# NOT COVERED, because they are not mechanically checkable from artifacts: the
# supported/unsupported construct lists, the operational requirements, the
# physical-device qualification, and the historical compatibility numbers. Those
# are records of measurements made elsewhere and cited there.
#
# MISSING EVIDENCE IS NEVER A PASS. Every check that cannot read its artifact
# fails; only the runtime-cache copy of the analyzer is optional, and only
# because the published archive it mirrors is checked unconditionally first.
#
#   SHOREBIRD_ROOT=<a shorebird checkout with a populated bin/cache> \
#     selfhost/engine/route_b/verify_supported_state.sh
#
# Exit: 0 all checks pass · 1 one or more failed · 2 environment error
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
STATE="$HERE/SUPPORTED_STATE.yaml"
ROOT=${SHOREBIRD_ROOT:-/Volumes/build/route-b/shorebird-candidate}

[[ -f "$STATE" ]] || { echo "no SUPPORTED_STATE.yaml at $STATE" >&2; exit 2; }
val() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" "$STATE" | head -1; }

# THE RECORD MUST ACTUALLY BE MACHINE-READABLE.
#
# It calls itself a machine/human-readable record, and `val` reads it with sed --
# which happily parses a file no YAML loader accepts. It did: `selector_chain`
# held a sequence and a mapping key at the same indent, so every check passed
# against a document that would not load. A claim about format is a claim, and
# claims here get checked.
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$STATE" 2>/dev/null; then
    PARSE_OK=1
  else
    PARSE_OK=0
  fi
else
  PARSE_OK=skip
fi

fails=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  FAILED  %s\n' "$*"; fails=$((fails+1)); }
cmp_v() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: record says $2, artifact is ${3:-<none>}"; fi
}

SELECTOR=$(val flutter_selector)
CLIREV=$(val cli_revision)
CLICONTAINS=$(val cli_contains)
CELL=$(val cell_address)
ARCHIVE=$(val compiler_archive_sha256)
ARCHBYTES=$(val compiler_archive_bytes)
ANALYZER=$(val analyzer_sha256)

echo "verify_supported_state -- record $STATE"
case "$PARSE_OK" in
  1) ok "record parses as YAML" ;;
  0) bad "record does NOT parse as YAML — it claims to be machine-readable" ;;
  *) echo "  --      no python3; YAML parse not checked" ;;
esac
echo "  shorebird root : $ROOT"

# 1. THE SELECTOR CHAIN, read from the artifacts a build actually walks --
#    and on BOTH links from the COMMITTED blob, never the working tree.
#
# Reading the CLI's selector with `cat` was a hole: an uncommitted
# bin/internal/flutter.version would have qualified, which is exactly what the
# Flutter-side check below exists to prevent. Both sides now read git.
if git -C "$REPO" cat-file -e "$CLIREV^{commit}" 2>/dev/null; then
  ok "recorded cli_revision exists in this repository"
  if git -C "$REPO" merge-base --is-ancestor "$CLIREV" HEAD 2>/dev/null; then
    ok "cli_revision is in this branch's history"
  else
    bad "cli_revision $CLIREV is not an ancestor of HEAD — the record names a revision this branch does not contain"
  fi
  if [[ -n "$CLICONTAINS" ]] && git -C "$REPO" merge-base --is-ancestor "$CLICONTAINS" "$CLIREV" 2>/dev/null; then
    ok "cli_revision contains ${CLICONTAINS:0:8} (private-name resolution)"
  else
    bad "cli_revision does not contain ${CLICONTAINS:-<none>}"
  fi
  cmp_v "CLI flutter.version (committed blob at cli_revision) selects the recorded Flutter" \
    "$SELECTOR" "$(git -C "$REPO" show "$CLIREV:bin/internal/flutter.version" 2>/dev/null | tr -d '[:space:]')"
else
  bad "recorded cli_revision ${CLIREV:-<none>} is not a commit in this repository"
fi

# THE QUALIFIED PRODUCT TREE, IN BOTH PLACES.
#
# Ancestry says a revision is in history; it says nothing about whether the CLI
# code has moved since. A descendant that edits route_b_producer.dart and leaves
# flutter.version alone passes every ancestry and cleanliness check while running
# a producer that was never qualified. Compare the git TREE objects instead --
# they are the bytes, and they cannot be argued with.
TREE_CLI=$(val packages_shorebird_cli)
TREE_BIN=$(val bin_internal)
for spec in "packages/shorebird_cli|$TREE_CLI" "bin/internal|$TREE_BIN"; do
  pth=${spec%%|*}; want=${spec##*|}
  if [[ -z "$want" ]]; then bad "no recorded tree for $pth"; continue; fi
  cmp_v "repo HEAD product tree $pth" "$want" \
    "$(git -C "$REPO" rev-parse "HEAD:$pth" 2>/dev/null)"
  # The runtime checkout, from its COMMITTED HEAD rather than its working tree:
  # a clean tree only says nothing is unstaged, not that it is the right commit.
  cmp_v "runtime checkout product tree $pth" "$want" \
    "$(git -C "$ROOT" rev-parse "HEAD:$pth" 2>/dev/null)"
done
if [[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  ok "runtime checkout has no uncommitted changes at all"
else
  bad "runtime checkout has uncommitted changes"
fi

# The RUNTIME checkout must be running that same committed selector, not a local
# edit of it.
cmp_v "runtime checkout's flutter.version matches the committed selector" \
  "$SELECTOR" "$(cat "$ROOT/bin/internal/flutter.version" 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$(git -C "$ROOT" status --porcelain -- bin/internal 2>/dev/null)" ]]; then
  ok "runtime checkout's bin/internal is clean"
else
  bad "runtime checkout has uncommitted changes under bin/internal"
fi

FDIR="$ROOT/bin/cache/flutter/$SELECTOR"
if [[ -d "$FDIR/.git" ]]; then
  # COMMITTED blob, not the working tree: an uncommitted engine.version must
  # never be part of the qualified lineage, and reading the file would not see
  # the difference.
  cmp_v "Flutter engine.version (committed blob) selects the recorded cell" \
    "$CELL" "$(git -C "$FDIR" show HEAD:bin/internal/engine.version 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$(git -C "$FDIR" status --porcelain 2>/dev/null)" ]]; then
    ok "Flutter checkout is clean"
  else
    bad "Flutter checkout has uncommitted changes"
  fi
else
  bad "no Flutter checkout at $FDIR"
fi

# 2. THE CELL'S BYTES.
ZIP="$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/$CELL/route-b-compiler-darwin-arm64.zip"
if [[ -f "$ZIP" ]]; then
  cmp_v "compiler archive digest" "$ARCHIVE" "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  cmp_v "compiler archive size"   "$ARCHBYTES" "$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")"
else
  bad "no published compiler archive at $ZIP"
fi

# THE ANALYZER, FROM THE PUBLISHED ARCHIVE — MANDATORY.
#
# This used to fall back to "not resolved into this root's cache yet (not a
# failure)" and still print VERIFIED. A record that names an exact consumed
# analyzer digest cannot be verified by an absent artifact: missing evidence must
# never produce a pass. The archive is the authority, because it is what any
# machine resolves from; a local cache is a convenience on top of it.
if [[ -f "$ZIP" ]]; then
  UNZ=$(mktemp -d)
  if unzip -qo "$ZIP" route_b_analyze.aot -d "$UNZ" 2>/dev/null && [[ -f "$UNZ/route_b_analyze.aot" ]]; then
    cmp_v "analyzer digest (extracted from the published archive)" \
      "$ANALYZER" "$(shasum -a 256 "$UNZ/route_b_analyze.aot" | cut -d' ' -f1)"
    # PROVENANCE identities the record also claims.
    if unzip -qo "$ZIP" PROVENANCE.txt -d "$UNZ" 2>/dev/null; then
      cmp_v "producer engine revision" "$(val producer_engine_revision)" \
        "$(sed -nE 's/^engine revision[[:space:]]*:[[:space:]]*([0-9a-f]+).*/\1/p' "$UNZ/PROVENANCE.txt" | head -1)"
      cmp_v "dart revision" "$(val dart_revision)" \
        "$(sed -nE 's/^dart revision[[:space:]]*:[[:space:]]*([0-9a-f]+).*/\1/p' "$UNZ/PROVENANCE.txt" | head -1)"
    else
      bad "published archive carries no PROVENANCE.txt"
    fi
  else
    bad "published archive does not contain route_b_analyze.aot"
  fi
  rm -rf "$UNZ"
else
  bad "cannot verify the analyzer: no published archive"
fi

# The resolved cache, WHEN present, must agree with the archive. Absence here is
# genuinely not a failure -- the mandatory check above already ran.
CACHED="$ROOT/bin/cache/artifacts/route-b-compiler/$CELL/route_b_analyze.aot"
if [[ -f "$CACHED" ]]; then
  cmp_v "analyzer digest (as resolved into the runtime cache)" \
    "$ANALYZER" "$(shasum -a 256 "$CACHED" | cut -d' ' -f1)"
else
  echo "  --      analyzer not resolved into this root's cache (archive already verified)"
fi

# 3. THE ADDRESS AUTHENTICATES ITSELF.
MAN="$HERE/cell_manifests/$CELL.v2"
if [[ -f "$MAN" ]]; then
  cmp_v "v2 manifest recomputes to the cell address" \
    "$CELL" "$(shasum -a 256 "$MAN" | cut -c1-40)"
else
  bad "no v2 address manifest registered for $CELL"
fi

# 4. EVERY ADDRESSED MEMBER STILL EQUALS THE BYTES SERVED.
#    PUBLISH-V2 proved 16/16 at publication; this asks whether they have drifted
#    since, which is the only question a supported-state check can answer.
if bash "$HERE/verify_cell_members.sh" "$CELL" >/dev/null 2>&1; then
  ok "all addressed cell members match the bytes served"
else
  bad "cell member drift — run verify_cell_members.sh $CELL for the detail"
fi

if [[ -f "$MAN" ]]; then
  cmp_v "fallback engine revision" "$(val fallback_engine_revision)" \
    "$(awk '$1=="fallback_engine_revision"{print $2}' "$MAN" | head -1)"
fi

# The updater pin, against the committed compatibility record rather than a
# rebuilt binary: this proves the two committed records agree, which is what it
# can honestly prove.
cmp_v "updater revision agrees with selfhost/compatibility.yaml" \
  "$(val updater_revision)" \
  "$(sed -nE 's/^[[:space:]]*updater_revision:[[:space:]]*([0-9a-f]+).*/\1/p' "$REPO/selfhost/compatibility.yaml" | head -1)"

# 4b. SOURCE DURABILITY. Every engine revision the record names as a producer of
#     EXECUTABLE cell members must be resolvable from a durable remote, at the
#     identity the record claims -- commit sha and parent sha, not a branch name
#     ([[branches-are-not-provenance]]).
#
#     A cell whose executables were produced by a commit living on one machine is
#     authenticated but not repository-closed: nobody can rebuild or review the
#     bytes. This was ruled a real durability defect, so it is checked here
#     rather than left to a lane document.
#
#     Requires network, and being offline is a FAILURE, not a skip: this file's
#     rule is that missing evidence must never produce a pass. SKIP_DURABILITY=1
#     exists for a deliberately offline run and says so out loud.
#     Two strengths, because the two producers are different kinds of thing.
#     The Android producer carries a diff THIS REPO BANKS, so its content is
#     checked against the banked patch. The macOS/iOS producer is
#     upstream-derived and this repo banks no patch for it, so the honest claim
#     there is reachability -- and claiming more would be a check that cannot
#     fail for the right reason.
DUR_PAR=$(sed -nE 's/^[[:space:]]*android_parent:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$STATE" | head -1)
DUR_FULL=$(sed -nE 's/^[[:space:]]*android_members:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$STATE" | sort -u)
DUR_ANY=$(sed -nE 's/^[[:space:]]*(producer_lineage|macos_ios_members):[[:space:]]*([0-9a-f]{40}).*/\2/p' "$STATE" | sort -u)
if [[ "${SKIP_DURABILITY:-0}" == 1 ]]; then
  echo "  SKIP    SOURCE DURABILITY NOT CHECKED (SKIP_DURABILITY=1) — this run does"
  echo "          not establish that any producer revision is resolvable"
else
  for rev in $DUR_FULL; do
    if bash "$HERE/verify_engine_producer_durable.sh" --rev "$rev" --parent "$DUR_PAR" >/dev/null 2>&1; then
      ok "engine producer ${rev:0:12} durable AND matches the banked patch, parent ${DUR_PAR:0:12}"
    else
      bad "engine producer $rev is NOT durable — run verify_engine_producer_durable.sh --rev $rev"
    fi
  done
  for rev in $DUR_ANY; do
    grep -q "$rev" <<<"$DUR_FULL" && continue
    if bash "$HERE/verify_engine_producer_durable.sh" --rev "$rev" --exists-only >/dev/null 2>&1; then
      ok "engine producer ${rev:0:12} is reachable on the remote"
    else
      bad "engine producer $rev is NOT reachable — run verify_engine_producer_durable.sh --rev $rev --exists-only"
    fi
  done
  [[ -n "$DUR_FULL$DUR_ANY" ]] || bad "the record names no engine producer revision to check"
fi

# 5. THE DEEPER COMPILER/RUNTIME AUDIT.
if bash "$HERE/audit_route_b_compiler.sh" --hash "$CELL" >/dev/null 2>&1; then
  ok "audit_route_b_compiler: AUDIT CLEAN"
else
  bad "audit_route_b_compiler reported findings for $CELL"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo "SUPPORTED STATE VERIFIED"
else
  echo "SUPPORTED STATE FAILED: $fails check(s)"
fi
exit $(( fails > 0 ))
