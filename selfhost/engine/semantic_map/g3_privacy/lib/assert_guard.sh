#!/usr/bin/env bash
# cspell:words semantic dill bytecode
# assert_guard.sh -- SM1-G3 (#52) CONFOUND ASSERTION. Must pass before the
# platform-library arm means anything.
#
# THE CONFOUND, and it is recorded in G0's manifest rather than restated here:
# the guard refusing --resolve-private-names-in-library on a platform library is
# UNCOMMITTED-BUT-SHIPPED source. It lives in effective tree 7b04b01b and is
# absent from a clean checkout of 9e8c898a. A gate built from the wrong tree
# makes the platform-library arm pass vacuously, because the refusal never
# fires at all -- and "no platform privacy was granted" is exactly what a
# missing guard looks like from the outside.
#
# So presence is asserted three ways, weakest to strongest:
#   1. the dirty path EXISTS               (existence-guarded: a missing file is
#                                           a hard error, never "absent, correct")
#   2. the refusal TEXT is in that file    (cheap, and can still be a comment)
#   3. the refusal actually FIRES          (a compile that must throw StateError)
# plus an ANTI-VACUITY control proving the body genuinely needs platform privacy,
# so arm 3 cannot pass because the source was harmless.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$HERE/../.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
# DT is overridable so the assertion can be FALSIFIED against a clone of the
# tree with the guard removed, without ever mutating the shared checkout.
# The dart tree's package_config uses RELATIVE rootUris (../pkg/front_end),
# so a clone resolves its own front_end rather than the original's.
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DT/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DT/pkg/dart2bytecode/bin/dart2bytecode.dart"
MANIFEST="$SM/g0_freeze/freeze_manifest.json"
FAILED=0
fail() { echo "  FAILED  $*"; FAILED=1; }
ok()   { echo "  ok      $*"; }

# ---- the confound is READ from G0's record, not restated ------------------
read -r CONF_ID DIRTY EFF < <(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
c = [c for c in m['confounds_recorded'] if c['owner_gate'] == 'SM1-G3']
if len(c) != 1:
    print('NO_SINGLE_G3_CONFOUND - -'); raise SystemExit(0)
d = m['inherited_lineage']['producing_source']['dart']
print(c[0]['id'], d['dirty_paths'][0], d['effective_tree'])
PY
)
echo "  confound (from G0's manifest) : $CONF_ID"
[[ "$CONF_ID" == "PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED" ]] \
  || fail "G0 records no single SM1-G3 confound; got '$CONF_ID'"
echo "  guarded path (from manifest)  : $DIRTY"

[[ "$EFF" == "7b04b01bdc10ec990143257f0d28580571c2122f" ]] \
  && ok "frozen effective tree $EFF" \
  || fail "frozen effective tree is $EFF, not 7b04b01b"

# ---- 1. the file must EXIST ----------------------------------------------
GUARD="$DT/$DIRTY"
if [[ -f "$GUARD" ]]; then
  ok "the guarded source exists ($(wc -c < "$GUARD" | tr -d ' ') bytes)"
else
  fail "$DIRTY is MISSING from the built tree. Every platform-library result
            below would be vacuous, so this is fatal rather than a finding."
  echo "GUARD_PRESENCE=FATAL_MISSING"; exit 2
fi

# ---- 2. the refusal text must be in it -----------------------------------
if grep -q "isScheme('dart')" "$GUARD" && grep -q "which is a platform library" "$GUARD"; then
  ok "the refusal text is present in the guarded source"
else
  fail "the refusal text is absent -- this tree predates the guard"
fi

# ---- 3. the refusal must FIRE, with an anti-vacuity control ---------------
W=${W:-${TMPDIR:-/tmp}}/sm1_g3_guard
rm -rf "$W"; mkdir -p "$W/lib" "$W/.dart_tool"
cat > "$W/lib/app.dart" <<'DART'
library g3app;

class PublicHolder {
  int _hidden = 7;
}

/// gen_kernel refuses a library with no entry point, so the import dill's
/// library carries one. It is never run.
void main() {
  print(PublicHolder()._hidden);
}
DART
printf '{"configVersion":2,"packages":[{"name":"g3app","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" \
  > "$W/.dart_tool/package_config.json"

# The body reaches dart:core's PRIVATE namespace. It compiles only if platform
# privacy was granted, which is the hole the guard closes.
# The body reaches dart:core's PRIVATE namespace and NOTHING ELSE private.
# It must not also touch the app's private members: under flag=dart:core the
# app's namespace is not in scope, so such a body fails on the APP private
# whether or not the guard exists -- which would make arm 3a pass for the wrong
# reason. With only a platform private in it, a guard-less tree COMPILES this
# (the hole P1.1 arm A5 found), so the guard is the only thing refusing it.
cat > "$W/probe.dart" <<'DART'
import 'package:g3app/app.dart';

@pragma('dyn-module:entry-point')
String reach(PublicHolder self) {
  final l = _GrowableList<int>.of(const <int>[1]);
  return '${l.length}${self.hashCode}';
}
DART

( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
    --no-link-platform --packages .dart_tool/package_config.json \
    -o import.dill package:g3app/app.dart ) >/dev/null 2>&1
if [[ ! -s "$W/import.dill" ]]; then
  fail "could not build the import dill, so the anti-vacuity control cannot run
            and arm 3a alone does not establish the guard"
  echo "GUARD_PRESENCE=NOT_PROVEN"; exit 2
fi

compile() { # <name> <flag>
  ( cd "$W" && "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill import.dill --resolve-private-names-in-library "$2" \
      --packages .dart_tool/package_config.json -o "$1.bytecode" probe.dart ) \
    > "$W/$1.log" 2>&1
  echo $? > "$W/$1.rc"
}

compile platform 'dart:core'
compile appscope 'package:g3app/app.dart'
PRC=$(cat "$W/platform.rc"); ARC=$(cat "$W/appscope.rc")

# 3a. the guard fires, and it must be the GUARD that refused -- a StateError
#     naming the platform library, not an ordinary "isn't a type" error.
if [[ "$PRC" != 0 ]] && grep -q "which is a platform library" "$W/platform.log"; then
  ok "the refusal FIRES: flag=dart:core throws the platform-library StateError (rc=$PRC)"
elif [[ "$PRC" != 0 ]]; then
  fail "flag=dart:core failed (rc=$PRC) but NOT with the guard's StateError, so
            something else refused it and the guard is unproven:
            $(grep -m1 -E 'Error|Bad state' "$W/platform.log" | head -c 160)"
else
  fail "flag=dart:core COMPILED (rc=0). The guard did not fire and dart:core's
            private namespace was granted to package source -- P1.1 arm A5's hole,
            open again. Every platform-library arm in this gate is vacuous."
fi

# 3b. ANTI-VACUITY. The same body under an APP library must still fail, and fail
#     on `_GrowableList` -- proving the body really does need platform privacy.
#     Without this, 3a could pass on a body that never needed the grant.
if [[ "$ARC" != 0 ]] && grep -q "_GrowableList" "$W/appscope.log"; then
  ok "anti-vacuity: the same body under an app library fails on _GrowableList,"
  echo "          so it genuinely required dart:core's private namespace"
elif [[ "$ARC" == 0 ]]; then
  fail "anti-vacuity BROKEN: the body compiled under an app-library scope, so it
            never needed platform privacy and 3a proved nothing"
else
  fail "anti-vacuity inconclusive: app-library scope failed for another reason:
            $(grep -m1 -E 'Error|Bad state' "$W/appscope.log" | head -c 160)"
fi

if [[ "$FAILED" == 0 ]]; then
  echo "GUARD_PRESENCE=PROVEN_FIRING"
else
  echo "GUARD_PRESENCE=NOT_PROVEN"
fi
exit "$FAILED"
