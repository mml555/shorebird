# cspell:words pubadd
# The shapes app as an ordinary Android app (applicationId dev.selfhost.untab.signed, label shapes-signed-f2458551):
# flutter create, a local pure-Dart package, intl, `shorebird doctor --fix`, then `shorebird release android --artifact apk`.
set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
trap unlock EXIT
die(){ echo "RELEASE STOP: $*"; exit 1; }
SH=$R/shapes; APP=$R/work/untab; rm -rf $R/work; mkdir -p $R/work; cd $R/work
$FLUTTER create --org dev.selfhost --project-name untab --platforms=android untab > $R/logs/create.log 2>&1 || die "flutter create"
rm -rf $APP/test
mkdir -p $APP/packages/tally/lib
printf 'name: tally\npublish_to: none\nenvironment:\n  sdk: ^3.0.0\n' > $APP/packages/tally/pubspec.yaml
perl -pi -e "s/^version: .*/version: $VERSION/" $APP/pubspec.yaml
perl -0pi -e 's/^dependencies:\n/dependencies:\n  tally:\n    path: packages\/tally\n/m' $APP/pubspec.yaml
G=$(ls $APP/android/app/build.gradle*); grep -n 'applicationId' $G
perl -pi -e 's/applicationId\s*=?\s*"dev\.selfhost\.untab"/applicationId = "dev.selfhost.untab.signed"/' $G
grep -q 'dev.selfhost.untab.signed' $G || die "applicationId not rewritten"
perl -pi -e 's/android:label="[^"]*"/android:label="shapes-signed-f2458551" android:usesCleartextTraffic="true" android:allowBackup="false"/' $APP/android/app/src/main/AndroidManifest.xml
grep -c 'usesCleartextTraffic="true"' $APP/android/app/src/main/AndroidManifest.xml | sed 's/^/cleartext attrs: /'
APP_ID=$(curl -fsS -m 20 -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d '{"display_name":"shapes-signed-f2458551"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || die "create app"
printf 'app_id: %s\nbase_url: %s\n' $APP_ID $BASE > $APP/shorebird.yaml
python3 -I $CLI/selfhost/scripts/lib/add_shorebird_asset.py $APP/pubspec.yaml
echo "APP_ID=$APP_ID" > $R/app.env
python3 -I $SH/variants.py $SH/main.dart $SH/tally.dart base $APP/lib/main.dart $APP/packages/tally/lib/tally.dart || die "base"
cd $APP
$FLUTTER pub add intl > $R/logs/pubadd.log 2>&1 || die "pub add intl"
$FLUTTER analyze --no-fatal-infos lib packages/tally/lib > $R/logs/analyze.log 2>&1 || { cat $R/logs/analyze.log; die "analyze"; }
$SB doctor --fix > $R/logs/doctor.log 2>&1; grep -c INTERNET android/app/src/main/AndroidManifest.xml | sed 's/^/INTERNET manifest entries: /'
lock release; timeout 3600 nice -n 10 $SB release android --artifact apk --public-key-path=$R/keys/a_public.pem --no-confirm -v > $R/logs/release.log 2>&1; rc=$?
unlock; echo "release exit=$rc"; tail -6 $R/logs/release.log | cut -c1-240
[ $rc = 0 ] || die "shorebird release"
APK=$(find build/app/outputs -name '*.apk' | head -1); echo "APK=$APK"; cp "$APK" $R/release.apk; ls -l $R/release.apk; shasum -a 256 $R/release.apk
# Our own test app only: replace it so no state of an earlier build of this package survives.
$ADB -s $DEV uninstall $PKG 2>&1 | tail -1
$ADB -s $DEV install -r $R/release.apk 2>&1 | tail -2
echo RELEASE_DONE
