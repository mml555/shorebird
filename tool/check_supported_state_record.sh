#!/usr/bin/env bash
# cspell:words CLIREV partialclonefilter
#
# Checks that selfhost/engine/route_b/SUPPORTED_STATE.yaml is consistent with
# this repository's git history and with the Flutter fork, so a records PR that
# names the wrong CLI or selector fails in CI instead of after it merges.
#
# Cell f2458551's record (#271) named the new selector but left cli_revision at
# the previous CLI, whose bin/internal/flutter.version selects a different
# Flutter. verify_supported_state.sh caught it only after the merge, because it
# needs a bootstrapped checkout and the overlay and so never runs in CI. This
# script is its record-only subset:
#
#   1. The record's format is clean (lib/record_lint.py: no duplicate keys,
#      coherent indentation).
#   2. cli_revision is a commit in this repository and an ancestor of HEAD.
#   3. cli_contains is an ancestor of cli_revision.
#   4. bin/internal/flutter.version at cli_revision is the recorded
#      flutter_selector.
#   5. The packages/shorebird_cli and bin/internal trees at cli_revision are the
#      recorded product trees.
#   6. bin/internal/engine.version at the recorded selector, read from the
#      Flutter fork, is the recorded cell_address. This one needs the network.
#   7. selfhost/compatibility.yaml's shorebird.cli_revision and
#      flutter_revision are the record's cli_revision and flutter_selector.
#
# Check 5 reads the trees at cli_revision, not at HEAD as
# verify_supported_state.sh does. That one asks whether a deployed checkout is
# the qualified CLI; here HEAD is any PR, and most PRs change
# packages/shorebird_cli without being a new supported CLI.
#
# The reader takes the first `key:` line, as verify_supported_state.sh does.
# cell_address appears twice in the record (the top-level one first); keep it so.
#
# It does not check artifacts (compiler archive, analyzer, cell members, engine
# revisions); verify_supported_state.sh does, on a host that has them.
#
# Usage: tool/check_supported_state_record.sh [checkout-root]
#   STATE=<file>        check another copy of the record (for tests)
#   COMPAT=<file>       check another copy of selfhost/compatibility.yaml
#   FLUTTER_REPO=<url>  the Flutter fork (default mml555/shorebird-flutter)
# Exit: 0 all hold, 1 one or more failed, 2 a file, key or fetch is missing.
set -euo pipefail

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
state=${STATE:-$root/selfhost/engine/route_b/SUPPORTED_STATE.yaml}
compat=${COMPAT:-$root/selfhost/compatibility.yaml}
lint="$root/selfhost/engine/route_b/lib/record_lint.py"
flutter_repo=${FLUTTER_REPO:-https://github.com/mml555/shorebird-flutter.git}

for f in "$state" "$compat" "$lint"; do
  [ -f "$f" ] || { echo "check_supported_state_record: missing $f" >&2; exit 2; }
done

# The same reader verify_supported_state.sh uses: the first `key: value` line.
# `|| true`: under pipefail a SIGPIPE in sed would otherwise end the script silently.
val() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" "${2:-$state}" | head -1 || true; }

SELECTOR=$(val flutter_selector)
CLIREV=$(val cli_revision)
CONTAINS=$(val cli_contains)
CELL=$(val cell_address)
TREE_CLI=$(val packages_shorebird_cli)
TREE_BIN=$(val bin_internal)
for kv in "flutter_selector=$SELECTOR" "cli_revision=$CLIREV" "cli_contains=$CONTAINS" \
  "cell_address=$CELL" "packages_shorebird_cli=$TREE_CLI" "bin_internal=$TREE_BIN"; do
  [[ ${kv#*=} =~ ^[0-9a-f]{40}$ ]] || { echo "check_supported_state_record: ${kv%%=*} is not a 40-character hash in $state: '${kv#*=}'" >&2; exit 2; }
done

fail=0
ok() { echo "  ok      $*"; }
bad() { echo "  FAILED  $*"; fail=1; }
same() { # <label> <record> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: record says $2, found ${3:-<none>}"; fi
}

echo "check_supported_state_record: $state"
if out=$(python3 "$lint" "$state" 2>&1); then ok "record format is clean"; else bad "record format: $out"; fi

git=(git -C "$root")
if "${git[@]}" cat-file -e "$CLIREV^{commit}" 2>/dev/null; then
  ok "cli_revision ${CLIREV:0:8} is a commit here"
  if "${git[@]}" merge-base --is-ancestor "$CLIREV" HEAD; then
    ok "cli_revision is an ancestor of HEAD"
  else
    bad "cli_revision $CLIREV is not an ancestor of HEAD"
  fi
  if "${git[@]}" merge-base --is-ancestor "$CONTAINS" "$CLIREV" 2>/dev/null; then
    ok "cli_revision contains cli_contains ${CONTAINS:0:8}"
  else
    bad "cli_revision does not contain cli_contains $CONTAINS"
  fi
  same "flutter.version at cli_revision is the recorded flutter_selector" \
    "$SELECTOR" "$("${git[@]}" show "$CLIREV:bin/internal/flutter.version" 2>/dev/null | tr -d '[:space:]')"
  same "packages/shorebird_cli tree at cli_revision" "$TREE_CLI" "$("${git[@]}" rev-parse "$CLIREV:packages/shorebird_cli" 2>/dev/null)"
  same "bin/internal tree at cli_revision" "$TREE_BIN" "$("${git[@]}" rev-parse "$CLIREV:bin/internal" 2>/dev/null)"
else
  bad "cli_revision $CLIREV is not a commit in this repository (a shallow clone has too little history)"
fi

same "compatibility.yaml shorebird.cli_revision is the record's" "$CLIREV" "$(val cli_revision "$compat")"
same "compatibility.yaml shorebird.flutter_revision is the record's flutter_selector" "$SELECTOR" "$(val flutter_revision "$compat")"

# The selector's own engine.version, from the fork: one commit, its trees, and
# the one blob `git show` asks for. Three tries each, so a network blip is not a
# red ci for an unrelated PR; still failing, it is exit 2 with git's error, never
# a FAILED line.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/flutter"
git -C "$tmp/flutter" remote add origin "$flutter_repo"
git -C "$tmp/flutter" config remote.origin.promisor true
git -C "$tmp/flutter" config remote.origin.partialclonefilter blob:none
try3() { # <what> <command...>; stdout to $tmp/out
  local i
  for i in 1 2 3; do
    "${@:2}" >"$tmp/out" 2>"$tmp/err" && return 0
    [ "$i" = 3 ] || sleep $((i * 5))
  done
  echo "check_supported_state_record: cannot $1 from $flutter_repo after 3 tries:" >&2
  cat "$tmp/err" >&2
  exit 2
}
try3 "fetch flutter_selector $SELECTOR" git -C "$tmp/flutter" fetch -q --depth=1 --filter=blob:none origin "$SELECTOR"
try3 "read bin/internal/engine.version at $SELECTOR" git -C "$tmp/flutter" show "$SELECTOR:bin/internal/engine.version"
same "engine.version at the recorded selector is the recorded cell_address" "$CELL" "$(tr -d '[:space:]' <"$tmp/out")"

if [ "$fail" -ne 0 ]; then
  echo "check_supported_state_record: FAILED" >&2
  exit 1
fi
echo "check_supported_state_record: ok (cli ${CLIREV:0:8} -> selector ${SELECTOR:0:8} -> cell ${CELL:0:8})"
