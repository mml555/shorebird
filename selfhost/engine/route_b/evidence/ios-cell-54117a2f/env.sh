# Cell 54117a2f device run (2026-11-19). Data, logs and evidence live in this directory; ../ (the a6a4 run) is untouched.
export R=/Users/mendel/Developer/shorebird-wt/devrun/run-54117a2f; export CLI=$R/cli; export PATH=/opt/homebrew/bin:$PATH
export CELL=54117a2fe0510a8cb070faf3f5191542179fb4ce FLUTTER_REV=f4024608592183cbfc27ff404e9fb23e84096f95
export UDID=8cb4bc982ddf6437b1952520edee80f898196c74; export BUNDLE=dev.selfhost.untab; export VERSION=1.0.0+71
export BASE=http://10.0.0.242:18290
export HTTPS_PROXY=http://127.0.0.1:18188 HTTP_PROXY=http://127.0.0.1:18188 NO_PROXY=localhost,127.0.0.1,10.0.0.41,10.0.0.115,10.0.0.242
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18188 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18188 -Dhttp.nonProxyHosts=localhost|127.*"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18185; export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:18185
export CI=true LANG=en_US.UTF-8; export SB=$CLI/bin/shorebird
export FLUTTER=$CLI/bin/cache/flutter/$FLUTTER_REV/bin/flutter
export LOCK=/Users/mendel/Developer/shorebird-wt/tmp/heavy.lock
[ -f $R/../secrets.sh ] && . $R/../secrets.sh; export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=${API_KEY:-}
# heavy.lock (mkdir lock, shared Mac): held around every build, released right after.
lock()   { until mkdir "$LOCK" 2>/dev/null; do sleep 20; done; echo "devrun-54117a2f pid $$ $(date +%T) $*" > "$LOCK/owner"; }
unlock() { grep -q "pid $$ " "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }; return 0; }   # only a lock this script took
