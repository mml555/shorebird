# cspell:words pubadd nostart
# The shapes app (bundle dev.selfhost.untab, an upgrade install that keeps the Local Network grant):
# flutter create, a local pure-Dart package, intl, then a plain `shorebird release ios`.
# Flutter 3.50 deprecates package:flutter/material.dart (info: use package:material_ui); the app keeps it, so infos are not fatal.
set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
trap unlock EXIT
die(){ echo "RELEASE STOP: $*"; exit 1; }
SH=$R/shapes; APP=$R/work/untab; rm -rf $R/work; mkdir -p $R/work; cd $R/work
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/<profile-uuid>.mobileprovision"
IDENTITY=<signing-identity-sha1>
$FLUTTER create --org dev.selfhost --project-name untab --platforms=ios untab > $R/logs/create.log 2>&1 || die "flutter create"
rm -rf $APP/test
mkdir -p $APP/packages/tally/lib
printf 'name: tally\npublish_to: none\nenvironment:\n  sdk: ^3.0.0\n' > $APP/packages/tally/pubspec.yaml
perl -pi -e "s/^version: .*/version: $VERSION/" $APP/pubspec.yaml
perl -0pi -e 's/^flutter:\n/flutter:\n  config:\n    enable-swift-package-manager: false\n/m' $APP/pubspec.yaml
perl -0pi -e 's/^dependencies:\n/dependencies:\n  tally:\n    path: packages\/tally\n/m' $APP/pubspec.yaml
grep -q 'PRODUCT_BUNDLE_IDENTIFIER = dev.selfhost.untab;' $APP/ios/Runner.xcodeproj/project.pbxproj || die "bundle id"
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d '{"display_name":"shapes-f2458551"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || die "create app"
printf 'app_id: %s\nbase_url: %s\n' $APP_ID $BASE > $APP/shorebird.yaml
python3 -I $CLI/selfhost/scripts/lib/add_shorebird_asset.py $APP/pubspec.yaml
echo "APP_ID=$APP_ID" > $R/app.env
python3 -I $SH/variants.py $SH/main.dart $SH/tally.dart base $APP/lib/main.dart $APP/packages/tally/lib/tally.dart || die "base"
cd $APP
$FLUTTER pub add intl > $R/logs/pubadd.log 2>&1 || die "pub add intl"
$FLUTTER analyze --no-fatal-infos lib packages/tally/lib > $R/logs/analyze.log 2>&1 || { cat $R/logs/analyze.log; die "analyze"; }
lock release; timeout 3600 nice -n 10 $SB release ios --no-codesign --no-confirm -v > $R/logs/release.log 2>&1; rc=$?
unlock; echo "release exit=$rc"; tail -4 $R/logs/release.log; grep -aE "Route B retention|SDK members|keep_sdk" $R/logs/release.log | cut -c1-260 | head -5
[ $rc = 0 ] || die "shorebird release"
grep -o -- '--extra-gen-snapshot-options=--route_b_untabled_overrides' $R/logs/release.log | head -1
APPB=$(find build/ios/archive -name Runner.app -path '*Products/Applications*' | head -1)
rm -rf $R/signed && mkdir -p $R/signed && cp -R "$APPB" $R/signed/ && APPB=$R/signed/Runner.app
IOS_DEVICE_UDID=$UDID $CLI/packages/code_push_server/tool/ios_resign.sh "$APPB" "$IDENTITY" "$PROFILE" <team-id> $BUNDLE > $R/logs/resign.log 2>&1 || die "resign"
codesign --verify --deep --strict "$APPB" && echo SIGN_OK
echo "CFBundleIdentifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APPB/Info.plist") version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APPB/Info.plist")+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APPB/Info.plist")"
# Upgrade install over the same bundle id. Never uninstall.
timeout 300 ios-deploy --id "$UDID" --bundle "$APPB" --nostart > $R/logs/install.txt 2>&1 || { tail -5 $R/logs/install.txt; die "install"; }
tail -1 $R/logs/install.txt
echo RELEASE_DONE
