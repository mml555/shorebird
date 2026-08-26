#!/usr/bin/env bash
# cspell:words pkgs
#
# verify_cell_completeness.sh -- does this cell host every engine-hash-addressed
# artifact a release from an EMPTY CACHE needs?
#
# Written for bash 3.2, which is what macOS ships: no `mapfile`.
#
# THE INVARIANT:
#
#   A publishable Route B cell contains every engine-hash-addressed artifact
#   required to perform a release from an empty cache.
#
# WHY THIS IS NOT A HARDCODED LIST. The required set is the CONSUMER's, and the
# consumer is `flutter_cache.dart`. A list maintained here would drift from it
# silently -- which is exactly how sky_engine.zip went missing from four
# published cells while the mint's own header claimed it was cloned. So the list
# is DERIVED from the consumer's source: `getPackageDirs()` for the SDK packages
# and the `_iosBinaryDirs` / FlutterSdk binary dirs for the rest.
#
# If the derivation itself fails, that is a hard error rather than an empty
# required set -- an empty set would make this check pass on any cell at all.
#
#   verify_cell_completeness.sh --hash <cellHash> [--flutter <flutterRepo>]
#
# Exit codes: 0 complete · 1 incomplete · 2 usage/derivation failure.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
FLUTTER=${FLUTTER:-/Volumes/build/route-b/flutter}
HASH=""

usage() { sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --flutter) FLUTTER="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$HASH" ]] || usage

CACHE=$FLUTTER/packages/flutter_tools/lib/src/flutter_cache.dart
[[ -f "$CACHE" ]] || { echo "no flutter_cache.dart at $CACHE" >&2; exit 2; }

DIR="$OVERLAY/flutter_infra_release/flutter/$HASH"
[[ -d "$DIR" ]] || { echo "no cell at $DIR" >&2; exit 2; }

echo "Route B cell completeness"
echo "  cell     : $HASH"
echo "  consumer : $CACHE"
echo

# ---- derive the required set from the consumer ------------------------------
#
# SCOPED to what an iOS RELEASE on macOS arm64 actually activates: FlutterSdk
# (DevelopmentArtifact.universal) and IOSEngineArtifacts (DevelopmentArtifact.iOS).
# A first version grepped every <String>[...] pair in the file and demanded 33
# artifacts including Android and darwin-x64 desktop -- which no iOS release
# fetches, so it reported a usable cell as missing 27 things. Over-collecting is
# as wrong as hardcoding: it makes the check unusable and it would be silenced.
REQ=$(python3 - "$CACHE" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

def cls(name):
    i = src.index(f'class {name} ')
    j = src.find('\nclass ', i + 1)
    return src[i:j if j > 0 else len(src)]

out = []
sdk = cls('FlutterSdk')
# getPackageDirs() -> <hash>/<name>.zip
m = re.search(r"getPackageDirs\(\) => const <String>\[([^\]]*)\]", sdk)
if not m:
    sys.exit('could not derive getPackageDirs')
out += [f"{n.strip().strip(chr(39))}.zip" for n in m.group(1).split(',') if n.strip()]
# FlutterSdk.getBinaryDirs(): the SECOND element of each pair is the URL path.
body = sdk[sdk.index('getBinaryDirs()'):]
for a, b in re.findall(r"<String>\['([^']+)', *'([^']+)'\]", body):
    if 'windows' in b or 'linux' in b or 'x64' in b:
        continue
    out.append(b.replace('darwin-$arch', 'darwin-arm64'))
# The iOS group is a module-level list, not inside the class.
m = re.search(r"_iosBinaryDirs = <List<String>>\[(.*?)\];", src, re.S)
if not m:
    sys.exit('could not derive _iosBinaryDirs')
for a, b in re.findall(r"<String>\['([^']+)', *'([^']+)'\]", m.group(1)):
    out.append(b)
# The Dart SDK is fetched by host platform, not by this table.
out.append('dart-sdk-darwin-arm64.zip')
print('\n'.join(sorted(set(out))))
PY
) || { echo "DERIVATION FAILED — refusing to report a cell complete against an" >&2
       echo "empty required set." >&2; exit 2; }

[[ -n "$REQ" ]] || { echo "DERIVATION produced nothing; refusing." >&2; exit 2; }
echo "required for an iOS release from an empty cache (derived, macOS arm64):"

missing=0
present=0
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  if [[ -f "$DIR/$r" ]]; then
    printf '  ok       %-34s %s\n' "$r" "$(shasum -a 256 "$DIR/$r" | cut -c1-16)"
    present=$((present+1))
  else
    printf '  MISSING  %s\n' "$r"; missing=$((missing+1))
  fi
done <<< "$REQ"

echo
if [[ "$missing" -eq 0 ]]; then
  echo "COMPLETE — $present required artifacts present. A release can be built"
  echo "from an empty cache without borrowing from another engine's hash."
  exit 0
fi
echo "INCOMPLETE — $missing of $((present+missing)) required artifacts absent."
echo
echo "A build from an empty cache CANNOT complete on this cell. It may still"
echo "appear to work on a machine whose cache retained those artifacts from a"
echo "DIFFERENT engine hash, which is the failure this check exists to expose:"
echo "the cache stamp makes it look settled."
exit 1
