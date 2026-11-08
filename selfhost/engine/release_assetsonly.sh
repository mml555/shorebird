#!/usr/bin/env bash
# cspell:words FLREV FLDIR rbtest pathlib assetsonly
# Release rbtest against OUR engine (the one carrying the assets-only guard), on
# Linux, so libapp.so comes from our gen_snapshot.
#
# Adapted from /data/shorebird-engine/release_routeb.sh. Two deliberate
# differences from that script:
#   - EXP is the new hash, which carries PatchCarriesCode().
#   - The mirror is reached over HTTPS. Gradle 8+ refuses an `http` Maven repo
#     without an explicit opt-in, and FlutterPlugin.kt on this box has been
#     reverted to stock now that TLS works — so plain http would fail at
#     :app:mergeReleaseAssets before any Flutter artifact is fetched.
set -euo pipefail

R=/data/shorebird-engine
FLREV=c15ef6379403a0a55531a058bdb2c8e55bc05c98
EXP=760e3fabffbf31b4e86919a0ef47d6ce5f182991
export PATH="$R/shorebird/bin:$PATH"

export SHOREBIRD_HOSTED_URL=http://localhost:18080
export FLUTTER_STORAGE_BASE_URL=https://localhost:8443
export SHOREBIRD_STORAGE_BASE_URL=https://localhost:8443
export SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev
export SHOREBIRD_TOKEN="$(cat $R/api_key.txt)"

echo "== tunnels =="
printf '  control plane : %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$SHOREBIRD_HOSTED_URL/api/v1/patches/check" -d '{}' -H 'content-type: application/json' || echo FAIL)"
printf '  mirror (ours) : %s\n' "$(curl -sSk -o /dev/null -w '%{http_code}' --max-time 40 "$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/flutter/$EXP/android-arm64-release/artifacts.zip" || echo FAIL)"

FLDIR="$R/shorebird/bin/cache/flutter/$FLREV"
# Point the checkout at our engine BEFORE any build runs, or the first release
# silently uses the stock one.
echo "$EXP" > "$FLDIR/bin/internal/engine.version"
echo "== engine the build will use: $(cat "$FLDIR/bin/internal/engine.version") =="

cd "$R/rbtest"
set_base_url() {
  if grep -q '^base_url:' shorebird.yaml; then
    sed -i "s#^base_url:.*#base_url: $SHOREBIRD_HOSTED_URL#" shorebird.yaml
  else
    printf '\nbase_url: %s\n' "$SHOREBIRD_HOSTED_URL" >> shorebird.yaml
  fi
}
# This app was registered against an older server instance, so re-register it.
set_base_url
echo "== init app on the current control plane =="
shorebird init --display-name "rbtest-assetsonly-v3" --force 2>&1 | tail -3 || true
set_base_url
grep -E '^app_id|^base_url' shorebird.yaml

echo "== releasing from LINUX so libapp.so comes from OUR gen_snapshot =="
# --no-tree-shake-icons is REQUIRED on a self-built engine: icon tree shaking runs
# const_finder, a kernel snapshot stamped with the SDK hash of whatever Dart built
# it, so ours fails with "Invalid SDK hash".
nice -n 10 shorebird release android --no-confirm --artifact=apk \
  --flutter-version="$FLREV" -- --no-tree-shake-icons 2>&1 | tail -25
