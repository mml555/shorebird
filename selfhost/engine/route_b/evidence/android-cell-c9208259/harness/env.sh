# Cell c9208259 PHYSICAL ANDROID run (2026-11-27), CLI 4a3adb1d (#313 head; shares run-c9208259/cli). The iOS run is in run-c9208259.
export R=~/Developer/shorebird-wt/devrun/android-c9208259; export CLI=~/Developer/shorebird-wt/devrun/run-c9208259/cli; export PATH=/opt/homebrew/bin:$PATH
export CELL=c920825972cdc7e096fa114bbb616b306914c4c7 FLUTTER_REV=246fd6f6fc70f2c4a7fb9b563eda5fcdccba2104
export ADB=~/Library/Android/sdk/platform-tools/adb DEV=3f72a543; export PKG=dev.selfhost.untab.android; export VERSION=1.0.0+1
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"; export ANDROID_HOME=~/Library/Android/sdk
# The device reaches the server through `adb reverse`, so host and device use the same URL.
export PORT=18290 BASE=http://localhost:18290
export HTTPS_PROXY=http://127.0.0.1:18188 HTTP_PROXY=http://127.0.0.1:18188 NO_PROXY=localhost,127.0.0.1,10.0.0.41,10.0.0.115,10.0.0.242
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18188 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18188 -Dhttp.nonProxyHosts=localhost|127.*|10.0.0.41"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18185; export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:18185
export CI=true LANG=en_US.UTF-8; export SB=$CLI/bin/shorebird
export FLUTTER=$CLI/bin/cache/flutter/$FLUTTER_REV/bin/flutter
export LOCK=~/Developer/shorebird-wt/tmp/heavy.lock
. $R/secrets.sh; export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=${API_KEY:-}
lock()   { until mkdir "$LOCK" 2>/dev/null; do sleep 20; done; echo "devrun-c9208259-android pid $$ $(date +%T) $*" > "$LOCK/owner"; }
unlock() { grep -q "pid $$ " "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }; return 0; }
