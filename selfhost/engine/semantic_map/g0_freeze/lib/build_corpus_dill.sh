#!/usr/bin/env bash
# Build a release dill from a corpus variant, using the FROZEN toolchain.
#   build_corpus_dill.sh <corpus-dir> <out.dill>
set -uo pipefail
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
[[ -x "$OUT/dart-sdk/bin/dart" ]] || { echo "no frozen toolchain at $OUT" >&2; exit 2; }
# A STABLE PATH, NOT A FRESH TEMP DIR. The package_config rootUri is a file://
# URI and is baked into the dill, so building each variant under a different
# mktemp path makes every dill unique and the determinism control fails for a
# reason that has nothing to do with the compiler. Same path every call.
W=${CORPUS_BUILD_DIR:-${TMPDIR:-/tmp}/sm1_corpus_build}

# MUTUAL EXCLUSION ON THE STABLE PATH.
#
# The stable path is required for CROSS-RUN determinism -- the rootUri is baked
# into the dill, so the same source must always build at the same path or the
# frozen release identity could never be re-verified. But a stable path plus
# `rm -rf` is not reentrant, and two concurrent harness runs silently destroy
# each other's work directory. That actually happened: a falsification loop and
# a fresh run overlapped, and the second reported "could not produce base ids"
# for a reason that had nothing to do with the map.
#
# A unique path per run would fix the race and break determinism, so the answer
# is to serialise instead. mkdir is atomic, which is all the lock needs to be.
LOCK="$W.lock"
# ACQUISITION MUST BE PROVEN, NOT INFERRED FROM THE LOCK'S EXISTENCE.
#
# The first version ended the retry loop with `[[ -d "$LOCK" ]] || exit 2`, which
# only shows that SOME lock directory exists -- possibly the one another process
# still holds. That let a contender fall through into the shared work directory
# and, on exit, remove a lock it never owned. `mkdir` succeeding is the only
# evidence of ownership, so that is what is recorded.
#
# The cleanup trap is installed ONLY after acquisition, so a process that never
# got the lock cannot delete another's.
CORPUS_LOCK_TRIES=${CORPUS_LOCK_TRIES:-600}
ACQUIRED=0
for _ in $(seq 1 "$CORPUS_LOCK_TRIES"); do
  if mkdir "$LOCK" 2>/dev/null; then
    ACQUIRED=1
    break
  fi
  sleep 1
done
if [[ "$ACQUIRED" != 1 ]]; then
  echo "could not acquire the corpus build lock at $LOCK after $CORPUS_LOCK_TRIES tries;" \
       "another build holds it. Not touching the shared work directory." >&2
  exit 2
fi
trap 'rm -rf "$W" "$LOCK"' EXIT
rm -rf "$W"
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$1"/*.dart "$W/lib/"
printf '{"configVersion":2,"packages":[{"name":"corpus","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" > "$W/.dart_tool/package_config.json"
rm -f "$2"
"$OUT/dart-sdk/bin/dart" "$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart" \
  --platform "$OUT/vm_platform.dill" --aot \
  --packages "$W/.dart_tool/package_config.json" -o "$2" package:corpus/app.dart
