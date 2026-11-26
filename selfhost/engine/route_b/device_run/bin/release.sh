#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
# cspell:words pubadd nostart
# The shapes app (bundle id $BUNDLE, default dev.selfhost.untab; an upgrade install that keeps the Local Network grant):
# flutter create, a local pure-Dart package, intl, then a plain `shorebird release ios`.
set -uo pipefail
. "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
export PATH="$CLI/bin:$PATH"
die(){ echo "RELEASE STOP: $*"; exit 1; }
# Patch signing: the CLI refuses a release without a key. The pair lives in KEYS_DIR, outside the repo;
# private.pem must never be committed. A missing pair is created; an existing one is reused.
KEYS_DIR="${KEYS_DIR:-$R/keys}"  # an env.sh from before KEYS_DIR existed has none
case "$(cd "$(dirname "$KEYS_DIR")" 2>/dev/null && pwd -P)/" in "$(cd "$CLI" && pwd -P)/"*) die "KEYS_DIR=$KEYS_DIR is inside the repo at CLI=$CLI; keep keys outside it";; esac
if [ ! -s "$KEYS_DIR/private.pem" ]; then
  [ ! -e "$KEYS_DIR/public.pem" ] || die "$KEYS_DIR/public.pem has no usable private.pem beside it"
  (umask 077 && mkdir -p "$KEYS_DIR" && openssl genrsa -out "$KEYS_DIR/private.pem" 2048) > "$R/logs/keys.log" 2>&1 || { cat "$R/logs/keys.log"; die "openssl genrsa"; }
  openssl rsa -in "$KEYS_DIR/private.pem" -outform PEM -pubout -out "$KEYS_DIR/public.pem" >> "$R/logs/keys.log" 2>&1 || { cat "$R/logs/keys.log"; die "openssl rsa"; }
fi
[ -s "$KEYS_DIR/public.pem" ] || die "$KEYS_DIR/private.pem has no public.pem beside it"
case "$(stat -f %Lp "$KEYS_DIR/private.pem")" in 600|400) ;; *) die "$KEYS_DIR/private.pem is readable by others: chmod 600 it";; esac
# R must be a dedicated directory: this script deletes $R/work and $R/signed.
[ -n "$R" ] && [ "$R" != / ] && [ -d "$R" ] || die "R must be an existing, dedicated directory (got: ${R:-empty})"
BUNDLE_ORG="${BUNDLE%.*}"; BUNDLE_NAME="${BUNDLE##*.}"
SH=$(cd "$(dirname "${BASH_SOURCE[0]}")/../shapes" && pwd); APP="$R/work/untab"; rm -rf "$R/work"; mkdir -p "$R/work"; cd "$R/work"
"$FLUTTER" create --org "$BUNDLE_ORG" --project-name "$BUNDLE_NAME" --platforms=ios untab > "$R/logs/create.log" 2>&1 || die "flutter create"
rm -rf "$APP/test"
mkdir -p "$APP/packages/tally/lib"
printf 'name: tally\npublish_to: none\nenvironment:\n  sdk: ^3.0.0\n' > "$APP/packages/tally/pubspec.yaml"
perl -pi -e "s/^version: .*/version: $VERSION/" "$APP/pubspec.yaml"
perl -0pi -e 's/^flutter:\n/flutter:\n  config:\n    enable-swift-package-manager: false\n/m' "$APP/pubspec.yaml"
perl -0pi -e 's/^dependencies:\n/dependencies:\n  tally:\n    path: packages\/tally\n/m' "$APP/pubspec.yaml"
grep -q "PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE;" "$APP/ios/Runner.xcodeproj/project.pbxproj" || die "bundle id"
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H @<(printf 'Authorization: Bearer %s\n' "$API_KEY") -H 'Content-Type: application/json' -d "{\"display_name\":\"shapes-${ENGINE_REV:0:8}\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || die "create app"
printf 'app_id: %s\nbase_url: %s\n' "$APP_ID" "$BASE" > "$APP/shorebird.yaml"
python3 -I "$CLI/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
echo "APP_ID=$APP_ID" > "$R/app.env"
python3 -I "$SH/variants.py" "$SH/main.dart" "$SH/tally.dart" base "$APP/lib/main.dart" "$APP/packages/tally/lib/tally.dart" || die "base"
cd "$APP"
"$FLUTTER" pub add intl > "$R/logs/pubadd.log" 2>&1 || die "pub add intl"
"$FLUTTER" analyze --no-fatal-infos lib packages/tally/lib > "$R/logs/analyze.log" 2>&1 || { cat "$R/logs/analyze.log"; die "analyze"; }
nice -n 10 "$SB" release ios --no-codesign --public-key-path="$KEYS_DIR/public.pem" --no-confirm -v > "$R/logs/release.log" 2>&1; rc=$?
echo "release exit=$rc"; tail -4 "$R/logs/release.log"
[ $rc = 0 ] || die "shorebird release"
grep -o -- '--extra-gen-snapshot-options=--route_b_untabled_overrides' "$R/logs/release.log" | head -1
APPB=$(find build/ios/archive -name Runner.app -path '*Products/Applications*' | head -1)
rm -rf "$R/signed" && mkdir -p "$R/signed" && cp -R "$APPB" "$R/signed/" && APPB="$R/signed/Runner.app"
IOS_DEVICE_UDID="$UDID" "$CLI/packages/code_push_server/tool/ios_resign.sh" "$APPB" "$SIGN_IDENTITY" "$PROVISIONING_PROFILE" "$TEAM_ID" "$BUNDLE" > "$R/logs/resign.log" 2>&1 || die "resign"
codesign --verify --deep --strict "$APPB" && echo SIGN_OK
echo "CFBundleIdentifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APPB/Info.plist") version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APPB/Info.plist")+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APPB/Info.plist")"
# Upgrade install over the same bundle id. Never uninstall.
timeout 300 ios-deploy --id "$UDID" --bundle "$APPB" --nostart > "$R/logs/install.txt" 2>&1 || { tail -5 "$R/logs/install.txt"; die "install"; }
tail -1 "$R/logs/install.txt"
echo RELEASE_DONE
