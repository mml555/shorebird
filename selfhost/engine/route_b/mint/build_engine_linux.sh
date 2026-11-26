#!/usr/bin/env bash
# build_engine_linux.sh -- the Linux half of an engine mint, run ON ci-build: the Android (arm64, arm, x64)
# and Linux host engine shards of the shorebird-flutter line, per shorebird/ci/shards/linux.json.
# It stands alone (no env file), so the owner can copy just this file to ci-build.
#
#   bash build_engine_linux.sh <flutter-commit>          # PLAN: prints what it would do, touches nothing
#   bash build_engine_linux.sh --run <flutter-commit>    # clone, sync, build, stage
#
# OWNER-RUN. Detach it with the box's step runner, for example:
#   ssh ci-build 'bash /srv/ci-cache/shorebird-engine/run_step.sh build bash /home/oem/build_engine_linux.sh --run <sha>'
#
# Settings (environment, all optional):
#   ENGINE_REPO_URL  git URL to clone      (default https://github.com/mml555/shorebird-flutter.git)
#   TREE             checkout, on / not the cache volume  (default /home/oem/engine-build; reuse an old
#                    synced tree by pointing TREE at it)
#   STAGE_ROOT       where the stage goes  (default /home/oem/engine-stage; the stage is $STAGE_ROOT/<sha>,
#                    which must match LINUX_STAGE_REMOTE in the mint env file)
#   ENV_SH           toolchain env file    (default /srv/ci-cache/shorebird-engine/env.sh)
#   JOBS             ninja jobs            (default 12)
#   NEED_GB          free GB required      (default by tree state: 90, 55 synced, 25 built)
#
# Builds only; uploads nothing. Artifacts are copied to $STAGE_ROOT/<sha>/<dst> with $engine = the
# commit built (the checked-in bin/internal/engine.version is upstream's hash, not ours).
# Dart is built from source (--no-prebuilt-dart-sdk): download_dart_sdk is off, and the host dart-sdk
# artifact must be the Dart fork, not a prebuilt.
# Skips clang_tidy, verify_exported, and the host-desktop/web/linux-arm64 shards (not in a cell).
# Refuses to start while another ninja or gclient runs. nice + ionice, one shard at a time.
set -euo pipefail
RUN=0; [[ "${1:-}" == --run ]] && { RUN=1; shift; }
SHA="${1:?usage: build_engine_linux.sh [--run] <flutter-commit>}"
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || { echo "STOP: $SHA is not a 40-hex commit" >&2; exit 1; }
URL=${ENGINE_REPO_URL:-https://github.com/mml555/shorebird-flutter.git}
R=${TREE:-/home/oem/engine-build}
S=${STAGE_ROOT:-/home/oem/engine-stage}/$SHA
B=$(dirname "${ENV_SH:-/srv/ci-cache/shorebird-engine/env.sh}")
ENV_SH=${ENV_SH:-$B/env.sh}
JOBS=${JOBS:-12}
SHARDS=(android-arm64 android-arm32 android-x64 host)
say() { echo "==> $(date -Is) $*"; }
die() { echo "STOP: $*" >&2; exit 1; }
free_gb() { df -Pk "$1" | awk 'NR==2{print int($4/1048576)}'; }

say "plan: commit $SHA from $URL into $R, stage $S, shards ${SHARDS[*]}, -j$JOBS"
if [[ $RUN == 0 ]]; then echo "PLAN ONLY. Add --run to build."; exit 0; fi

pgrep -x ninja >/dev/null && die "a ninja is already running; one heavy job at a time"
pgrep -f "gclient.py sync" >/dev/null && die "a gclient sync is already running"
# A fresh run needs room for the ~30 GB checkout too; a rerun on a synced tree needs only the builds'
# (~35 GB of out/ dirs); a rerun whose out/ dirs are already built grows them by a few GB at most.
need=90; [[ -d "$R/engine/src/flutter/third_party/dart/.git" ]] && need=55
[[ -f "$R/engine/src/out/android_release/build.ninja" && -f "$R/engine/src/out/host_release/build.ninja" ]] && need=25
need=${NEED_GB:-$need}
mkdir -p "$(dirname "$R")"
if [[ $(free_gb "$(dirname "$R")") -lt $need ]]; then
  # Name the built checkouts beside R, so a short disk points at reusing one rather than at deleting.
  hint=""
  for t in "$(dirname "$R")"/*/engine/src/out/host_release/build.ninja; do
    [[ -f $t ]] || continue
    t=${t%/engine/src/out/host_release/build.ninja}; [[ $t == "$R" ]] && continue
    hint+=" TREE=$t"
  done
  [[ -n $hint ]] && hint="; a built checkout needs only 25 GB, reuse one with:$hint"
  die "need $need GB free for $R (have $(free_gb "$(dirname "$R")"))$hint"
fi

[[ -f $ENV_SH ]] || die "no toolchain env file at $ENV_SH (set ENV_SH)"
# shellcheck disable=SC1090
source "$ENV_SH"
export PATH="$R/engine/src/flutter/third_party/ninja:$PATH"
for t in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
  rustup target list --installed | grep -qx "$t" || die "rust target $t missing: rustup target add $t"
done

if [[ ! -d "$R/.git" ]]; then
  say "clone"
  git clone -q --filter=blob:none --no-checkout "$URL" "$R"
fi
git -C "$R" fetch -q origin "$SHA" 2>/dev/null || git -C "$R" fetch -q origin
git -C "$R" checkout -q --detach "$SHA"
[[ "$(git -C "$R" rev-parse HEAD)" == "$SHA" ]] || die "tree is not at $SHA"
say "tree at $(git -C "$R" log --oneline -1)"

cat > "$R/.gclient" <<EOF2
solutions = [
  {
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
    "name": ".",
    "safesync_url": "",
    "url": "$URL",
    "custom_vars": {
      # gs://shorebird-dart-sdk-prebuilt is private; Dart is built from source.
      "download_dart_sdk": False,
    },
  },
]
EOF2
say "gclient sync"
(cd "$R" && nice -n 10 ionice -c3 gclient sync --no-history --jobs 8 -D)
dart_want=$(sed -nE 's/.*"dart_sdk_revision": "([0-9a-f]{40})".*/\1/p' "$R/DEPS" | head -1)
dart_have=$(git -C "$R/engine/src/flutter/third_party/dart" rev-parse HEAD)
[[ "$dart_want" == "$dart_have" ]] || die "third_party/dart at $dart_have, DEPS wants $dart_want"
say "dart fork ok: $dart_have; $(free_gb "$R") GB free"

J="$R/shorebird/ci/shards/linux.json"
cd "$R/engine/src"
for shard in "${SHARDS[@]}"; do
  # One line per gn_ninja step: out|gn args|ninja targets
  steps=$(python3 -I - "$J" "$shard" <<'PY'
import json, sys
for s in json.load(open(sys.argv[1]))[sys.argv[2]]["steps"]:
    if s["type"] == "gn_ninja":
        print(s["out_dir"] + "|" + " ".join(s["gn_args"]) + "|" + " ".join(s["ninja_targets"]))
PY
)
  while IFS='|' read -r out gnargs targets; do
    [[ -n "$out" ]] || continue
    [[ $(free_gb "$R") -ge 20 ]] || die "under 20 GB free before $shard/$out"
    say "$shard: gn $gnargs -> out/$out"
    # shellcheck disable=SC2086
    ./flutter/tools/gn --no-rbe --no-enable-unittests --no-prebuilt-dart-sdk $gnargs
    # Dart writes dart-sdk/revision in an action ninja never reruns when the Dart tree's HEAD moves
    # (fixed in dart-sdk-shorebird-lineage #9), so an incremental build kept the old label beside new
    # binaries (engine c9a5421c). Removing it makes ninja write it again.
    rm -f "out/$out/dart-sdk/revision"
    say "$shard: ninja -C out/$out $targets"
    # shellcheck disable=SC2086
    nice -n 10 ionice -c3 ninja -C "out/$out" -j"$JOBS" $targets
  done <<<"$steps"
done

say "stage artifacts to $S"
mkdir -p "$S"
python3 -I - "$J" "$S" "$SHA" "${SHARDS[@]}" <<'PY'
import json, os, shutil, sys
j, stage, sha, shards = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
spec = json.load(open(j)); missing = 0
for sh in shards:
    for a in spec[sh]["artifacts"]:
        src = os.path.join("out", a["src"]); dst = os.path.join(stage, a["dst"].replace("$engine", sha))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.exists(src):
            print("MISSING", src); missing += 1; continue
        if a.get("zip"):
            parent, name = os.path.split(src)
            shutil.make_archive(dst[:-4], "zip", parent, name)
        else:
            shutil.copy2(src, dst)
print(f"staged; {missing} missing")
sys.exit(1 if missing else 0)
PY
# shellcheck disable=SC2094
# The staged Dart SDK zips must carry the Dart this tree built: the CLI checks that label, and a stale
# one (engine c9a5421c) is found otherwise only at publish time, after both builds.
python3 -I - "$dart_have" "$S" <<'PY' || die "a staged Dart SDK zip does not carry revision $dart_have"
import glob, os, sys, zipfile
want, root = sys.argv[1], sys.argv[2]
zips = sorted(glob.glob(os.path.join(root, "**", "dart-sdk-*.zip"), recursive=True))
if not zips:
    sys.exit("no dart-sdk-*.zip staged in " + root)
bad = 0
for z in zips:
    with zipfile.ZipFile(z) as f:
        got = f.read("dart-sdk/revision").decode().strip() if "dart-sdk/revision" in f.namelist() else "(no dart-sdk/revision)"
    print(("ok   " if got == want else "BAD  ") + got + "  " + z)
    bad += got != want
sys.exit(1 if bad else 0)
PY
(cd "$S" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
say "BUILD_ENGINE_LINUX_DONE $(wc -l < "$S/SHA256SUMS") files in $S; $(free_gb "$R") GB free"
