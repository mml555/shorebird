# Cell 9995f957 (f2458551 with Route B analysis 24; Flutter 3.50, engine 09c6f422, updater 64a458f0) device run for #254 (2026-11-24), CLI 2f0b38a6. Data, logs and evidence live in this directory.
export R=~/Developer/shorebird-wt/devrun/run-9995f957; export CLI=$R/cli; export PATH=/opt/homebrew/bin:$PATH
export CELL=9995f9571ec94b60eca64ec7eaae5fa190285b4d FLUTTER_REV=8e996caeeba7d826cc27397660a996c1e6194d07
export UDID=8cb4bc982ddf6437b1952520edee80f898196c74; export BUNDLE=dev.selfhost.untab; export VERSION=1.0.0+75
export BASE=http://10.0.0.242:18290
export HTTPS_PROXY=http://127.0.0.1:18188 HTTP_PROXY=http://127.0.0.1:18188 NO_PROXY=localhost,127.0.0.1,10.0.0.41,10.0.0.115,10.0.0.242
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18188 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18188 -Dhttp.nonProxyHosts=localhost|127.*"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18185; export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:18185
export CI=true LANG=en_US.UTF-8; export SB=$CLI/bin/shorebird
export FLUTTER=$CLI/bin/cache/flutter/$FLUTTER_REV/bin/flutter
export LOCK=~/Developer/shorebird-wt/tmp/heavy.lock
[ -f $R/../secrets.sh ] && . $R/../secrets.sh; export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=${API_KEY:-}
# heavy.lock (mkdir lock, shared Mac): held around every build, released right after.
lock()   { until mkdir "$LOCK" 2>/dev/null; do sleep 20; done; echo "devrun-9995f957 pid $$ $(date +%T) $*" > "$LOCK/owner"; }
unlock() { grep -q "pid $$ " "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }; return 0; }   # only a lock this script took
