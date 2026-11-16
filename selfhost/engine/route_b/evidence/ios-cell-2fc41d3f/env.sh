export R=/Users/mendel/Developer/shorebird-wt/devrun; export CLI=/Users/mendel/Developer/shorebird-wt/devrun/cli; export PATH=/opt/homebrew/bin:$PATH
export UDID=8cb4bc982ddf6437b1952520edee80f898196c74; export BUNDLE=dev.selfhost.untab; export VERSION=1.0.0+33
export BASE=http://10.0.0.115:18290
export HTTPS_PROXY=http://127.0.0.1:18188 HTTP_PROXY=http://127.0.0.1:18188 NO_PROXY=localhost,127.0.0.1,10.0.0.41,10.0.0.115
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=18188 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=18188 -Dhttp.nonProxyHosts=localhost|127.*"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18185; export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:18185
export CI=true LANG=en_US.UTF-8; export SB=$CLI/bin/shorebird
export FLUTTER=$CLI/bin/cache/flutter/5c60356ca635c74696ab737e2d5e77f04d615057/bin/flutter
[ -f $R/secrets.sh ] && . $R/secrets.sh; export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=${API_KEY:-}
