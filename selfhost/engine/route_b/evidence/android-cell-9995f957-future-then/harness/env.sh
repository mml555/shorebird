# Cell 9995f957 PHYSICAL ANDROID run for #254 (2026-11-24), CLI 2f0b38a6 (shares run-9995f957/cli). The iOS run is in run-9995f957.
export R=~/Developer/shorebird-wt/devrun/run-9995f957-android; export CLI=$R/cli; export PATH=/opt/homebrew/bin:$PATH
export CELL=9995f9571ec94b60eca64ec7eaae5fa190285b4d FLUTTER_REV=8e996caeeba7d826cc27397660a996c1e6194d07
export ADB=~/Library/Android/sdk/platform-tools/adb DEV=3f72a543; export PKG=dev.selfhost.untab.android; export VERSION=1.0.0+2
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"; export ANDROID_HOME=~/Library/Android/sdk
# The device reaches the server through `adb reverse`, so host and device use the same URL.
export PORT=18290 BASE=http://localhost:18290
export HTTPS_PROXY=http://127.0.0.1:18188 HTTP_PROXY=http://127.0.0.1:18188 NO_PROXY=localhost,127.0.0.1,10.0.0.41,10.0.0.115,10.0.0.242
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18188 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18188 -Dhttp.nonProxyHosts=localhost|127.*|10.0.0.41"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18185; export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:18185
export CI=true LANG=en_US.UTF-8; export SB=$CLI/bin/shorebird
export FLUTTER=$CLI/bin/cache/flutter/$FLUTTER_REV/bin/flutter
export LOCK=~/Developer/shorebird-wt/tmp/heavy.lock
[ -f $R/../secrets.sh ] && . $R/../secrets.sh; export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=${API_KEY:-}
lock()   { until mkdir "$LOCK" 2>/dev/null; do sleep 20; done; echo "devrun-9995f957-android pid $$ $(date +%T) $*" > "$LOCK/owner"; }
unlock() { grep -q "pid $$ " "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }; return 0; }
