set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
die(){ echo "RELEASE STOP: $*"; exit 1; }
APP=$R/work/app; rm -rf $R/work; mkdir -p $R/work; cd $R/work
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/94dbee59-269c-42f3-a232-bdbced744580.mobileprovision"
IDENTITY=3965E9C59636AD0C304CFDE5ECFC788EDEF855CD
$FLUTTER create --org dev.selfhost --project-name cell5f6e --platforms=ios app > $R/logs/create.log 2>&1 || die "flutter create"
sed -i '' -E "s/^version: .*/version: $VERSION/" $APP/pubspec.yaml
cat > $APP/lib/main.dart <<'DART'
import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'CELL5F6E-V1-RELEASE'
    : 'CELL5F6E-V1-RELEASE!';

void main() {
  debugPrint('CELL5F6E-MARKER ${markerText()}');
  runApp(const MarkerApp());
}

class MarkerApp extends StatelessWidget {
  const MarkerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(markerText(), style: const TextStyle(fontSize: 30)),
      ),
    ),
  );
}
DART
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d '{"display_name":"cell5f6e"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || die "create app"
printf 'app_id: %s\nbase_url: %s\n' $APP_ID $BASE > $APP/shorebird.yaml
python3 -I $CLI/selfhost/scripts/lib/add_shorebird_asset.py $APP/pubspec.yaml
echo "APP_ID=$APP_ID" > $R/app.env
cd $APP
$SB release ios --no-codesign --no-confirm -v > $R/logs/release.log 2>&1; rc=$?
echo "release exit=$rc"; tail -4 $R/logs/release.log
[ $rc = 0 ] || die "shorebird release"
APPB=$(find build/ios/archive -name Runner.app -path '*Products/Applications*' | head -1)
rm -rf $R/signed && mkdir -p $R/signed && cp -R "$APPB" $R/signed/ && APPB=$R/signed/Runner.app
IOS_DEVICE_UDID=$UDID $CLI/packages/code_push_server/tool/ios_resign.sh "$APPB" "$IDENTITY" "$PROFILE" SK85S6YZP9 $BUNDLE > $R/logs/resign.log 2>&1 || die "resign"
codesign --verify --deep --strict "$APPB" && echo SIGN_OK
echo "CFBundleIdentifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APPB/Info.plist") version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APPB/Info.plist")+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APPB/Info.plist")"
# Upgrade install over the same bundle id: keeps the Local Network grant. Never uninstall.
timeout 300 ios-deploy --id "$UDID" --bundle "$APPB" --nostart > $R/logs/install.txt 2>&1 || { tail -5 $R/logs/install.txt; die "install"; }
tail -1 $R/logs/install.txt
echo RELEASE_DONE
