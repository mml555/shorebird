set -uo pipefail
. $RUN/env.sh
export PATH="$CLI/bin:$PATH"
FLUTTER=$CLI/bin/cache/flutter/f6bbc8a0b4e4d12f824edea754d05f86047d6c8f/bin/flutter
APP=$R/work/app; rm -rf $R/work; mkdir -p $R/work; cd $R/work
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/94dbee59-269c-42f3-a232-bdbced744580.mobileprovision"
IDENTITY=3965E9C59636AD0C304CFDE5ECFC788EDEF855CD
$FLUTTER create --org dev.selfhost --project-name cell82fc --platforms=ios app > create.log 2>&1 || { echo create failed; tail create.log; exit 1; }
cat > $APP/lib/main.dart <<'DART'
import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'CELL82FC-V1-RELEASE'
    : 'CELL82FC-V1-RELEASE!';

void main() {
  debugPrint('CELL82FC-MARKER ${markerText()}');
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
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d '{"display_name":"cell82fc"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
printf 'app_id: %s\nbase_url: %s\n' $APP_ID $BASE > $APP/shorebird.yaml
python3 -I $CLI/selfhost/scripts/lib/add_shorebird_asset.py $APP/pubspec.yaml
echo "APP_ID=$APP_ID" > $R/app.env
cd $APP
$SB release ios --no-codesign --no-confirm -v
echo "release exit=$?"
APPB=$(find build/ios/archive -name Runner.app -path '*Products/Applications*' | head -1)
echo "APPB=$APPB"
$CLI/packages/code_push_server/tool/ios_resign.sh "$APPB" "$IDENTITY" "$PROFILE" SK85S6YZP9 $BUNDLE
codesign --verify --deep --strict "$APPB" && echo SIGN_OK
rm -rf $R/signed && mkdir -p $R/signed && cp -R "$APPB" $R/signed/
echo RELEASE_DONE
