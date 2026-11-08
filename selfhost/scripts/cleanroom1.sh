#!/usr/bin/env bash
# cspell:words seatbelt sandboxed pubcache prebuilt getsockname dyld realpath RECPATH cand PREREQ prereq CARRIER tagrev tagcell mlist fprobe FSEL undistributable pyyaml CLIBIN
# SELFHOST-CLEANROOM-1 -- can the supported self-hosted stack be reproduced from
# DURABLE sources, without this development machine's accumulated state?
#
# The question is provenance, not merely "does it work somewhere else". So this
# run does two things a fresh checkout on another machine would not do by
# itself:
#
#   1 it makes the old state PROVABLY UNREADABLE. A macOS Seatbelt profile
#     denies file-read on /Volumes/build, the development checkout, and every
#     inherited cache (~/.shorebird, ~/.pub-cache, ~/.gradle, ~/Library/Caches
#     /flutter). Denial is asserted, per path, before anything else runs --
#     "I did not reference it" is a promise; "the kernel refused" is a proof.
#
#   2 it records every input it needs and where that input can come from, so a
#     missing file is reported as a PRODUCTIZATION DEFECT rather than fetched
#     from the machine that already has it. Nothing here copies from the
#     development tree; the sandbox could not even if it tried.
#
# The ONE injected file is this script. It carries no product bytes: everything
# it runs comes from the clone it makes.
#
#   cleanroom1.sh [--root DIR]
set -uo pipefail
ROOT=${ROOT:-/Volumes/build/cleanroom1}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The identities the supported record names. Hard-coded here ON PURPOSE: this
# script must be able to say "the stack claims X" without reading the
# development checkout, which is exactly what it is denied.
CLI_REPO=https://github.com/mml555/shorebird.git
ENGINE_REPO=https://github.com/mml555/shorebird-flutter.git
CLI_REV=5920a8bf0a992618bfe7d1680c5439abd7a4f55f
FLUTTER_SELECTOR=e64eb0af52e1c43c3b21a39556d789538d0df9b3
CELL=f85251f344600ae08196925a174e9cff8f0ff18e
ANDROID_PRODUCER=f1a59b8a1609c51397601c36d586ad7763d57153
MACOS_IOS_PRODUCER=dfa2b24ac38477f3705ff0357530f33fe09474b8

DEV_CHECKOUT=/Users/mendell/shorebird
DENIED=(
  /Volumes/build
  "$DEV_CHECKOUT"
  "$HOME/.shorebird"
  "$HOME/.pub-cache"
  "$HOME/.gradle"
  "$HOME/Library/Caches/flutter"
)

fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
defect(){ printf '  \033[33mDEFECT\033[0m %s\n' "$1"; DEFECTS+=("$1"); }
DEFECTS=()
PREREQS=()
prereq(){ printf "  \033[36mPREREQ\033[0m %s\n" "$1"; PREREQS+=("$1"); }

mkdir -p "$ROOT"
# EVERY child must start from an allowed directory. This driver is invoked from
# wherever the operator happens to be -- which on this machine is the denied
# development checkout -- and git refuses with "Unable to read current working
# directory: Operation not permitted" because the sandbox will not let it stat
# its own cwd. Inherited cwd is inherited state too.
cd "$ROOT" || { echo "cannot enter $ROOT" >&2; exit 2; }
PROFILE="$ROOT/cleanroom.sb"
LOG="$ROOT/logs"; mkdir -p "$LOG"

note "1 - the Seatbelt profile, and the proof that it bites"
{
  echo '(version 1)'
  echo '(allow default)'
  for d in "${DENIED[@]}"; do echo "(deny file-read* (subpath \"$d\"))"; done
  # Traversal, and nothing more. `file-read*` on a directory subsumes
  # file-read-metadata, so denying the parent volume also denies the stat() that
  # creating anything beneath it requires -- `git clone` failed with "could not
  # create leading directories ... Operation not permitted". Re-allowing
  # METADATA on each ancestor path (not their contents) restores traversal while
  # `ls` of a denied directory still fails, which is what the assertions below
  # actually test.
  a="$ROOT"
  while [[ "$a" != "/" && -n "$a" ]]; do
    echo "(allow file-read-metadata (literal \"$a\"))"
    a=$(dirname "$a")
  done
  # Last match wins in Seatbelt, so the cleanroom is re-allowed after the
  # blanket deny on its parent volume.
  echo "(allow file-read* (subpath \"$ROOT\"))"
} > "$PROFILE"
sed 's/^/    /' "$PROFILE"
box() { sandbox-exec -f "$PROFILE" "$@"; }

for d in "${DENIED[@]}"; do
  [[ -e "$d" ]] || { echo "    (absent on this machine, nothing to deny: $d)"; continue; }
  if box /bin/ls "$d" >/dev/null 2>&1; then
    bad "STILL READABLE inside the sandbox: $d"
  else
    ok "denied: $d"
  fi
done
# The denial must be real and not an artifact of the path being unreadable
# anyway: the same paths must be readable OUTSIDE the sandbox.
outside=0
for d in "${DENIED[@]}"; do
  [[ -e "$d" ]] || continue
  /bin/ls "$d" >/dev/null 2>&1 && outside=$((outside+1))
done
[[ "$outside" -gt 0 ]] && ok "$outside of those paths ARE readable outside the sandbox, so the denial is what stops them" \
                       || bad "none of the denied paths were readable anyway — the control proves nothing"
box /bin/ls "$ROOT" >/dev/null 2>&1 && ok "the cleanroom itself is readable" || bad "the cleanroom is not readable"

note "2 - a fresh HOME, and an environment with nothing inherited"
CR_HOME="$ROOT/home"
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME"
# env -i, then an explicit allowlist. Anything the bootstrap needs beyond this
# is an operator prerequisite and gets recorded as one.
run() { # run a command inside the sandbox with a scrubbed environment
  sandbox-exec -f "$PROFILE" /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$CR_HOME" \
    TMPDIR="$ROOT/tmp" \
    LANG=en_US.UTF-8 TERM=dumb \
    GIT_TERMINAL_PROMPT=0 \
    "$@"
}
mkdir -p "$ROOT/tmp"
run /usr/bin/env | sort | sed 's/^/    /'
for c in .shorebird .pub-cache .gradle; do
  [[ -e "$CR_HOME/$c" ]] && bad "$c already exists in the fresh HOME" || ok "fresh HOME has no $c"
done
# And the fresh HOME must not be a link to the real one.
[[ "$(/usr/bin/stat -f%i "$CR_HOME")" != "$(/usr/bin/stat -f%i "$HOME")" ]] \
  && ok "the fresh HOME is a different inode from the operator's" || bad "HOME was not replaced"

note "3 - clone the durable repositories, anonymously"
# Anonymous on purpose: a stack that needs this machine's credential helper is
# not reproducible by anyone else.
CLONE="$ROOT/shorebird"
if [[ ! -d "$CLONE/.git" ]]; then
  run /usr/bin/git clone --quiet "$CLI_REPO" "$CLONE" > "$LOG/clone_cli.log" 2>&1
fi
if [[ -d "$CLONE/.git" ]]; then
  ok "cloned $CLI_REPO anonymously"
else
  bad "could not clone $CLI_REPO"; sed 's/^/    /' "$LOG/clone_cli.log" | head -5
fi
DEFAULT_BRANCH=$(run /usr/bin/git -C "$CLONE" rev-parse --abbrev-ref HEAD | tr -d '[:space:]')
DEFAULT_HEAD=$(run /usr/bin/git -C "$CLONE" rev-parse HEAD | tr -d '[:space:]')
echo "    a bare clone lands on: $DEFAULT_BRANCH @ $DEFAULT_HEAD"
run /usr/bin/git -C "$CLONE" cat-file -e "$CLI_REV^{commit}" 2>/dev/null \
  && ok "the supported cli_revision is present in the clone" \
  || bad "the supported cli_revision is NOT in the durable repository"
run /usr/bin/git ls-remote "$ENGINE_REPO" > "$ROOT/engine-refs" 2>/dev/null
for rev in "$ANDROID_PRODUCER" "$MACOS_IOS_PRODUCER"; do
  grep -q "^$rev" "$ROOT/engine-refs" \
    && ok "engine producer ${rev:0:12} is advertised by the durable engine repo" \
    || bad "engine producer ${rev:0:12} is NOT advertised by the durable engine repo"
done

note "4 - WHICH REVISION DOES AN OPERATOR CHECK OUT to get the supported record?"
# Three candidate entry points, because the answer turned out not to be
# obvious and the difference between them is a defect.
#
#   the documented pin  — CLAUDE.md says releases are cut as selfhost-vX.Y.Z,
#                         "the whole distribution, the tag users pin"
#   cli_revision        — the revision the record names for the PRODUCT TREE
#   the branch tip      — where the work actually is
#
# They are not the same, and only one of them carries a record that describes
# the current supported stack.
RECPATH=selfhost/engine/route_b/SUPPORTED_STATE.yaml
TAG=$(run /usr/bin/git -C "$CLONE" tag -l 'selfhost-v*' | sort -V | tail -1 | tr -d '[:space:]')
TIP=$(run /usr/bin/git -C "$CLONE" rev-parse "origin/experimental" 2>/dev/null | tr -d '[:space:]')
printf '    %-42s %-14s %s\n' CANDIDATE REVISION "cell_address named there"
CARRIER=""
for cand in "${TAG:-<none>}" "$CLI_REV" "${TIP:-<none>}"; do
  [[ "$cand" == "<none>" ]] && { printf '    %-42s %s\n' "$cand" "(no such ref)"; continue; }
  rev=$(run /usr/bin/git -C "$CLONE" rev-parse "$cand^{commit}" 2>/dev/null | tr -d '[:space:]')
  got=$(run /usr/bin/git -C "$CLONE" show "$rev:$RECPATH" 2>/dev/null \
        | sed -nE 's/^[[:space:]]*cell_address:[[:space:]]*([0-9a-f]{40}).*/\1/p' | head -1)
  printf '    %-42s %-14s %s\n' "$cand" "${rev:0:12}" "${got:-<no record here>}"
  [[ "$got" == "$CELL" ]] && CARRIER="$rev"
done
if [[ -n "$CARRIER" ]]; then
  ok "a revision carrying the current record exists: ${CARRIER:0:12}"
else
  bad "NO reachable revision carries a record naming the supported cell $CELL"
fi
# Is that revision durably NAMEABLE? A mutable branch tip is not an identity.
if [[ -n "$TAG" ]]; then
  tagrev=$(run /usr/bin/git -C "$CLONE" rev-parse "$TAG^{commit}" | tr -d '[:space:]')
  tagcell=$(run /usr/bin/git -C "$CLONE" show "$tagrev:$RECPATH" 2>/dev/null \
            | sed -nE 's/^[[:space:]]*cell_address:[[:space:]]*([0-9a-f]{40}).*/\1/p' | head -1)
  if [[ "$tagcell" == "$CELL" ]]; then
    ok "the documented pin $TAG names the supported cell"
  else
    defect "the documented distribution pin is $TAG, and the record at that tag names ${tagcell:-no cell at all}, not $CELL. There is no immutable ref an operator can pin to obtain the CURRENT supported record -- only the mutable tip of a non-default branch."
  fi
else
  defect "no selfhost-v* tag exists, so there is no documented immutable pin for the distribution at all."
fi
if [[ "$CARRIER" == "$TIP" && -n "$TIP" ]]; then
  prereq "check out origin/experimental (a MUTABLE branch tip) to obtain the current record; \`git clone\` lands on $DEFAULT_BRANCH and the newest selfhost-v* tag is stale."
fi
# From here on the cleanroom reads the record at the CARRIER revision -- the
# only one that describes the stack under test.
[[ -n "$CARRIER" ]] && run /usr/bin/git -C "$CLONE" checkout --quiet --detach "$CARRIER"
STATE="$CLONE/$RECPATH"
[[ -f "$STATE" ]] && ok "the supported-state record is readable in the cleanroom" \
                  || bad "no supported-state record"

note "5 - the cell's 30 members: can a fresh operator OBTAIN them?"
MAN="$CLONE/selfhost/engine/route_b/cell_manifests/$CELL.v2"
if [[ -f "$MAN" ]]; then
  ok "the cell DESCRIPTOR is in the repository (membership and digests are durable)"
else
  bad "the cell descriptor is not in the repository"
fi
mlist=$(awk '$1!="address_schema" && $1!="cell" && $1!="fallback_engine_revision" && NF==2 {print $1}' "$MAN" 2>/dev/null)
MEMBERS=$(printf '%s\n' "$mlist" | grep -c . || true)
OVERLAY="$CLONE/selfhost/cdn/overlay"
present=0; absent=0
while read -r m; do
  [[ -n "$m" ]] || continue
  [[ -f "$OVERLAY/${m//%H/$CELL}" ]] && present=$((present+1)) || absent=$((absent+1))
done < <(printf '%s\n' "$mlist")
echo "    addressed members: $MEMBERS   present in a fresh clone: $present   ABSENT: $absent"
run /usr/bin/git -C "$CLONE" check-ignore -v selfhost/cdn/overlay/x 2>/dev/null | sed 's/^/    gitignore: /'
if [[ "$absent" -gt 0 ]]; then
  defect "$absent of $MEMBERS addressed cell members are absent from a fresh clone. selfhost/cdn/overlay/* is gitignored, the repository publishes no release asset carrying them, and the record names no durable location to fetch them from. The CDN that serves them reads that same local directory, so it is not an independent source."
fi

note "6 - could the missing bytes be REBUILT instead of fetched?"
# If they could, the absence is an inconvenience. If they cannot, the supported
# identity is undistributable, which is a larger and different defect.
echo "    the repository's own statement about the compiler archive:"
grep -h "non-byte-reproducible" \
  "$CLONE/selfhost/engine/route_b/publish_route_b_compiler.sh" \
  "$CLONE/selfhost/engine/route_b/stage_v13_cell.sh" 2>/dev/null \
  | sed 's/^ *#* */      /' | head -4
if grep -qh "non-byte-reproducible" "$CLONE/selfhost/engine/route_b/publish_route_b_compiler.sh" 2>/dev/null; then
  defect "the cell address is a digest over exact bytes and the repository records the Route B compiler archive as non-byte-reproducible, so a rebuild yields a DIFFERENT address. Cell $CELL cannot be re-derived from source -- it can only be distributed as bytes, which makes the previous defect a hard blocker rather than a slow path."
fi

note "7 - the runtime checkout the verifier requires"
# verify_supported_state.sh reads a SHOREBIRD_ROOT: an installed CLI checkout
# with a bootstrapped Flutter. Its default is a path on the qualification
# machine, which this sandbox denies -- so whatever an operator must do to
# create one is a prerequisite, and the default is a defect.
DEF_ROOT=$(sed -nE 's/^ROOT=\$\{SHOREBIRD_ROOT:-([^}]*)\}.*/\1/p' \
  "$CLONE/selfhost/engine/route_b/verify_supported_state.sh" | head -1)
echo "    the verifier's default SHOREBIRD_ROOT is: ${DEF_ROOT:-<not found>}"
if [[ -n "$DEF_ROOT" && "$DEF_ROOT" != /Volumes/build/cleanroom1* && "$DEF_ROOT" == /* ]]; then
  defect "verify_supported_state.sh defaults SHOREBIRD_ROOT to $DEF_ROOT -- an absolute path on the qualification machine. An operator elsewhere must know to override it; nothing in the record says so."
fi
prereq "provide a runtime CLI checkout (SHOREBIRD_ROOT) whose bin/cache/flutter/<selector> is bootstrapped, and whose Flutter engine.version is committed to the supported cell."

note "8 - the tooling the verifier itself needs"
# Discovered the hard way: the cleanroom's first run reported "record is not
# cleanly machine-readable" against a well-formed record, because the system
# python3 has no PyYAML. The verifier now distinguishes "cannot check" from
# "malformed"; the missing module is an operator prerequisite either way.
if run /usr/bin/python3 -c 'import yaml' >/dev/null 2>&1; then
  ok "python3 has PyYAML, so the record's format can actually be checked"
else
  prereq "install PyYAML (pip install pyyaml). The stock macOS python3 has no yaml module, and without it the record's format check cannot run."
  echo "    (the system python3 in this cleanroom has no yaml module)"
fi

note "8b - is the supported FLUTTER SELECTOR obtainable?"
# The record names flutter_selector as the revision the CLI clones. The CLI
# clones it from SHOREBIRD_FLUTTER_GIT_URL, defaulting to
# shorebirdtech/flutter. If that revision is not fetchable from a durable
# remote, the CLI cannot bootstrap at all -- which is what happens below.
FSEL_FOUND=""
for r in "$ENGINE_REPO" https://github.com/shorebirdtech/flutter.git https://github.com/flutter/flutter.git; do
  rm -rf "$ROOT/fprobe"; run /usr/bin/git init -q "$ROOT/fprobe"
  if run /usr/bin/git -C "$ROOT/fprobe" fetch -q --depth 1 "$r" "$FLUTTER_SELECTOR" 2>/dev/null; then
    printf '    %-52s FETCHABLE\n' "$r"; FSEL_FOUND="$r"
  else
    printf '    %-52s not fetchable\n' "$r"
  fi
done
rm -rf "$ROOT/fprobe"
if [[ -n "$FSEL_FOUND" ]]; then
  ok "the Flutter selector is fetchable from $FSEL_FOUND"
else
  defect "the supported flutter_selector $FLUTTER_SELECTOR is not fetchable from ANY durable remote. On the qualification machine it is cloned from file:///…/selfhost/cdn/mirrors/flutter.git, which is gitignored, so the CLI cannot bootstrap anywhere else. This is a hard blocker, not a slow path."
fi

note "9 - can the CLI bootstrap itself in the cleanroom?"
# `bin/shorebird` sources third_party/flutter/bin/internal/shared.sh, which
# clones Flutter and builds a snapshot. Whatever it needs is a prerequisite, and
# running it is the only honest way to enumerate that.
CLIBIN="$CLONE/bin/shorebird"
if [[ -x "$CLIBIN" ]]; then
  run /bin/bash "$CLIBIN" --version > "$LOG/cli_bootstrap.log" 2>&1
  rc=$?
  echo "    exit=$rc"
  tail -12 "$LOG/cli_bootstrap.log" | sed 's/^/    | /'
  if [[ $rc -eq 0 ]]; then
    ok "the CLI bootstrapped from the clone with no inherited state"
  else
    bad "the CLI could not bootstrap in the cleanroom (exit $rc) — logs/cli_bootstrap.log"
    # Name the missing tool if the log says so, rather than guessing.
    grep -oiE "command not found: [a-z0-9_.-]+|[a-z0-9_.-]+: command not found|No such file or directory" \
      "$LOG/cli_bootstrap.log" | sort -u | head -5 | sed 's/^/      missing: /'
  fi
else
  bad "no bin/shorebird in the clone"
fi

note "10 - run the record's own verifier in the cleanroom, and read it honestly"
V="$CLONE/selfhost/engine/route_b/verify_supported_state.sh"
run /bin/bash "$V" > "$LOG/verify.log" 2>&1
grep -E "^  (ok|FAILED|--)" "$LOG/verify.log" | sed 's/^/    /'
tail -2 "$LOG/verify.log" | sed 's/^/    /'
if grep -q "SUPPORTED STATE VERIFIED" "$LOG/verify.log"; then
  ok "SUPPORTED STATE VERIFIED in the cleanroom"
else
  nf=$(grep -c "^  FAILED" "$LOG/verify.log" || true)
  bad "the verifier does not pass in the cleanroom ($nf failed checks) — logs/verify.log"
fi

note "RESULT"
echo "  cleanroom: $ROOT"
if [[ ${#PREREQS[@]} -gt 0 ]]; then
  echo
  echo "  OPERATOR PREREQUISITES ENCOUNTERED (${#PREREQS[@]}):"
  i=1; for d in "${PREREQS[@]}"; do echo "    $i. $d"; i=$((i+1)); done
fi
if [[ ${#DEFECTS[@]} -gt 0 ]]; then
  echo
  echo "  PRODUCTIZATION DEFECTS (${#DEFECTS[@]}):"
  i=1; for d in "${DEFECTS[@]}"; do echo "    $i. $d"; i=$((i+1)); done
fi
echo
if [[ $fail -eq 0 && ${#DEFECTS[@]} -eq 0 ]]; then
  echo "  CLEANROOM REPRODUCIBLE"
else
  echo "  CLEANROOM NOT REPRODUCIBLE: $fail failed check(s), ${#DEFECTS[@]} defect(s)"
  exit 1
fi
