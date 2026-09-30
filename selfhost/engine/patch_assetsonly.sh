#!/usr/bin/env bash
# cspell:words FLREV rbtest pathlib assetsonly
# Publish an ASSETS-ONLY patch: no Dart code, only the asset bundle.
#
# The point of the whole chain. If the device applies this and the engine's asset
# overlay changes, then an asset fix shipped without any code in the patch — which
# is the shape that works on iOS too, because there is nothing to link.
set -euo pipefail

R=/data/shorebird-engine
FLREV=c15ef6379403a0a55531a058bdb2c8e55bc05c98
export PATH="$R/shorebird/bin:$PATH"
export SHOREBIRD_HOSTED_URL=http://localhost:18080
export FLUTTER_STORAGE_BASE_URL=https://localhost:8443
export SHOREBIRD_STORAGE_BASE_URL=https://localhost:8443
export SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev
export SHOREBIRD_TOKEN="$(cat $R/api_key.txt)"

cd "$R/rbtest"

# Change ONLY an asset. The Dart source is untouched, so any code diff is
# incidental — and --assets-only discards it regardless.
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('assets/probe.json')
d = json.loads(p.read_text())
d['origin'] = 'ASSETS-ONLY-PATCH'
p.write_text(json.dumps(d))
print('probe.json now:', p.read_text())
PY

echo "== patching (assets only, no code) =="
yes | nice -n 10 shorebird patch android \
  --release-version=0.5.0+1 --assets-only --allow-asset-diffs \
  -- --no-tree-shake-icons 2>&1 | tail -25
