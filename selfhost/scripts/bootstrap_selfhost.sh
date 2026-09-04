#!/usr/bin/env bash
# cspell:words armv realpath
# bootstrap_selfhost.sh -- THE supported way to stand up this stack from durable
# sources on a machine that has never seen it.
#
# It CONSTRUCTS state rather than assuming it. Nothing here refers to the
# qualification machine, and every byte it places comes from one of exactly
# three places, named in the output as it goes:
#
#   a durable git remote            the CLI repo, and the Flutter selector
#   the recorded cell distribution  the 30 member bytes (SUPPORTED_STATE.yaml
#                                   names the release and its digests)
#   the operator                    Xcode / Android SDK / Docker, listed by
#                                   PREREQ lines rather than assumed
#
#   bootstrap_selfhost.sh --root DIR [--ref TAG|REV] [--repo URL]
#
# --ref should be an annotated selfhost-v* tag (immutable INTENT -- a tag can be
# force-moved, so the real guarantees are the digests committed in the record).
# It defaults to the newest one
# the remote advertises, because "clone the repo" lands on a branch that is not
# the supported stack.
set -uo pipefail
ROOT=""; REF=""; REPO_URL=https://github.com/mml555/shorebird.git
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?}"; shift 2 ;;
    --ref) REF="${2:?}"; shift 2 ;;
    --repo) REPO_URL="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ROOT" ]] || { echo "usage: bootstrap_selfhost.sh --root DIR [--ref TAG]" >&2; exit 2; }
fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
prereq(){ printf '  \033[36mPREREQ\033[0m %s\n' "$1"; }
rec()  { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\\1/p" "$STATE" | head -1; }

mkdir -p "$ROOT"; ROOT=$(cd "$ROOT" && pwd)
CLONE="$ROOT/shorebird"
RUNTIME="$ROOT/runtime"
DIST="$ROOT/cell-dist"
# THE OVERLAY GOES WHERE BOTH CONSUMERS LOOK. verify_supported_state.sh reads
# cell members from <clone>/selfhost/cdn/overlay, and
# selfhost/cdn/docker-compose.cdn.yaml mounts ./overlay from that same
# directory. A first version of this script hydrated to $ROOT/overlay instead,
# and the cleanroom run failed on "no published compiler archive" -- correctly,
# because the bytes were somewhere neither consumer looks.
OVERLAY="$CLONE/selfhost/cdn/overlay"

note "1 - the distribution ref (annotated tag, immutable intent)"
if [[ -z "$REF" ]]; then
  REF=$(git ls-remote --tags "$REPO_URL" 'selfhost-v*' 2>/dev/null \
        | sed 's|.*refs/tags/||' | grep -v '\^{}' | sort -V | tail -1)
  [[ -n "$REF" ]] && echo "    newest selfhost-v* tag on the remote: $REF" \
                  || bad "the remote advertises no selfhost-v* tag"
fi
echo "    using ref: ${REF:-<none>}"
[[ -n "$REF" ]] || { echo; echo "  BOOTSTRAP FAILED: no ref to start from"; exit 1; }

note "2 - clone the repository at that ref"
if [[ ! -d "$CLONE/.git" ]]; then
  git clone --quiet "$REPO_URL" "$CLONE" || bad "clone failed"
fi
git -C "$CLONE" fetch --quiet --tags origin 2>/dev/null
git -C "$CLONE" checkout --quiet --detach "$REF" 2>/dev/null \
  && ok "checked out $REF ($(git -C "$CLONE" rev-parse --short HEAD))" \
  || bad "could not check out $REF"
STATE="$CLONE/selfhost/engine/route_b/SUPPORTED_STATE.yaml"
[[ -f "$STATE" ]] && ok "the supported-state record is present at that ref" \
                  || { bad "no record at $REF"; echo; echo "  BOOTSTRAP FAILED"; exit 1; }

note "3 - read the identities the record names"
CLI_REV=$(rec cli_revision); SELECTOR=$(rec flutter_selector); CELL=$(rec cell_address)
BUNDLE_SHA=$(rec bundle_sha256); DIST_TAG=$(rec tag)
printf '    %-22s %s\n' cli_revision "$CLI_REV" flutter_selector "$SELECTOR" \
                        cell_address "$CELL" cell_distribution "$DIST_TAG"
for v in CLI_REV SELECTOR CELL BUNDLE_SHA DIST_TAG; do
  [[ -n "${!v}" ]] || bad "the record does not name $v"
done

note "4 - create the runtime CLI checkout at cli_revision"
if [[ ! -d "$RUNTIME/.git" ]]; then
  git clone --quiet "$CLONE" "$RUNTIME" || bad "runtime clone failed"
fi
git -C "$RUNTIME" fetch --quiet origin 2>/dev/null
git -C "$RUNTIME" checkout --quiet --detach "$CLI_REV" 2>/dev/null \
  && ok "runtime checkout at $CLI_REV" || bad "could not check out $CLI_REV"
[[ -z "$(git -C "$RUNTIME" status --porcelain 2>/dev/null)" ]] \
  && ok "runtime checkout is clean" || bad "runtime checkout is dirty"

note "5 - hydrate the cell from the RECORDED durable distribution"
BASEURL="https://github.com/mml555/shorebird/releases/download/$DIST_TAG"
mkdir -p "$DIST"
for f in "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt MANIFEST.sha256 CELL.txt; do
  [[ -s "$DIST/$f" ]] && continue
  curl -fsSL "$BASEURL/$f" -o "$DIST/$f" || bad "could not download $f from $BASEURL"
done
GOT=$(shasum -a 256 "$DIST/cell-$CELL.tar" 2>/dev/null | cut -d' ' -f1)
[[ "$GOT" == "$BUNDLE_SHA" ]] && ok "the bundle matches the digest committed in the record" \
                              || bad "bundle digest $GOT != recorded $BUNDLE_SHA"
if bash "$CLONE/selfhost/scripts/sd1_hydrate_cell.sh" --dist "$DIST" --overlay "$OVERLAY" \
     --cell "$CELL" > "$ROOT/hydrate.log" 2>&1; then
  ok "cell hydrated and verified 30/30 into $OVERLAY"
else
  bad "hydration failed — see $ROOT/hydrate.log"
fi

note "6 - bootstrap the CLI, which fetches the exact Flutter selector"
# The CLI clones Flutter from the fork that carries the selector and then
# resolves engine artifacts. SHOREBIRD_ARTIFACT_ORIGIN points it at the
# operator's own CDN over the overlay hydrated above.
prereq "serve \$ROOT/overlay with the CDN in selfhost/cdn (docker compose -f selfhost/cdn/docker-compose.cdn.yaml up), then set SHOREBIRD_ARTIFACT_ORIGIN to it"
if [[ -n "${SHOREBIRD_ARTIFACT_ORIGIN:-}" ]]; then
  ( cd "$RUNTIME" && ./bin/shorebird --version ) > "$ROOT/cli_bootstrap.log" 2>&1 \
    && ok "the CLI bootstrapped: $(grep -m1 'Flutter • revision' "$ROOT/cli_bootstrap.log")" \
    || bad "the CLI did not bootstrap — see $ROOT/cli_bootstrap.log"
  grep -m1 'Engine • revision' "$ROOT/cli_bootstrap.log" | sed 's/^/    /'
else
  echo "    SHOREBIRD_ARTIFACT_ORIGIN is unset, so the artifact step is skipped."
  echo "    Cloning the selector alone is still checked:"
  FD="$RUNTIME/bin/cache/flutter/$SELECTOR"
  if [[ ! -d "$FD/.git" ]]; then
    git clone --quiet --filter=tree:0 --no-checkout \
      "${SHOREBIRD_FLUTTER_GIT_URL:-https://github.com/mml555/shorebird-flutter.git}" "$FD" 2>/dev/null
    git -C "$FD" -c advice.detachedHead=false checkout --quiet "$SELECTOR" 2>/dev/null
  fi
  [[ "$(git -C "$FD" rev-parse HEAD 2>/dev/null)" == "$SELECTOR" ]] \
    && ok "the Flutter selector fetched and checked out" || bad "could not fetch the selector"
  got=$(git -C "$FD" show "$SELECTOR:bin/internal/engine.version" 2>/dev/null | tr -d '[:space:]')
  [[ "$got" == "$CELL" ]] && ok "and its engine.version selects the recorded cell" \
                          || bad "the selector's engine.version is $got, not $CELL"
fi

note "7 - derive SHOREBIRD_ROOT mechanically, so nothing has to be known"
printf '%s\n' "$RUNTIME" > "$CLONE/selfhost/engine/route_b/.runtime_root"
ok "wrote .runtime_root = $RUNTIME"

note "8 - verify the supported state"
out=$(cd "$CLONE" && bash selfhost/engine/route_b/verify_supported_state.sh 2>&1)
echo "$out" | grep -E "^  (ok|FAILED|--)" | sed 's/^/    /'
echo "$out" | tail -2 | sed 's/^/    /'
echo "$out" | grep -q "SUPPORTED STATE VERIFIED" && ok "SUPPORTED STATE VERIFIED" \
                                                 || bad "the supported state does not verify"

note "RESULT"
printf '  clone    %s\n  runtime  %s\n  overlay  %s\n' "$CLONE" "$RUNTIME" "$OVERLAY"
if [[ $fail -eq 0 ]]; then echo "  BOOTSTRAP COMPLETE"; else echo "  BOOTSTRAP: $fail FAILURE(S)"; exit 1; fi
