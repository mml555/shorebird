#!/usr/bin/env bash
# build_engine_mac.sh -- the Mac half of an engine mint: the iOS, macOS and Android-on-Darwin engine
# shards of the shorebird-flutter line (shorebird/ci/shards/macos.json), then the framework and
# gen_snapshot packaging (shorebird/ci/compose.json). The Linux half is build_engine_linux.sh on
# ci-build. Both must build the same commit E, because $engine in every artifact path is that commit.
#
#   MINT_ENV=<env file> bash build_engine_mac.sh              # PLAN: checks the tree, prints the steps
#   MINT_ENV=<env file> bash build_engine_mac.sh --run        # build, stage, write SHA256SUMS
#   MINT_ENV=<env file> bash build_engine_mac.sh --run --stage-only   # restage what an earlier run built
#   SHARDS="ios mac-arm64" ...                                # a subset; compose steps whose shards ran
#
# Tree: MAC_TREE, already synced to E (bin/sync). This checks that it is at E, clean, and that
# third_party/dart is the revision DEPS pins. It does not sync. Builds only; uploads nothing.
# Artifacts go to $MAC_STAGE/<dst>, beside a SHA256SUMS, for publish_engine.sh to read.
# Dart is built from source (--no-prebuilt-dart-sdk), as on Linux. Holds the shared heavy lock for the
# whole run (one heavy job at a time on this Mac), nice'd, -j6, under caffeinate.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env
RUN=0; STAGE_ONLY=0
for a in "$@"; do case "$a" in --run) RUN=1;; --stage-only) STAGE_ONLY=1;; *) die "usage: $0 [--run] [--stage-only]";; esac; done
T=${MAC_TREE:?set MAC_TREE=<engine checkout, synced to E> in $MINT_ENV}
ENV_SH=${MAC_ENV_SH:-$HOME/shorebird-engine/env.sh}
S=$MAC_STAGE
JOBS=${JOBS:-6}
read -r -a SHARDS <<<"${SHARDS:-android ios ios-debug ios-profile mac-arm64 mac-x64 mac-arm64-debug mac-arm64-profile mac-x64-debug mac-x64-profile}"
free_gb() { df -Pk "$1" | awk 'NR==2{print int($4/1048576)}'; }

[[ -d $T/.git ]] || die "MAC_TREE=$T is not a git checkout"
[[ -f $ENV_SH ]] || die "no toolchain env file at $ENV_SH (set MAC_ENV_SH)"
# shellcheck disable=SC1090
source "$ENV_SH"
export PATH="$T/engine/src/flutter/third_party/ninja:$PATH"
[[ "$(git -C "$T" rev-parse HEAD)" == "$E" ]] || die "$T is at $(git -C "$T" rev-parse HEAD), not $E"
[[ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]] || die "$T has local changes"
dart_want=$(sed -nE 's/.*"dart_sdk_revision": "([0-9a-f]{40})".*/\1/p' "$T/DEPS" | head -1)
dart_have=$(git -C "$T/engine/src/flutter/third_party/dart" rev-parse HEAD)
[[ "$dart_want" == "$dart_have" ]] || die "third_party/dart at $dart_have, DEPS wants $dart_want: sync the tree"
[[ "$dart_have" == "$DART" ]] || die "DEPS pins Dart $dart_have but the env file says DART=$DART"
for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed | grep -qx "$t" || die "rust target $t missing: rustup target add $t"
done

J="$T/shorebird/ci/shards/macos.json"; C="$T/shorebird/ci/compose.json"
# One line per gn_ninja/shell step: shard|type|out|gn args|ninja targets or command
plan() {
  python3 -I - "$J" "${SHARDS[@]}" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
for sh in sys.argv[2:]:
    if sh not in spec: sys.exit(f"no shard {sh} in macos.json")
    for s in spec[sh]["steps"]:
        if s["type"] == "gn_ninja":
            gn = list(s["gn_args"])
            # 32-bit Android: lib/snapshot's Shorebird create_macos_analyze_snapshots needs analyze_snapshot in
            # the mac host toolchains, which Dart defines only for 64-bit targets unless asked.
            if "--android" in gn and not any(a.startswith("--android-cpu") for a in gn):
                gn.append("--gn-args=build_analyze_snapshot=true")
            print("|".join([sh, "gn_ninja", s["out_dir"], " ".join(gn), " ".join(s["ninja_targets"])]))
        elif s["type"] == "shell":
            print("|".join([sh, "shell", "", "", s.get("script") or s["command"]]))
PY
}
# Compose steps whose required shards all ran: name|script|args (paths under out/)|dst
compose() {
  python3 -I - "$C" "${SHARDS[@]}" <<'PY'
import json, sys
spec, ran = json.load(open(sys.argv[1])), set(sys.argv[2:])
for name, c in spec.items():
    if not set(c["requires"]) <= ran: continue
    dst = c.get("dst", "release")
    args = list(c.get("flags", [])) + [f"{k} out/{v}" for k, v in c.get("path_args", {}).items()]
    print("|".join([name, c["script"], " ".join(args), dst]))
PY
}
say "tree $T at $(git -C "$T" log --oneline -1)"
say "dart $dart_have; $(free_gb "$HOME") GB free; shards: ${SHARDS[*]}; stage $S"
plan | sed 's/^/    step /'
compose | sed 's/^/    compose /'
[[ $RUN == 1 ]] || { echo "PLAN ONLY. Add --run to build."; exit 0; }

if [[ $STAGE_ONLY == 0 ]]; then
  take_heavy_lock "build_engine_mac"
  cd "$T/engine/src"
  while IFS='|' read -r shard type out gnargs targets; do
    [[ $(free_gb "$HOME") -ge 20 ]] || die "under 20 GB free before $shard/$out"
    if [[ "$type" == shell ]]; then
      say "$shard: shell $targets"
      caffeinate -i bash -c "$targets"
      continue
    fi
    say "$shard: gn $gnargs -> out/$out"
    # tools/gn turns --no-enable-unittests into dart_dynamic_modules = false, overriding
    # --dart-dynamic-modules, which Route B steps need (an assert in shell/common/shorebird/BUILD.gn).
    nounit=--no-enable-unittests
    [[ " $gnargs " == *" --dart-dynamic-modules "* ]] && nounit=
    # shellcheck disable=SC2086
    ./flutter/tools/gn --no-rbe $nounit --no-prebuilt-dart-sdk $gnargs
    [[ -f "out/$out/args.gn" ]] || die "gn did not write out/$out (shard $shard); the out_dir in macos.json and gn's name disagree"
    # Dart writes dart-sdk/revision in an action ninja never reruns when the Dart tree's HEAD moves
    # (fixed in dart-sdk-shorebird-lineage #9), so an incremental build kept the old label beside new
    # binaries (engine c9a5421c). Removing it makes ninja write it again.
    rm -f "out/$out/dart-sdk/revision"
    say "$shard: ninja -C out/$out $targets"
    # shellcheck disable=SC2086
    caffeinate -i nice -n 10 ninja -C "out/$out" -j"$JOBS" $targets
  done < <(plan)

  while IFS='|' read -r name script args dst; do
    say "compose $name: $script $args --dst out/$dst"
    # shellcheck disable=SC2086
    python3 "$script" $args --dst "out/$dst"
  done < <(compose)
fi
cd "$T/engine/src"

say "stage artifacts to $S"
mkdir -p "$S"
python3 -I - "$J" "$C" "$S" "$E" "${SHARDS[@]}" <<'PY'
import json, os, shutil, sys
j, c, stage, sha, shards = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
spec, comp = json.load(open(j)), json.load(open(c))
items = [(os.path.join("out", a["src"]), a) for sh in shards for a in spec[sh].get("artifacts", [])]
items += [(os.path.join("out", "release", a["src"]), a) for e in comp.values()
          if set(e["requires"]) <= set(shards) for a in e["artifacts"]]
missing = 0
for src, a in items:
    dst = os.path.join(stage, a["dst"].replace("$engine", sha))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(src):
        print("MISSING", src); missing += 1; continue
    if a.get("zip"):
        parent, name = os.path.split(src)
        shutil.make_archive(dst[:-4], "zip", parent, name)
    else:
        shutil.copy2(src, dst)
print(f"staged {len(items) - missing}; {missing} missing")
sys.exit(1 if missing else 0)
PY
# An AppleDouble file in the stage would end up in the overlay. Refuse here, before SHA256SUMS can hide it.
[[ -z "$(find "$S" -name '._*' -print -quit)" ]] || die "AppleDouble (._*) files in $S"
# shellcheck disable=SC2094
(cd "$S" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
say "BUILD_ENGINE_MAC_DONE $(wc -l < "$S/SHA256SUMS" | tr -d ' ') files in $S; $(free_gb "$HOME") GB free"
