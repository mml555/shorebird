#!/usr/bin/env bash
# cspell:words dynmod nodm depot caffeinate prebuilt
#
# build_host_nodm_debug.sh -- the NON-dynamic-modules release host and the debug
# host, from the candidate tree, so the published host toolchain shares the
# engine's Dart lineage.
#
# WHY THIS EXISTS. Measured 2026-09-01: the host toolchain published under cell
# H carried Dart lineage 6b58bb3a72 while the iOS engine and the Route B
# compiler cell were at 9e8c898a4d, and `shorebird release ios` died in the AOT
# snapshotter with "Can't load Kernel binary: Invalid SDK hash". out/
# host_release_arm64_nodm had simply never been rebuilt after third_party/dart
# moved -- its args.gn still pins dart_version = 6b58bb3a72.
#
# WHY nodm IS STILL THE RIGHT VARIANT, and is not "just use the dm host":
# the published frontend_server is dm=false and the iOS gen_snapshot is dm=true,
# and that combination is what builds releases today. R3's dm host dill failed
# the iOS AOT step with "Unexpected tag 4 (Field)". Recorded in PARITY.md.
# The defect here is STALENESS, not the dm setting.
#
# TWO TRAPS THIS LANE ALREADY PAID FOR, both in the log rather than the code:
#   * a previous nodm `dart_sdk_archive` step failed on a malformed
#     `//`-rooted entitlements path and left a 138 MB PARTIAL zip with a
#     plausible size. Size is not integrity: every archive is `unzip -t`ed here.
#   * `build_ios_debug_profile.sh` does not use `set -e` and prints ALL DONE
#     regardless. Every step below records its own exit code and the script
#     refuses to claim success if any of them is non-zero.
#
#   screen -dmS routebhost bash -c 'caffeinate -is .../build_host_nodm_debug.sh'
set -u

ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/host_nodm_debug_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
export DEPOT_TOOLS_UPDATE=0

RC_TOTAL=0
say()  { echo "=== $(date '+%F %H:%M:%S') $*" | tee -a "$LOG"; }
step() { # <label> <cmd...>
  local label=$1; shift
  say "BEGIN $label"
  "$@" >> "$LOG" 2>&1
  local rc=$?
  say "END   $label exit=$rc"
  [ "$rc" -eq 0 ] || RC_TOTAL=$((RC_TOTAL+1))
  return $rc
}

cd "$SRC" || { echo "ABORT: $SRC missing" >&2; exit 1; }
say "engine source HEAD: $(git -C "$SRC/flutter" rev-parse HEAD)"
say "dart source  HEAD: $(git -C "$SRC/flutter/third_party/dart" rev-parse HEAD)"

# ---- 1. nodm release host ---------------------------------------------------
# Config DERIVED from the dm host's args.gn minus its dynamic-modules line --
# the same way this dir was originally created -- so the two differ in exactly
# one setting and nothing else drifts.
NODM=out/host_release_arm64_nodm
DM=out/host_release_arm64
[ -f "$DM/args.gn" ] || { say "ABORT: no $DM/args.gn to derive from"; exit 1; }
say "regenerating $NODM/args.gn from $DM/args.gn minus dart_dynamic_modules"
rm -rf "$NODM"; mkdir -p "$NODM"
# DERIVING FROM $DM CARRIES ITS STALE LABELS. Measured 2026-09-01: the DM host's
# args.gn still records dart_version = 6b58bb3a72 even though its own platform
# dill hashes 9e8c898a4d, so a plain copy reproduces the exact defect class this
# lane is repairing -- a label that disagrees with the bytes. dart_version is
# therefore taken from the Dart checkout itself, not inherited.
DART_HEAD=$(git -C "$SRC/flutter/third_party/dart" rev-parse HEAD)
grep -v '^dart_dynamic_modules' "$DM/args.gn" \
  | sed "s|^dart_version = .*|dart_version = \"$DART_HEAD\"|" > "$NODM/args.gn"
say "nodm dart_version set from the Dart checkout: $DART_HEAD"
say "nodm args.gn:"; sed 's/^/    /' "$NODM/args.gn" | tee -a "$LOG" >/dev/null
# The engine's OWN gn binary, not depot_tools' wrapper: the wrapper needs a
# gclient bootstrap this tree has never had ("python3_bin_reldir.txt not
# found"), and `flutter/tools/gn` cannot be used here because it derives the
# out dir name and would clobber out/host_release_arm64 -- the DM host whose
# dill is the compiler cell's identity input.
GN="$SRC/flutter/third_party/gn/gn"
step "gn gen $NODM" "$GN" gen "$NODM"

step "ninja nodm archives" nice -n 5 ninja -C "$NODM" -j 8 \
  flutter/build/archives:dart_sdk_archive \
  flutter/build/archives:flutter_patched_sdk

# ---- 2. debug host ----------------------------------------------------------
DBG=out/host_debug_arm64
step "gn debug" ./flutter/tools/gn --runtime-mode=debug --mac-cpu arm64 --no-prebuilt-dart-sdk
step "ninja debug archives" nice -n 5 ninja -C "$DBG" -j 8 \
  flutter/build/archives:artifacts \
  flutter/build/archives:flutter_patched_sdk

# ---- 3. integrity, because size is not integrity ----------------------------
for z in "$NODM/zip_archives/dart-sdk-darwin-arm64.zip" \
         "$NODM/zip_archives/flutter_patched_sdk_product.zip" \
         "$DBG/zip_archives/flutter_patched_sdk.zip" \
         "$DBG/zip_archives/darwin-arm64/artifacts.zip"; do
  if [ -f "$z" ]; then
    if unzip -t "$z" >/dev/null 2>&1; then
      say "OK   $(basename "$z")  $(wc -c < "$z" | tr -d ' ') bytes  $(shasum -a 256 "$z" | cut -c1-16)"
    else
      say "CORRUPT $z"; RC_TOTAL=$((RC_TOTAL+1))
    fi
  else
    say "MISSING $z"; RC_TOTAL=$((RC_TOTAL+1))
  fi
done

say "args.gn dart_version nodm : $(sed -n 's/^dart_version = //p' "$NODM/args.gn" | tr -d '\"')"
say "args.gn dm flag nodm      : $(grep -c '^dart_dynamic_modules' "$NODM/args.gn") (must be 0)"
say "args.gn dart_version dbg  : $(sed -n 's/^dart_version = //p' "$DBG/args.gn" 2>/dev/null | tr -d '\"')"

if [ "$RC_TOTAL" -eq 0 ]; then say "RESULT: OK"; else say "RESULT: $RC_TOTAL FAILED STEP(S)"; fi
say "log: $LOG"
exit "$RC_TOTAL"
