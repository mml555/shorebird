#!/usr/bin/env bash
#
# g41b_define_from_file.sh -- G4.1: is our expansion of `--dart-define-from-file`
# the one Flutter actually compiles with?
#
# WHY THIS EXISTS. `--dart-define-from-file` was declined rather than supported,
# and the reason recorded in the source was sound: Flutter parses `.json` and
# `.env` with its own rules, and reimplementing that parsing to expand the option
# into defines is hand-reconstruction. A wrong expansion is the worst outcome
# this project has: the release's prepass, import kernel and fingerprint would
# all describe a program that is not the one that shipped, and every downstream
# check would agree with itself while being wrong.
#
# The objection is answerable because FLUTTER WRITES DOWN ITS OWN ANSWER.
# `ios/Flutter/Generated.xcconfig` carries `DART_DEFINES=` as base64 `K=V`
# entries (`build_info.dart:396` -> `ios/xcode_build_settings.dart:265`), and
# `flutter build ios --config-only` writes it without building anything: the
# `configOnly` early return is at `ios/mac.dart:375`, AFTER
# `updateGeneratedXcodeProperties` at `:347`. So the toolchain can be asked, in
# seconds, per arm.
#
# So this probe compares two things that must agree:
#
#   OURS     RouteBBuildConfig.fromBuildArgs / DartDefineFromFileExpansion.expand,
#            via probes/expand_defines.dart -- the product code path, not a copy
#   THEIRS   the DART_DEFINES Flutter wrote for that same invocation
#
# TWO CONTROLS, because a comparison that cannot fail is worse than no
# comparison:
#
#   arm 0    an instrument control -- a --dart-define the harness KNOWS the value
#            of must appear in THEIRS. A stale or misread xcconfig fails here,
#            before any arm can report a false agreement.
#   arm 5    a sabotage -- the file is rewritten after Flutter read it, so OURS
#            and THEIRS genuinely differ. The comparator MUST report it. If arm 5
#            passes, every other arm's agreement means nothing.
#
# WHAT IS DELIBERATELY EXEMPT. `FLUTTER_APP_FLAVOR` is compared by nobody here:
# Flutter rewrites it at the xcodebuild stage from the Xcode CONFIGURATION (the
# scheme's own casing) after the xcconfig was written from the CLI token, so the
# two spellings disagree by design -- measured on flavored_app, xcconfig `foo`
# vs shipped kernel `Foo`. And keys present only in THEIRS are not disagreements:
# Flutter injects FLUTTER_VERSION and its siblings into every build.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}
FLUTTER_REV=${FLUTTER_REV:-c15ef6379403a0a55531a058bdb2c8e55bc05c98}
FLUTTER=${FLUTTER:-$HOME/.shorebird/bin/cache/flutter/$FLUTTER_REV/bin/flutter}
FIXTURE=${FIXTURE:-$REPO/selfhost/fixtures/flavored_app}
# `packages/` is a pub WORKSPACE (`pubspec.yaml:5`), so resolution lands in the
# repo root's `.dart_tool/`, not in the package's. Both are checked because a
# non-workspace checkout would have the other one.
PKG_CONFIG=${PKG_CONFIG:-$REPO/.dart_tool/package_config.json}
[ -f "$PKG_CONFIG" ] ||
  PKG_CONFIG=$REPO/packages/shorebird_cli/.dart_tool/package_config.json
EXPAND=$REPO/selfhost/engine/route_b/probes/expand_defines.dart
WORK=${WORK:-$(mktemp -d)}

# The pinned Flutter is stamped with an EXPERIMENTAL engine revision that only
# our own mirror serves. Without this, `flutter build` asks
# download.shorebird.dev for `engine_stamp.json` and takes a 404 -- which arm 0
# catches, but as an instrument failure rather than as the one-line configuration
# mistake it is. Read-only use of `R11`; nothing here reloads or seals it.
export FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else
    echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1))
  fi
}

[ -x "$FLUTTER" ] || die "pinned flutter not found: $FLUTTER"
[ -f "$PKG_CONFIG" ] || die "run 'dart pub get' first; missing $PKG_CONFIG"
[ -d "$FIXTURE/ios" ] || die "fixture has no ios/ tree: $FIXTURE (run prepare_flavored_fixture.sh)"

# A COPY. The committed fixture is claimed and this probe writes define files,
# deletes Generated.xcconfig and runs builds -- none of which may touch it.
APP=$WORK/app
note "copying fixture to $APP"
mkdir -p "$APP"
tar -C "$FIXTURE" -cf - . | tar -C "$APP" -xf -
XCCONFIG=$APP/ios/Flutter/Generated.xcconfig

# THEIRS: ask Flutter, and refuse a stale answer. The xcconfig is deleted first,
# so a build that fails to write it cannot be misread as "no defines".
flutter_defines() { # <buildArg>...
  rm -f "$XCCONFIG"
  ( cd "$APP" && "$FLUTTER" build ios --config-only --no-codesign "$@" ) \
    >"$WORK/flutter.log" 2>&1 || {
      echo "FLUTTER-FAILED"; return 0
    }
  [ -f "$XCCONFIG" ] || { echo "NO-XCCONFIG"; return 0; }
  python3 - "$XCCONFIG" <<'PY'
import base64, sys
for line in open(sys.argv[1]):
    if not line.startswith('DART_DEFINES='):
        continue
    for entry in line.strip()[len('DART_DEFINES='):].split(','):
        if entry:
            print(base64.b64decode(entry).decode())
    break
PY
}

# OURS: the product's own expansion, through the product's own API.
our_defines() { # <buildArg>...
  dart --packages="$PKG_CONFIG" "$EXPAND" "$APP" "$@" 2>&1 || true
}

# The comparison the whole probe exists for. Every key OURS claims must carry
# THEIRS' value. Prints the disagreeing keys, or `agree`.
compare() { # <ours-file> <theirs-file> <section>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
ours_path, theirs_path, section = sys.argv[1], sys.argv[2], sys.argv[3]
EXEMPT = {'FLUTTER_APP_FLAVOR'}
ours = {}
for line in open(ours_path):
    line = line.rstrip('\n')
    if not line.startswith(section + ' '):
        continue
    k, _, v = line[len(section) + 1:].partition('=')
    ours[k] = v
theirs = {}
for line in open(theirs_path):
    line = line.rstrip('\n')
    if not line:
        continue
    k, _, v = line.partition('=')
    theirs[k] = v
bad = sorted(k for k, v in ours.items() if k not in EXEMPT and theirs.get(k) != v)
print(','.join(bad) if bad else 'agree')
PY
}

note "work dir $WORK"

# THE RESTAMP HAZARD, guarded rather than hoped about. The mirror's
# `experimental_hashes.map` fallback has rewritten this cache's stamps mid-build
# before (PARITY.md:1595-1612), and a probe that leaves the shared Flutter cache
# pointing at a different engine would cost the next release, not this run.
FLUTTER_CACHE=$(dirname "$(dirname "$FLUTTER")")/bin/cache
ENGINE_STAMP_BEFORE=$(cat "$FLUTTER_CACHE/engine.stamp" 2>/dev/null || echo missing)
note "engine.stamp before: $ENGINE_STAMP_BEFORE"

# ---------------------------------------------------------------- arm 0
# THE INSTRUMENT CONTROL. Before any expansion is believed, prove the harness is
# reading THIS invocation's xcconfig: a define whose value the harness chose must
# come back. A stale file, a wrong path or a silently-failed build dies here.
note "arm 0 -- instrument control: is the xcconfig this invocation's?"
flutter_defines --dart-define=PROBE_CONTROL=arm0 >"$WORK/theirs0"
check "arm0 flutter ran" "$(grep -c 'FLUTTER-FAILED\|NO-XCCONFIG' "$WORK/theirs0" || true)" "0"
check "arm0 control define present" \
  "$(grep -c '^PROBE_CONTROL=arm0$' "$WORK/theirs0" || true)" "1"
if [ "$fail" -ne 0 ]; then
  echo; echo "INSTRUMENT CONTROL FAILED -- no arm below can mean anything."
  sed -n '1,40p' "$WORK/flutter.log" >&2 || true
  echo "RESULT $pass/$((pass+fail))"; exit 1
fi

# ---------------------------------------------------------------- arm 1
# JSON, including the non-string values that make a hand-rolled parser wrong:
# a number, a bool and a nested object all reach the compiler as Dart toString.
note "arm 1 -- .json, with non-string values"
cat >"$APP/defines.json" <<'JSON'
{"API_URL":"https://api.example.com","RETRIES":7,"BETA":true,"NESTED":{"b":1}}
JSON
flutter_defines --dart-define-from-file=defines.json >"$WORK/theirs1"
our_defines --dart-define-from-file=defines.json >"$WORK/ours1"
check "arm1 file expansion agrees" "$(compare "$WORK/ours1" "$WORK/theirs1" FILE)" "agree"
check "arm1 effective agrees" "$(compare "$WORK/ours1" "$WORK/theirs1" EFFECTIVE)" "agree"
check "arm1 number stringified" \
  "$(grep -c '^FILE RETRIES=7$' "$WORK/ours1" || true)" "1"
check "arm1 nested object stringified" \
  "$(grep -c '^FILE NESTED={b: 1}$' "$WORK/ours1" || true)" "1"

# ---------------------------------------------------------------- arm 2
# .env, where every quoting rule is a chance to be subtly wrong. The `#` inside
# a quoted value must survive; the one after an unquoted value must not.
note "arm 2 -- .env quoting and comments"
cat >"$APP/defines.env" <<'ENV'
# a comment line
PLAIN=value # trailing comment
QUOTED="foo#bar=baz"
SINGLE='sq value'
BACKTICK=`bq value`
EMPTY=
SPACED = spaced
ENV
flutter_defines --dart-define-from-file=defines.env >"$WORK/theirs2"
our_defines --dart-define-from-file=defines.env >"$WORK/ours2"
check "arm2 file expansion agrees" "$(compare "$WORK/ours2" "$WORK/theirs2" FILE)" "agree"
check "arm2 comment stripped from unquoted" \
  "$(grep -c '^FILE PLAIN=value$' "$WORK/ours2" || true)" "1"
check "arm2 hash kept inside quotes" \
  "$(grep -c '^FILE QUOTED=foo#bar=baz$' "$WORK/ours2" || true)" "1"

# ---------------------------------------------------------------- arm 3
# PRECEDENCE. The help text promises --dart-define wins over a file entry with
# the same key. That is the one rule a user is most likely to depend on, and
# getting it backwards produces a patch that compiles a different constant.
note "arm 3 -- --dart-define wins over the file"
cat >"$APP/defines3.json" <<'JSON'
{"K":"from-file","ONLY_FILE":"f"}
JSON
flutter_defines --dart-define-from-file=defines3.json --dart-define=K=from-cli \
  >"$WORK/theirs3"
our_defines --dart-define-from-file=defines3.json --dart-define=K=from-cli \
  >"$WORK/ours3"
check "arm3 effective agrees" "$(compare "$WORK/ours3" "$WORK/theirs3" EFFECTIVE)" "agree"
check "arm3 cli wins" "$(grep -c '^EFFECTIVE K=from-cli$' "$WORK/ours3" || true)" "1"
check "arm3 file-only key survives" \
  "$(grep -c '^EFFECTIVE ONLY_FILE=f$' "$WORK/ours3" || true)" "1"

# ---------------------------------------------------------------- arm 4
note "arm 4 -- two files, later wins"
printf '{"DUP":"first","A":"1"}\n' >"$APP/d4a.json"
printf '{"DUP":"second","B":"2"}\n' >"$APP/d4b.json"
flutter_defines --dart-define-from-file=d4a.json --dart-define-from-file=d4b.json \
  >"$WORK/theirs4"
our_defines --dart-define-from-file=d4a.json --dart-define-from-file=d4b.json \
  >"$WORK/ours4"
check "arm4 effective agrees" "$(compare "$WORK/ours4" "$WORK/theirs4" EFFECTIVE)" "agree"
check "arm4 later file wins" "$(grep -c '^FILE DUP=second$' "$WORK/ours4" || true)" "1"

# ---------------------------------------------------------------- arm 5
# SABOTAGE. Flutter's answer for arm 1 is on disk; rewrite the file underneath it
# so OURS must now differ. A comparator that reports `agree` here is broken, and
# every PASS above would be worthless.
note "arm 5 -- sabotage: the comparator must be able to FAIL"
cat >"$APP/defines.json" <<'JSON'
{"API_URL":"https://SABOTAGED","RETRIES":7,"BETA":true,"NESTED":{"b":1}}
JSON
our_defines --dart-define-from-file=defines.json >"$WORK/ours5"
check "arm5 disagreement detected" \
  "$(compare "$WORK/ours5" "$WORK/theirs1" FILE)" "API_URL"

# ---------------------------------------------------------------- arm 6
# The failure state must stay a failure. A named file that does not exist leaves
# the configuration UNKNOWN, which is not the same as empty and must not
# silently become it.
note "arm 6 -- a missing file still declines"
set +e
dart --packages="$PKG_CONFIG" "$EXPAND" "$APP" \
  --dart-define-from-file=nope.json >"$WORK/ours6" 2>&1
rc=$?
set -e
check "arm6 exit code" "$rc" "3"
check "arm6 names the reason" "$(grep -c '^FAILED: did not find the file' "$WORK/ours6" || true)" "1"

# ---------------------------------------------------------------- arm 7
note "arm 7 -- the shared Flutter cache still points where it did"
check "arm7 engine.stamp unchanged" \
  "$(cat "$FLUTTER_CACHE/engine.stamp" 2>/dev/null || echo missing)" \
  "$ENGINE_STAMP_BEFORE"

echo
echo "RESULT $pass/$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
