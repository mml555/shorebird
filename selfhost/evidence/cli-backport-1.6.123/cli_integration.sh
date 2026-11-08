#!/usr/bin/env bash
# Command-level integration: backported CLI vs local self-hosted server.
set -u
S="$(cd "$(dirname "$0")" && pwd)"; source "$S/seed.env"
export SHOREBIRD_HOSTED_URL=http://localhost:18099 SHOREBIRD_TOKEN=sb_api_backportcheck_0123456789abcdef
B=$SHOREBIRD_HOSTED_URL; K=$SHOREBIRD_TOKEN; CLI="$S/shorebird-bp"; cd "$S/proj"
pass=0; fail=0
run() { # name expected_exit(0|nonzero) grep_pattern -- cmd...
  local name=$1 want=$2 pat=$3; shift 4
  local out; out=$("$CLI" "$@" 2>&1); local rc=$?
  local ok=1
  if [[ $want == 0 && $rc -ne 0 ]]; then ok=0; fi
  if [[ $want == nonzero && $rc -eq 0 ]]; then ok=0; fi
  if [[ -n $pat ]] && ! grep -qE "$pat" <<<"$out"; then ok=0; fi
  if [[ $ok == 1 ]]; then pass=$((pass+1)); echo "PASS [$rc] $name"; else fail=$((fail+1)); echo "FAIL [$rc] $name"; fi
  sed 's/^/        | /' <<<"$out" | grep -v "^        | $" | tail -4
}
check() { # name actual expected
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "PASS       $1 = $2"; else fail=$((fail+1)); echo "FAIL       $1 = $2 (want $3)"; fi
}
dev() { curl -s -H 'content-type: application/json' -d "{\"app_id\":\"$APP\",\"release_version\":\"1.0.0\",\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"$1\"}" $B/api/v1/patches/check; }
api() { curl -s -H "Authorization: Bearer $K" "$@"; }
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "## rollback"
run "rollback patch 1" 0 "rolled back" -- patches rollback --app-id $APP --release-version 1.0.0 --patch-number 1
check "device check rolled_back_patch_numbers" "$(dev stable | j 'd["rolled_back_patch_numbers"]')" "[1]"
run "rollback repeat reports already rolled back (304)" 0 "already rolled back" -- patches rollback --app-id $APP --release-version 1.0.0 --patch-number 1
run "rollback repeat --require-change fails" nonzero "already rolled back" -- patches rollback --app-id $APP --release-version 1.0.0 --patch-number 1 --require-change
run "rollback --json" 0 '"changed": ?false' -- patches rollback --app-id $APP --release-version 1.0.0 --patch-number 1 --json
run "patches list shows rolled back" 0 "" -- patches list --app-id $APP --release-version 1.0.0

echo "## rollforward (intentionally unsupported)"
run "rollforward fails explicitly" nonzero "not supported by this self-hosted server" -- patches rollforward --app-id $APP --release-version 1.0.0 --patch-number 1
run "rollforward --json fails explicitly" nonzero '"status": ?"error"' -- patches rollforward --app-id $APP --release-version 1.0.0 --patch-number 1 --json
check "patch still rolled back after rollforward" "$(dev stable | j 'd["rolled_back_patch_numbers"]')" "[1]"

echo "## apps rename"
run "apps rename" 0 "Renamed" -- apps rename --app-id $APP --name "Backport Renamed"
check "server display_name" "$(api $B/api/v1/apps | j 'd["apps"][0]["display_name"]')" "Backport Renamed"

echo "## channels"
run "channels create qa" 0 "" -- channels create --app-id $APP --name qa
run "channels list shows qa" 0 "qa" -- channels list --app-id $APP
run "channels delete without confirm refused" nonzero "" -- channels delete --app-id $APP --name qa
run "channels delete stable refused (built-in)" nonzero "permanent|cannot be deleted" -- channels delete --app-id $APP --name stable --confirm-name stable
run "channels delete qa" 0 "" -- channels delete --app-id $APP --name qa --confirm-name qa
check "qa hidden from server listing" "$(api $B/api/v1/apps/$APP/channels | j '"qa" in [c["name"] for c in d]')" "False"

echo "## apps transfer"
run "transfer into current org is a no-op" 0 "" -- apps transfer --app-id $APP --org-id 1
run "transfer into an org the caller is not in is refused" nonzero "account orgs" -- apps transfer --app-id $APP --org-id 999

echo "## apps delete (no server route; see matrix)"
run "apps delete" nonzero "" -- apps delete --app-id $APP --confirm-name "Backport Renamed"
check "app still exists" "$(api $B/api/v1/apps | j 'len(d["apps"])')" "1"

echo "## unchanged surface"
run "account whoami (no /plan call)" 0 "" -- account whoami

echo; echo "TOTAL pass=$pass fail=$fail"
