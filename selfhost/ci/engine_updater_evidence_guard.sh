#!/usr/bin/env bash
# Host check for selfhost/engine/route_b/evidence/p16_engine_updater.md.
# cspell:words lstrip finditer
#
# Usage: engine_updater_evidence_guard.sh [--require-engine]
#
# Reads source text only (no engine build, no device, no cargo). Checks:
#   1. compatibility.yaml's updater_revision is the revision VENDOR.md says
#      vendor/updater is.
#   2. download_and_install_patch verifies the signature first and returns on
#      failure, before any download state or network call. Runs on
#      vendor/updater, and on the engine's own updater.rs when the engine
#      checkout is present.
#   3. report_launch_failure [-> record_launch_failure] -> record_boot_failure_for_patch -> record_boot_failure
#      -> mark_bad(BootCrash) is intact, and its C2 control test is live.
#   4. (engine) DEPS pins the same updater revision.
#   5. (engine) the Route B wrong-release branch reports launch failure through
#      a ReportRefusal that really calls ReportLaunchFailure, returns without
#      activating, and the hook is still armed from ApplyPatchToSettings.
#   6. (engine) a Route B build of shell.cc never banks success, and its Shell
#      constructor reports failure for a null VM.
# Checks 4-6 need an engine checkout (ENGINE_SRC, default ~/shorebird-engine/
# flutter-350/engine/src, the Flutter 3.50 tree) at the supported
# engine_revision. Hosted CI has none, so there they are SKIPPED; the final line
# says so and --require-engine turns the skip into exit 2. Exit 1 is a failed
# check.
set -uo pipefail

require_engine=0
[ "${1:-}" = "--require-engine" ] && require_engine=1

ROOT="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
COMPAT="$ROOT/selfhost/compatibility.yaml"
VENDOR="$ROOT/vendor/updater"
ENGINE_SRC="${ENGINE_SRC:-$HOME/shorebird-engine/flutter-350/engine/src}"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

want_updater="$(sed -n 's/^  updater_revision: \([0-9a-f]\{12\}\).*/\1/p' "$COMPAT" | head -1)"
want_engine="$(sed -n 's/^  engine_revision: \([0-9a-f]\{40\}\).*/\1/p' "$COMPAT" | head -1)"
[ -n "$want_updater" ] && [ -n "$want_engine" ] || { echo "FAIL: cannot read updater_revision/engine_revision from $COMPAT" >&2; exit 1; }

# Source-text assertions. Comment-only lines are dropped, braces are matched, so a
# mention in a comment or a call that no longer returns cannot satisfy a check.
PY='
import re, sys
def code(path):
    return "\n".join(l for l in open(path, encoding="utf-8").read().split("\n")
                     if not l.lstrip().startswith("//"))
def block(text, start):
    """Text from the first "{" at/after start to its matching "}"."""
    i = text.index("{", start); d = 0
    for j in range(i, len(text)):
        d += (text[j] == "{") - (text[j] == "}")
        if d == 0: return text[i:j+1]
    raise ValueError("unbalanced")
def fn(text, name):
    m = re.search(r"\bfn " + re.escape(name) + r"\b", text)
    if not m: raise ValueError("fn %s not found" % name)
    return m.start(), block(text, m.start())
def cfn(text, name):
    m = re.search(r"\bvoid " + re.escape(name) + r"\(", text)
    if not m: raise ValueError("function %s not found" % name)
    return m.start(), block(text, m.start())
def cfn_all(text, name):
    """Bodies of every definition of an overloaded C++ function (declarations,
    which reach a ";" before a "{", are skipped)."""
    out = []
    for m in re.finditer(r"\bvoid " + re.escape(name) + r"\(", text):
        b, c = text.find("{", m.start()), text.find(";", m.start())
        if b >= 0 and (c < 0 or b < c): out.append(block(text, m.start()))
    if not out: raise ValueError("function %s not found" % name)
    return out
def route_b_view(text):
    """The text a SHOREBIRD_ROUTE_B=1 build compiles: drops the #if !ROUTE_B
    arms and the #else arms of #if ROUTE_B. Other conditionals keep every arm."""
    keep, stack, out = True, [], []
    for line in text.split("\n"):
        d = line.split("//")[0].strip()
        if d.startswith("#if"):
            arm = {"#if SHOREBIRD_ROUTE_B": True, "#if !SHOREBIRD_ROUTE_B": False}.get(d)
            stack.append([keep, arm]); keep = keep and arm is not False; continue
        if d.startswith("#el") and stack:
            outer, arm = stack[-1]
            if arm is not None:
                if not d.startswith("#else"): raise ValueError("#elif after a ROUTE_B #if")
                stack[-1][1] = arm = not arm
            keep = outer and arm is not False; continue
        if d.startswith("#endif") and stack:
            keep = stack.pop()[0]; continue
        if keep: out.append(line)
    return "\n".join(out)
def need(cond, msg):
    if not cond: print(msg); sys.exit(1)

mode = sys.argv[1]
if mode == "sig":
    t = code(sys.argv[2])
    _, body = fn(t, "download_and_install_patch")
    a = body.find("if let Err(e) = crate::cache::check_patch_signature(")
    need(a >= 0, "no `if let Err(e) = crate::cache::check_patch_signature(` in download_and_install_patch")
    blk = block(body, a)
    need("return Err(e.context(UpdateError::InvalidSignature))" in blk,
         "the failed signature branch no longer returns InvalidSignature")
    need("record_signature_refused(" in blk, "the failed branch no longer tombstones the refusal")
    after = body[a + len(blk):]
    need("record_download_started(" in after and "download_to_path(" in after,
         "record_download_started/download_to_path not found after the signature check")
    need("record_download_started(" not in body[:a] and "download_to_path(" not in body[:a],
         "a download call precedes the signature check")
elif mode == "failure":
    upd, state, life = (code(p) for p in sys.argv[2:5])
    raw = open(sys.argv[2], encoding="utf-8").read()
    _, f = fn(upd, "report_launch_failure")
    # Upstream #455 (in a58774ab) moved the body into record_launch_failure, shared
    # with report_launch_failure_for_patch; follow that one hop, and no further.
    # Only the unfiltered call counts: record_launch_failure(Some(n)) marks nothing
    # unless patch n is the one booting.
    if "record_boot_failure_for_patch(" not in f and "record_launch_failure(None)" in f:
        _, f = fn(upd, "record_launch_failure")
    need("record_boot_failure_for_patch(" in f, "report_launch_failure (or the record_launch_failure it calls) no longer calls record_boot_failure_for_patch")
    _, g = fn(state, "record_boot_failure_for_patch")
    need("self.lifecycle.record_boot_failure(" in g, "record_boot_failure_for_patch no longer calls lifecycle.record_boot_failure")
    _, h = fn(life, "record_boot_failure")
    need("mark_bad(n, BadReason::BootCrash)" in h, "record_boot_failure no longer marks Bad{BootCrash}")
    m = re.search(r"((?:[ \t]*#\[[^\n]*\]\n)*)[ \t]*fn prod_c2_explicit_failure_retires_immediately\b", raw)
    need(m is not None, "C2 control test missing")
    need("#[ignore" not in m.group(1) and "#[test]" in m.group(1), "C2 control test is not a live #[test]")
    _, tb = fn(raw, "prod_c2_explicit_failure_retires_immediately")
    need("report_launch_failure()" in tb and "patch_is_bad(1)" in tb, "C2 control test body no longer asserts the failure retires the patch")
elif mode == "wrong_release":
    t = code(sys.argv[2])
    m = re.search(r"auto ReportRefusal = \[\] ", t)
    need(m is not None, "ReportRefusal lambda not found")
    need("ReportLaunchFailure()" in block(t, m.start()), "ReportRefusal no longer calls ReportLaunchFailure()")
    i = t.find("if (running_id != container.release_build_id)")
    need(i >= 0, "the `running_id != container.release_build_id` test is gone (or rewritten)")
    b = block(t, i)
    k = b.find("ReportRefusal();")
    need(k >= 0, "wrong-release branch does not call ReportRefusal()")
    need(re.match(r"ReportRefusal\(\);\s*return;", b[k:]) is not None, "wrong-release branch does not return right after ReportRefusal()")
    need("Dart_RouteBActivatePatchTraced" not in b, "wrong-release branch activates a patch")
    need(t.find("Dart_RouteBActivatePatchTraced") > i + len(b), "activation no longer comes after the wrong-release branch")
    # 3.50 split it into a two-argument wrapper and the overload that does the
    # work, so any definition may hold the call.
    need(any("InstallRouteBActivationHook(settings, patch_path);" in a for a in cfn_all(t, "ApplyPatchToSettings")),
         "ApplyPatchToSettings no longer arms the Route B hook")
    _, hk = cfn(t, "InstallRouteBActivationHook")
    need("settings.root_isolate_create_callback =" in hk, "the hook no longer registers root_isolate_create_callback")
elif mode == "shell":
    # Read as a Route B build compiles it. 3.47 had a Route B arm in the Shell
    # constructor; 3.50 (upstream #453-#455) reports failure or "paused" there in
    # every build and keeps success out of Route B with #if !SHOREBIRD_ROUTE_B.
    t = route_b_view(code(sys.argv[2]))
    m = re.search(r"\bShell::Shell\(DartVMRef vm,", t)
    need(m is not None, "Shell constructor taking DartVMRef not found")
    ctor = block(t, m.start())
    i = ctor.find("if (!vm_)")
    need(i >= 0 and "ReportLaunchFailure()" in block(ctor, i),
         "Route B Shell constructor no longer reports failure for a null VM")
    need("ReportLaunchSuccess" not in ctor, "Route B Shell constructor banks launch success")
    need("ReportLaunchSuccess" not in t, "a Route B build of shell.cc banks launch success (it must come from Dart)")
'
py() { python3 -I -c "$PY" "$@"; }
chk() { # chk <label> <py args...>
  local label="$1"; shift
  local out; out="$(py "$@" 2>&1)" && ok "$label" || bad "$label: ${out:-python failed}"
}

# 1. vendored revision
vend_rev="$(sed -n 's/.*Source revision: \([0-9a-f]\{40\}\).*/\1/p' "$VENDOR/VENDOR.md" | head -1)"
if [ -z "$vend_rev" ]; then bad "VENDOR.md has no 'Source revision: <40 hex>' line (reworded?)"
elif [ "${vend_rev:0:12}" = "$want_updater" ]; then ok "vendor/updater source revision is $want_updater"
else bad "VENDOR.md source revision '${vend_rev:0:12}' != compatibility.yaml updater_revision '$want_updater'"; fi

# 2, 3. vendored updater
V="$VENDOR/library/src"
chk "vendor: signature verified first, failure returns, before any download" sig "$V/updater.rs"
chk "vendor: report_launch_failure -> record_boot_failure -> Bad{BootCrash}; C2 test live" failure "$V/updater.rs" "$V/cache/updater_state.rs" "$V/cache/lifecycle.rs"

# 4-6. engine checkout
if [ -d "$ENGINE_SRC/flutter" ] && [ "$(git -C "$ENGINE_SRC/flutter" rev-parse HEAD 2>/dev/null)" = "$want_engine" ]; then
  E="$ENGINE_SRC/flutter/third_party/updater/library/src"
  chk "engine: signature verified first, failure returns, before any download" sig "$E/updater.rs"
  chk "engine: report_launch_failure -> record_boot_failure -> Bad{BootCrash}; C2 test live" failure "$E/updater.rs" "$E/cache/updater_state.rs" "$E/cache/lifecycle.rs"
  deps_rev="$(sed -n 's/^  "updater_rev": "\([0-9a-f]*\)".*/\1/p' "$(git -C "$ENGINE_SRC/flutter" rev-parse --show-toplevel)/DEPS" | head -1)"
  [ "${deps_rev:0:12}" = "$want_updater" ] && ok "engine DEPS updater_rev is $deps_rev" ||
    bad "engine DEPS updater_rev '${deps_rev}' != $want_updater"
  chk "engine: wrong-release branch reports failure, returns, hook armed" wrong_release "$ENGINE_SRC/flutter/shell/common/shorebird/shorebird.cc"
  chk "engine: Route B shell.cc never banks success; null VM reports failure" shell "$ENGINE_SRC/flutter/shell/common/shell.cc"
  engine_ran=1
else
  engine_ran=0
fi

if [ "$engine_ran" = 0 ]; then
  echo "SKIPPED: engine checks (4-6 and the engine-side 2-3) did NOT run: no checkout of $want_engine under $ENGINE_SRC. Only vendor/updater was checked." >&2
  [ "$require_engine" = 1 ] && { echo "--require-engine: refusing to pass without the engine tree" >&2; exit 2; }
fi
[ "$fail" = 0 ] || exit 1
exit 0
