#!/usr/bin/env bash
# Host check for selfhost/engine/route_b/evidence/p16_engine_updater.md.
#
# Asserts, from source text only (no engine build, no device, no cargo):
#   1. compatibility.yaml's updater_revision is the revision VENDOR.md says
#      vendor/updater is, so the vendored copy the CI tests is the updater the
#      supported engine consumes.
#   2. In that updater, download_and_install_patch verifies the patch signature
#      BEFORE it records a download or touches the network.
#   3. An explicit launch failure marks the patch Bad at once (no retry).
# When an engine checkout is present (ENGINE_SRC, default ~/shorebird-engine/
# flutter/engine/src) and sits on the supported engine revision, it also asserts:
#   4. DEPS pins the same updater revision.
#   5. The Route B wrong-release branch reports launch failure and returns.
#   6. A Route B engine does not bank launch success in the Shell constructor.
# Part 4-6 are skipped, loudly, when the checkout is absent or on another revision.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPAT="$ROOT/selfhost/compatibility.yaml"
VENDOR="$ROOT/vendor/updater"
ENGINE_SRC="${ENGINE_SRC:-$HOME/shorebird-engine/flutter/engine/src}"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

want_updater="$(sed -n 's/^  updater_revision: \([0-9a-f]\{12\}\).*/\1/p' "$COMPAT" | head -1)"
want_engine="$(sed -n 's/^  engine_revision: \([0-9a-f]\{40\}\).*/\1/p' "$COMPAT" | head -1)"
[ -n "$want_updater" ] && [ -n "$want_engine" ] || { echo "FAIL: cannot read revisions from $COMPAT" >&2; exit 1; }

# 1. vendored revision
vend_rev="$(sed -n 's/.*Source revision: \([0-9a-f]\{40\}\).*/\1/p' "$VENDOR/VENDOR.md" | head -1)"
if [ "${vend_rev:0:12}" = "$want_updater" ]; then ok "vendor/updater source revision is $want_updater"
else bad "VENDOR.md source revision '${vend_rev:0:12}' != compatibility.yaml updater_revision '$want_updater'"; fi

# 2. signature verified before any download state or network call
UPD="$VENDOR/library/src/updater.rs"
fn_start="$(grep -n '^fn download_and_install_patch' "$UPD" | head -1 | cut -d: -f1)"
if [ -z "$fn_start" ]; then bad "download_and_install_patch not found in $UPD"
else
  body="$(tail -n +"$fn_start" "$UPD" | sed -n '1,80p')"
  sig="$(printf '%s\n' "$body" | grep -n 'check_patch_signature' | head -1 | cut -d: -f1)"
  rec="$(printf '%s\n' "$body" | grep -n 'record_download_started' | head -1 | cut -d: -f1)"
  net="$(printf '%s\n' "$body" | grep -n 'download_to_path' | head -1 | cut -d: -f1)"
  if [ -n "$sig" ] && [ -n "$rec" ] && [ -n "$net" ] && [ "$sig" -lt "$rec" ] && [ "$sig" -lt "$net" ]; then
    ok "check_patch_signature precedes record_download_started and download_to_path"
  else bad "signature check does not precede download in download_and_install_patch (sig=$sig rec=$rec net=$net)"; fi
fi

# 3. explicit failure retires immediately
if grep -q 'fn prod_c2_explicit_failure_retires_immediately' "$UPD" &&
   grep -A3 'pub fn record_boot_failure' "$VENDOR/library/src/cache/lifecycle.rs" | grep -q 'mark_bad(n, BadReason::BootCrash)'; then
  ok "record_boot_failure marks Bad{BootCrash}; C2 control test present"
else bad "explicit-failure path or its C2 control test changed"; fi

# 4-6 engine checkout
if [ -d "$ENGINE_SRC/flutter" ] && [ "$(git -C "$ENGINE_SRC/flutter" rev-parse HEAD 2>/dev/null)" = "$want_engine" ]; then
  deps_rev="$(sed -n 's/^  "updater_rev": "\([0-9a-f]*\)".*/\1/p' "$(git -C "$ENGINE_SRC/flutter" rev-parse --show-toplevel)/DEPS" | head -1)"
  [ "${deps_rev:0:12}" = "$want_updater" ] && ok "engine DEPS updater_rev is $deps_rev" ||
    bad "engine DEPS updater_rev '$deps_rev' != $want_updater"
  SB="$ENGINE_SRC/flutter/shell/common/shorebird/shorebird.cc"
  if grep -A12 'running_id != container.release_build_id' "$SB" | grep -q 'ReportRefusal();'; then
    ok "wrong-release branch calls ReportRefusal (ReportLaunchFailure)"
  else bad "wrong-release branch no longer reports launch failure"; fi
  # In shell.cc the Route B arm (between '#if SHOREBIRD_ROUTE_B' and '#else') must not call success.
  if sed -n '/^#if SHOREBIRD_ROUTE_B/,/^#else/p' "$ENGINE_SRC/flutter/shell/common/shell.cc" | grep -v '^ *//' | grep -q 'ReportLaunchSuccess'; then
    bad "Route B Shell constructor banks launch success"
  else ok "Route B Shell constructor does not bank launch success"; fi
else
  echo "skip: no engine checkout at supported revision $want_engine under $ENGINE_SRC (checks 4-6 not run)"
fi

exit "$fail"
