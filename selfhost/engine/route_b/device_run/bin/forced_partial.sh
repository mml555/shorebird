#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
# cspell:words idevicedate
# The all-or-nothing rollback on a device: a patch built from two edits in different functions (the
# shapes app's p06+p03 carries 3 targets), which must apply, then forged copies of it that must each be
# refused and rolled back (packages/shorebird_cli/tool/route_b_forge_partial_patch.dart).
# Run after release.sh and up.sh. Boots are detached, so a crash leaves a crash report.
#
#   FORGE_MODES   space-separated, run in order (default: "retarget-last reuse-first-payload append")
#                 retarget-last        last target renamed to a bogus selector     -> REFUSED (target-missing)
#                 reuse-first-payload  last target keeps its selector, carries the
#                                      first target's payload                      -> REFUSED (invalid-bytecode)
#                 append               a bogus target appended after the real ones -> REFUSED (target-missing)
#                 bad-format-last      last payload's bytecode format version set
#                                      to one no VM reads                         -> REFUSED (invalid-bytecode)
#                 unresolve-last       last payload names dart:cor_, a library no
#                                      release has, in place of dart:core         -> REFUSED (invalid-bytecode)
#                 Engines up to 64abe347 crash on reuse-first-payload and append; use FORGE_MODES=retarget-last there.
#                 bad-format-last and unresolve-last need an engine with lineage#11 (older ones abort before main),
#                 so they are not in the default list; the refusal also prints "payload does not load, refused".
#   VARIANT       the patch to forge from (default p06_async_return+p03_setstate_closure)
# Patches go to the stable channel, the one the app polls. Each forged patch is a new patch on the release;
# after its rollback the updater marks it bad and the next boot runs the good patch again.
# Prints PASS or FAIL per mode and exits 1 on any FAIL or crash. Logs go to $R/logs/forced_partial.
. "$(dirname "$0")/lib.sh"
. "$R/app.env"
L=$R/logs/forced_partial; mkdir -p "$L"
START=$(idevicedate -u "$UDID" 2>/dev/null | head -1)  # phone clock, for crash report names
START=$(date -j -f '%a %b %d %T %Z %Y' "$START" +%Y-%m-%d-%H%M%S 2>/dev/null || date +%Y-%m-%d-%H%M%S)
MODES=${FORGE_MODES:-retarget-last reuse-first-payload append}
VARIANT=${VARIANT:-p06_async_return+p03_setstate_closure}
DART="$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart"
fail=0
patch "$VARIANT" two || { echo "TWO-TARGET PATCH FAILED"; exit 1; }
cp "$APP/build/route_b/patch.sbrbptch" "$L/two.sbrbptch"
boot two_download 30; boot two_boot 25
grep -aqE 'ROUTEB: applied ([0-9]+)/\1 targets' "$L/two_boot.sys" || { echo "FAIL two: the patch did not apply fully"; exit 1; }
for m in $MODES; do
  also='ROUTEB'
  case "$m" in
    retarget-last) flag=(--retarget-last); want='REFUSED \(target-missing\)';;
    reuse-first-payload) flag=(--reuse-first-payload); want='REFUSED \(invalid-bytecode\)';;
    append) flag=(); want='REFUSED \(target-missing\)';;
    bad-format-last) flag=(--bad-format-last); want='REFUSED \(invalid-bytecode\)'; also='payload does not load, refused: .*format version';;
    unresolve-last) flag=(--unresolve-last); want='REFUSED \(invalid-bytecode\)'; also='payload does not load, refused: .*Unable to find library';;
    *) echo "unknown FORGE_MODES entry: $m"; exit 1;;
  esac
  (cd "$CLI/packages/shorebird_cli" && "$DART" run tool/route_b_forge_partial_patch.dart --i-know-this-is-a-test-patch ${flag[@]+"${flag[@]}"} \
    --container "$L/two.sbrbptch" --out "$L/$m.sbrbptch" \
    --private-key "$KEYS_DIR/private.pem" --public-key "$KEYS_DIR/public.pem" \
    --app-id "$APP_ID" --release-version "$VERSION" --channel stable --allow-stable) > "$L/forge_$m.txt" 2>&1
  rc=$?; echo "=== $m: forge exit=$rc"; grep -E '^  [0-9]+\.|^published|^release id' "$L/forge_$m.txt"
  [ $rc = 0 ] || { tail -5 "$L/forge_$m.txt"; exit 1; }
  boot "${m}_download" 30; boot "${m}_boot" 25; boot "${m}_after" 25
  s="$L/${m}_boot.sys"
  if grep -aqE "$want" "$s" && grep -aqE "$also" "$s" && grep -aqE 'rolled back ([0-9]+)/\1 attached targets, main runs the release code' "$s"; then
    echo "PASS $m"
  else
    echo "FAIL $m: no '$want' ('$also') with a full rollback in ${m}_boot"; fail=1
  fi
done
idevicedebug -u "$UDID" kill "$BUNDLE" >/dev/null 2>&1
crashes=$(crash_reports "$L" "$START"); crc=$?
if [ $crc != 0 ] || [ -n "$crashes" ]; then echo "FAIL crash reports since $START:"; echo "$crashes"; fail=1; else echo "no crash reports since $START"; fi
[ $fail = 0 ] && echo FORCED_PARTIAL_PASS || echo FORCED_PARTIAL_FAIL
exit $fail
