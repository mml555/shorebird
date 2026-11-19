#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
# cspell:words untab sdkprobe nostart
# Release for the SDK instance-member device probe: a Flutter app (bundle id $BUNDLE, an upgrade
# install that keeps the Local Network grant) whose main.dart is the generated main_release.dart.
# Like ../bin/release.sh, minus the tally package and intl. Needs ../bin/up.sh running.
# Reads its settings from $DEVRUN_ENV (default ../env.sh; copy ../env.example.sh and fill it in): R, CLI, UDID,
# BASE, ARTIFACT_UPSTREAM, ENGINE_REV, FLUTTER_REV, SIGN_IDENTITY, PROVISIONING_PROFILE, TEAM_ID, BUNDLE, VERSION
# (the run used 1.0.0+63), and API_KEY from $SECRETS_FILE. It derives SB and FLUTTER. The API key goes to curl
# through a header file descriptor, not the command line.
set -uo pipefail
. "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
export PATH="$CLI/bin:$PATH"
die(){ echo "RELEASE STOP: $*"; exit 1; }
[ -n "$R" ] && [ "$R" != / ] && [ -d "$R" ] || die "R must be an existing, dedicated directory"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP="$R/work/untab"; rm -rf "$R/work"; mkdir -p "$R/work"; cd "$R/work"
python3 -I "$HERE/gen_device_probe.py" "$R/gen" > "$R/logs/gen.log" 2>&1 || die "gen_device_probe.py"
BUNDLE_ORG="${BUNDLE%.*}"; BUNDLE_NAME="${BUNDLE##*.}"
"$FLUTTER" create --org "$BUNDLE_ORG" --project-name "$BUNDLE_NAME" --platforms=ios untab > "$R/logs/create.log" 2>&1 || die "flutter create"
rm -rf "$APP/test"
perl -pi -e "s/^version: .*/version: $VERSION/" "$APP/pubspec.yaml"
perl -0pi -e 's/^flutter:\n/flutter:\n  config:\n    enable-swift-package-manager: false\n/m' "$APP/pubspec.yaml"
grep -q "PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE;" "$APP/ios/Runner.xcodeproj/project.pbxproj" || die "bundle id"
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H @<(printf 'Authorization: Bearer %s\n' "$API_KEY") -H 'Content-Type: application/json' -d '{"display_name":"sdkprobe"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || die "create app"
printf 'app_id: %s\nbase_url: %s\n' "$APP_ID" "$BASE" > "$APP/shorebird.yaml"
python3 -I "$CLI/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
echo "APP_ID=$APP_ID" > "$R/app.env"
cp "$R/gen/main_release.dart" "$APP/lib/main.dart"
cd "$APP"
"$FLUTTER" pub get > "$R/logs/pubget.log" 2>&1 || die "pub get"
"$FLUTTER" analyze --no-fatal-infos --no-fatal-warnings lib > "$R/logs/analyze.log" 2>&1 || { head -30 "$R/logs/analyze.log"; die "analyze"; }
nice -n 10 "$SB" release ios --no-codesign --no-confirm -v > "$R/logs/release.log" 2>&1; rc=$?
echo "release exit=$rc"; tail -4 "$R/logs/release.log" | cut -c1-200
[ $rc = 0 ] || die "shorebird release"
if [ -n "${KEPT_GATE:-}" ]; then
  # The kept release must have real code for every member the counter release threw on, before it goes on the phone.
  python3 -I "$HERE/check_kept.py" "$APP/build/route_b_snapshot_profile.json" "$R/gen/probes.tsv" "$HERE/result/results.tsv" "$R/logs/kept_check.tsv" --gate "$KEPT_GATE" || die "kept gate: members still missing (see $R/logs/kept_check.tsv)"
fi
grep -o -- '--extra-gen-snapshot-options=--route_b_untabled_overrides' "$R/logs/release.log" | head -1
APPB=$(find build/ios/archive -name Runner.app -path '*Products/Applications*' | head -1)
rm -rf "$R/signed" && mkdir -p "$R/signed" && cp -R "$APPB" "$R/signed/" && APPB="$R/signed/Runner.app"
IOS_DEVICE_UDID="$UDID" "$CLI/packages/code_push_server/tool/ios_resign.sh" "$APPB" "$SIGN_IDENTITY" "$PROVISIONING_PROFILE" "$TEAM_ID" "$BUNDLE" > "$R/logs/resign.log" 2>&1 || die "resign"
codesign --verify --deep --strict "$APPB" && echo SIGN_OK
echo "CFBundleIdentifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APPB/Info.plist") version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APPB/Info.plist")+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APPB/Info.plist")"
timeout 300 ios-deploy --id "$UDID" --bundle "$APPB" --nostart > "$R/logs/install.txt" 2>&1 || { tail -5 "$R/logs/install.txt"; die "install"; }
tail -1 "$R/logs/install.txt"
echo RELEASE_DONE
