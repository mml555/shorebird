#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
# The all-or-nothing rollback on a device: a two-target patch that must apply, then forged copies of it
# that must each be refused and rolled back (packages/shorebird_cli/tool/route_b_forge_partial_patch.dart).
# Run after release.sh and up.sh. Boots are detached, so a crash leaves a crash report.
#
#   FORGE_MODES   space-separated, run in order (default: "retarget-last reuse-first-payload append")
#                 retarget-last        last target renamed to a bogus selector     -> REFUSED (target-missing)
#                 reuse-first-payload  last target keeps its selector, carries the
#                                      first target's payload                      -> REFUSED (invalid-bytecode)
#                 append               a bogus target appended after the real ones -> REFUSED (target-missing)
#                 Engines up to 64abe347 crash on reuse-first-payload and append; use FORGE_MODES=retarget-last there.
#   VARIANT       the two-target patch (default p06_async_return+p03_setstate_closure)
#   CHANNEL       an existing channel (default stable)
# Each forged patch is a new patch on the release. After its rollback the updater marks it bad, and the next
# boot goes back to the two-target patch. Logs go to $R/logs/forced_partial.
. "$(dirname "$0")/lib.sh"
. "$R/app.env"
L=$R/logs/forced_partial; mkdir -p "$L"; : > "$L/start"
MODES=${FORGE_MODES:-retarget-last reuse-first-payload append}
VARIANT=${VARIANT:-p06_async_return+p03_setstate_closure}
CHANNEL=${CHANNEL:-stable}
allow=(); [ "$CHANNEL" = stable ] && allow=(--allow-stable)
patch "$VARIANT" two || { echo "TWO-TARGET PATCH FAILED"; exit 1; }
cp "$APP/build/route_b/patch.sbrbptch" "$L/two.sbrbptch"
boot two_download 30; boot two_boot 25
for m in $MODES; do
  case "$m" in retarget-last|reuse-first-payload) flag=(--"$m");; append) flag=();; *) echo "unknown FORGE_MODES entry: $m"; exit 1;; esac
  (cd "$CLI/packages/shorebird_cli" && dart run tool/route_b_forge_partial_patch.dart --i-know-this-is-a-test-patch ${flag[@]+"${flag[@]}"} \
    --container "$L/two.sbrbptch" --out "$L/$m.sbrbptch" --patch-tool "$CLI/bin/cache/artifacts/patch/patch" \
    --private-key "$KEYS_DIR/private.pem" --public-key "$KEYS_DIR/public.pem" \
    --app-id "$APP_ID" --release-version "$VERSION" --channel "$CHANNEL" ${allow[@]+"${allow[@]}"}) > "$L/forge_$m.txt" 2>&1
  rc=$?; echo "=== $m: forge exit=$rc"; grep -E '^  [0-9]+\.|published|release id' "$L/forge_$m.txt"
  [ $rc = 0 ] || { tail -5 "$L/forge_$m.txt"; exit 1; }
  boot "${m}_download" 30; boot "${m}_boot" 25; boot "${m}_after" 25
done
idevicedebug -u "$UDID" kill "$BUNDLE" >/dev/null 2>&1
echo "crash reports since the start (none expected):"; crash_reports "$L" "$L/start"
echo FORCED_PARTIAL_DONE
