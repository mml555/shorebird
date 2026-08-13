#!/usr/bin/env bash
# cspell:words arm64 xcarchive objdump ldur dsym DWARF foldable foldability
# cspell:words stur sturb sturh strb strh stlr stlxr cbnz tbnz ccmp insns mnem
# cspell:words locarg nwrite
#
# assert_result_consumed.sh -- does the caller USE what the patchable call returns?
#
# THE FAILURE THIS EXISTS TO CATCH. Releases 25 through 30 each delivered a patch
# that attached, reported `applied 1/1 targets`, moved BOTH `Function` entry
# points to the same-run `InterpretCall` stub, and loaded the very Function that
# was patched from the very pool slot the call site names -- every one of those
# measured on device -- and the app went on displaying the release's own value.
# Six device runs and five causal attributions were spent inside that gap.
#
# The cause was in the RELEASE's own bytes, in the instruction AFTER the call:
#
#     dda84: ldr  x0, [x0, #0x4a8]   ; pool[0xd4a8] = the patched Function
#     dda88: ldur x30, [x0, #0xf]    ; its unchecked entry, read fresh
#     dda8c: blr  x30                ; the call RUNS -- dispatch is real
#     dda90: add  x0, x27, #0xd, lsl #12
#     dda94: ldr  x0, [x0, #0x488]   ; <- x0 OVERWRITTEN with a pool constant
#     dda98: ret                     ;    which is what the app displays
#
# The release body was `String value() => slot = 'NEW-SET';`. Its result is a
# compile-time constant, so the type-flow analysis substituted that constant at
# the call site. The call is still emitted and still runs -- only its RESULT is
# dead. `vm:never-inline` does not prevent this; it prevents a different thing.
#
# THIS IS THE SECOND TIME. `selfhost/engine/killgate/target.dart` carries the
# same finding from 2026-08-09, in its own words: "the call was still emitted and
# still ran -- its RESULT was simply no longer used, which is visible in the
# disassembly as a `blr` whose r0 nobody reads." The fixture's own comments repeat
# the warning three times. It still recurred, silently, the moment a target body
# was edited to return a constant -- which is why this is now a script and not a
# comment.
#
# WHY IT IS A PRECONDITION AND NOT A DIAGNOSTIC. Like assert_installed_release.sh
# and verify_patchable_release.sh, it reads the SHIPPED BYTES and answers in
# seconds, before any device result is interpreted. A folded call site makes the
# UI blind: no runtime instrument downstream of it can distinguish "the
# interpreter never ran" from "the interpreter ran and its answer was thrown
# away". Run this BEFORE booking the rig, not after.
#
# WHAT IT CANNOT DO. It sees one call site at a time and it sees only what the
# locator finds. "Not located" is therefore its own exit code: a target this
# script cannot find is NOT a target whose result is consumed. That distinction
# is load-bearing -- three separate defects in this investigation were caused by
# a not-measured value being read as a measured zero.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: assert_result_consumed.sh <binary|.app|.xcarchive> [locator]
       assert_result_consumed.sh --selftest   # detector vs known-foldability arms
       assert_result_consumed.sh --corpus     # the six preserved failing releases

locators (default: --fixture-signature):
  --symbol NAME         sites inside the function symbol NAME. Works when the
                        DISASSEMBLED binary carries symbols, which a host
                        app-aot-elf does and a shipped iOS App does not.
  --symbols PATH        resolve --symbol NAME against PATH's symbol table instead
                        (a dSYM's DWARF binary), while still disassembling the
                        target. Required for a shipped App: its dSYM has the Dart
                        symbols but NO code, so pointing --symbol at the dSYM
                        alone reports NOT LOCATED — measured, once, by doing it.
  --pool-offset 0xNNN   sites whose Function is loaded from this pool byte
                        offset. Also the way to RE-DERIVE the offset the
                        .routeb.trace is given -- a stale one silently reads a
                        different pool entry.
  --at 0xADDR           the single site whose `blr` is at ADDR. Use it to name one
                        site out of a caller that has several.
  --fixture-signature   sites preceded by three field initialiser stores at
                        +0x7/+0xf/+0x17, which is how `routeBValue()` appears in
                        a stripped airgap_probe release.

exit: 0 result consumed at every located site
      1 result DISCARDED at a located site (the fold; a patch cannot show)
      2 no site located, or the window was undecidable -- MEASUREMENT
        INCOMPLETE, which is not a pass
      3 usage or environment error
USAGE
  exit 3
}

# ---- selftest ---------------------------------------------------------------
#
# A detector with no negative control is a detector nobody can trust. This builds
# three arms with the host toolchain and asserts the verdict for each, so the
# script proves it can tell the two cases apart before it is believed about a
# release. Arms 1 and 2 differ only in whether the constant arrives by assignment
# or directly -- both fold, which is the point: it is the CONSTANT-ness, not the
# assignment.
selftest() {
  local SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
  local OUT=${OUT:-$SRC/out/host_release_arm64}
  local DART_TREE=$SRC/flutter/third_party/dart
  local DART=$OUT/dart-sdk/bin/dart
  local GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
  local GEN_SNAPSHOT=$OUT/gen_snapshot
  for f in "$DART" "$GEN_SNAPSHOT" "$OUT/vm_platform.dill"; do
    [ -e "$f" ] || { echo "SELFTEST SKIPPED: no host toolchain at $f" >&2; exit 3; }
  done

  local work; work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  local rc=0

  arm() { # $1=name $2=body $3=expected exit code
    local d="$work/$1"; mkdir -p "$d"
    cat > "$d/main.dart" <<DART
class RouteBThing {
  String label = 'NEW-C1';
  String slot = 'UNSET';

  @pragma('vm:never-inline')
  String value() => $2
}

// No vm:entry-point pragma here, deliberately. It makes the compiler emit a
// SECOND body under the same name, so locating by symbol then matches two call
// sites and the gate correctly refuses to collapse them. Nothing in this selftest
// attaches by name -- it reads bytes -- so the pragma bought an ambiguity and
// nothing else. (Before the multi-site check existed, worst-verdict-wins made
// these arms pass with two sites, which is passing by accident.)
//
// NO BACKTICKS IN THIS HEREDOC. It is unquoted so that the body interpolates, so
// backticks are command substitution -- the first draft of this very comment ran
// vm:entry-point as a command. Same defect as the one fixed in
// preserve_release_evidence.sh, caught here by shellcheck SC2215.
@pragma('vm:never-inline')
String routeBValue() => RouteBThing().value();

void main() { print(routeBValue()); }
DART
    ( cd "$d"
      "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
        -o base.dill main.dart >/dev/null
      "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
        --elf=app.aot base.dill )
    local got=0
    "$0" "$d/app.aot" --symbol routeBValue >"$d/out.txt" 2>&1 || got=$?
    if [ "$got" = "$3" ]; then
      echo "  PASS  $1 -> exit $got"
    else
      echo "  FAIL  $1 -> exit $got, expected $3"; sed -n 's/^/        /p' "$d/out.txt"
      rc=1
    fi
  }

  echo "selftest: the detector against bodies whose foldability is known"
  arm shipped_assignment "slot = 'NEW-SET';"                                        1
  arm bare_literal       "'NEW-SET';"                                               1
  arm datetime_routed    "DateTime.now().millisecondsSinceEpoch >= 0 ? slot = 'NEW-SET' : 'X';" 0
  [ "$rc" = 0 ] && echo "SELFTEST PASSED" || echo "SELFTEST FAILED"
  exit "$rc"
}

# ---- corpus -----------------------------------------------------------------
#
# The preserved releases are the runs this detector explains, so they are also the
# only regression test that can prove it still explains them. Needs no toolchain
# and no device: the bytes are in the repo.
#
# EACH SPECIMEN DECLARES ITS OWN EXPECTATION. The first version asserted one
# global expectation -- "folded, at 0xd4a8" -- which was true for every release
# that existed when it was written and became FALSE the moment the fix shipped:
# release 31 is CONSUMED, at 0xd4a0. A corpus that encodes today's answer as a
# universal law fails on the very evidence that proves the fix worked, which is
# the wrong direction for a regression test to point.
#
# Membership is checked BOTH WAYS. A preserved release absent from the table is a
# FAILURE, not a skip: a new specimen must state what it proves. A tabled release
# absent from disk is also a failure, because evidence going missing must never
# read as an empty pass. That collapse -- not-measured masquerading as measured --
# is what the pool counters, the scan states and this script's exit 2 exist to
# prevent.
corpus() {
  local HERE; HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  local dir="$HERE/../../../evidence/releases"
  local n=0 fail=0
  # <release> <expected-exit> <expected-offset> <what it is>
  local TABLE="
25 1 0xd4a8 folded: release body returned one constant
26 1 0xd4a8 folded, and the release the 0xd4a8 offset was measured from
27 1 0xd4a8 folded
28 1 0xd4a8 folded
29 1 0xd4a8 folded
30 1 0xd4a8 folded; the IDENTITY specimen, settled on these frozen bytes
31 0 0xd4a0 CONSUMED: the fixed release body, and the offset moved one slot
32 0 0xd4a0 CONSUMED: adds the private-class target for the G3.6c/G3.6d gate
"
  echo "corpus: preserved releases, each against its own declared expectation"
  for app in "$dir"/*/App; do
    [ -f "$app" ] || continue
    local rel out rc off row want_rc want_off
    rel=$(basename "$(dirname "$app")")
    row=$(printf '%s\n' "$TABLE" | awk -v r="$rel" '$1==r {print; exit}')
    if [ -z "$row" ]; then
      echo "  FAIL  release $rel is preserved but UNDECLARED — add it to the table"
      echo "        with what it is expected to prove; an unexplained specimen is"
      echo "        not a passing one"
      fail=$((fail+1)); n=$((n+1)); continue
    fi
    want_rc=$(printf '%s' "$row" | awk '{print $2}')
    want_off=$(printf '%s' "$row" | awk '{print $3}')
    # `out=$(...); rc=$?` would abort under `set -e` before rc is ever read --
    # the detector's normal answer for a folded release is a nonzero exit.
    if out=$("$0" "$app" --fixture-signature 2>&1); then rc=0; else rc=$?; fi
    off=$(printf '%s' "$out" | sed -n 's/.*pool offset   : \([^ ]*\).*/\1/p' | head -1)
    n=$((n+1))
    if [ "$rc" = "$want_rc" ] && [ "$off" = "$want_off" ]; then
      echo "  PASS  release $rel -> exit $rc at $off   ($(printf '%s' "$row" | cut -d' ' -f4-))"
    else
      echo "  FAIL  release $rel -> exit $rc at ${off:-<none>}; expected exit $want_rc at $want_off"
      fail=$((fail+1))
    fi
  done
  # Every tabled release must be on disk.
  local missing
  while read -r rel _; do
    [ -n "$rel" ] || continue
    [ -f "$dir/$rel/App" ] || { missing="$missing $rel"; }
  done <<< "$(printf '%s\n' "$TABLE" | sed '/^$/d')"
  if [ -n "$missing" ]; then
    echo "  FAIL  declared but not preserved:$missing — evidence went missing, which"
    echo "        is a failure and not an empty pass"
    fail=$((fail+1))
  fi
  echo
  if [ "$fail" = 0 ]; then
    echo "CORPUS PASSED ($n releases)"
    exit 0
  fi
  echo "CORPUS FAILED"
  exit 1
}

[ $# -ge 1 ] || usage
[ "$1" = "--selftest" ] && selftest
[ "$1" = "--corpus" ] && corpus

TARGET="$1"; shift
LOCATOR=--fixture-signature
LOCARG=
SYMSRC=
while [ $# -gt 0 ]; do
  case "$1" in
    --symbol|--pool-offset|--at) LOCATOR="$1"; LOCARG="${2:-}"; [ -n "$LOCARG" ] || usage; shift 2 ;;
    --symbols)              SYMSRC="${2:-}"; [ -n "$SYMSRC" ] || usage; shift 2 ;;
    --fixture-signature)    LOCATOR="$1"; LOCARG=; shift ;;
    *) usage ;;
  esac
done
if [ -n "$SYMSRC" ]; then
  # Accept the .dSYM bundle or the DWARF binary inside it, whichever is handed over.
  [ -d "$SYMSRC" ] && [ -f "$SYMSRC/Contents/Resources/DWARF/App" ] &&
    SYMSRC="$SYMSRC/Contents/Resources/DWARF/App"
  [ -f "$SYMSRC" ] || { echo "ERROR: no symbol source at $SYMSRC" >&2; exit 3; }
fi

# Accept whichever level of the bundle the caller happens to have -- the same
# shapes verify_patchable_release.sh accepts, so the two gates take one argument.
if [ -d "$TARGET" ]; then
  for candidate in \
    "$TARGET/Frameworks/App.framework/App" \
    "$TARGET/Products/Applications/Runner.app/Frameworks/App.framework/App" \
    "$TARGET/Contents/Resources/DWARF/App"; do
    [ -f "$candidate" ] && { TARGET="$candidate"; break; }
  done
fi
[ -f "$TARGET" ] || { echo "ERROR: no binary at $1" >&2; exit 3; }
command -v xcrun >/dev/null || { echo "ERROR: xcrun not found" >&2; exit 3; }

# The disassembly is fetched by the Python below rather than piped in: this
# script's own body arrives on stdin as a heredoc, so a pipe would be silently
# empty -- which the detector reports as NOT LOCATED, i.e. the one failure mode
# that must never be mistaken for a verdict. It was, once, while writing this.
python3 - "$TARGET" "$LOCATOR" "$LOCARG" "$SYMSRC" <<'PY'
import re, subprocess, sys

binary, locator, locarg = sys.argv[1], sys.argv[2], sys.argv[3]
symsrc = sys.argv[4] if len(sys.argv) > 4 else ''

# ---- name -> address range, from a SEPARATE symbol source --------------------
#
# A shipped App.framework binary carries four symbols, none of them Dart's. Its
# dSYM carries every Dart symbol and NO code: `__text` is a header with no
# contents, so disassembling the dSYM yields nothing and the locator reports NOT
# LOCATED. That is measured, not assumed -- it is what happened the first time
# this gate was pointed at a dSYM.
#
# So the name is resolved in the dSYM and the CODE is read from the real binary.
# Both come from the same link, so the addresses correspond; release 26's manual
# procedure ("symbolize routeBValue, disassemble its range") is exactly this, and
# this is that procedure stopped being manual.
symrange = None
if symsrc and locator == '--symbol':
    nm = subprocess.run(['nm', '-n', symsrc], capture_output=True, text=True)
    syms = []
    for line in nm.stdout.splitlines():
        parts = line.split(' ', 2)
        if len(parts) == 3 and parts[0].strip():
            try:
                syms.append((int(parts[0], 16), parts[2].strip()))
            except ValueError:
                pass
    # An exact match first; a Dart method appears as `Class.method`, and the
    # compiler also emits `(#2)` duplicates whose range must not be confused with
    # the primary body.
    hits = [i for i, (_, n) in enumerate(syms)
            if n == locarg or n.endswith('.' + locarg)]
    if not hits:
        print(f"binary : {binary}")
        print(f"RESULT: NOT LOCATED — no symbol matching {locarg!r} in {symsrc}")
        sys.exit(2)
    i = hits[0]
    start = syms[i][0]
    end = syms[i + 1][0] if i + 1 < len(syms) else start + 0x400
    symrange = (start, end, syms[i][1])
    if len(hits) > 1:
        print(f"note   : {len(hits)} symbols matched {locarg!r}; using "
              f"{syms[i][1]} at 0x{start:x}. Others: "
              + ', '.join(f"{syms[h][1]}@0x{syms[h][0]:x}" for h in hits[1:]))

dump = subprocess.run(
    ['xcrun', 'llvm-objdump', '-d', '--no-show-raw-insn', '--print-imm-hex', binary],
    capture_output=True, text=True)
if dump.returncode != 0:
    print(f"ERROR: llvm-objdump failed on {binary}", file=sys.stderr)
    print(dump.stderr.strip()[:400], file=sys.stderr)
    sys.exit(3)

# ---- parse the disassembly -------------------------------------------------
INSN = re.compile(r'^\s*([0-9a-f]+):\s+(\S+)\s*(.*?)\s*$')
SYM  = re.compile(r'^[0-9a-f]+\s+<(.+)>:\s*$')
insns, sym_of = [], {}          # insns[i] = (addr, mnemonic, operands)
cur = None
for line in dump.stdout.splitlines():
    m = SYM.match(line)
    if m:
        cur = m.group(1)
        continue
    m = INSN.match(line)
    if m:
        sym_of[len(insns)] = cur
        insns.append((int(m.group(1), 16), m.group(2), m.group(3)))

if not insns:
    print(f"binary : {binary}")
    print("RESULT: NOT LOCATED — the disassembler produced no instructions.")
    sys.exit(2)

# ---- register liveness, one instruction at a time --------------------------
#
# Deliberately conservative: anything that cannot be decided from the operand
# form is reported UNDECIDED rather than guessed. A wrong "consumed" here would
# license exactly the device run this gate exists to prevent.
STORES   = {'str', 'stur', 'strb', 'sturb', 'strh', 'sturh', 'stp', 'stlr', 'stlxr'}
READONLY = {'cmp', 'cmn', 'tst', 'cbz', 'cbnz', 'tbz', 'tbnz', 'ccmp'}
BRANCH   = {'b', 'br', 'bl', 'blr', 'ret'}
REG = re.compile(r'\b[wx](\d+|zr)\b')

def regs(ops):
    return [r for r in REG.findall(ops.replace('lsl', '').replace('lsr', ''))]

def touches(mnem, ops):
    """Return (reads_x0, writes_x0, undecidable)."""
    if mnem.startswith('b.') or mnem in ('b', 'br'):
        return False, False, True           # control flow left the window
    if mnem in ('bl', 'blr'):
        return False, False, True           # a call may consume or clobber x0
    if mnem == 'ret':
        return True, False, False           # x0 is the return value: consumed
    rs = regs(ops)
    if not rs:
        return False, False, False
    if mnem in STORES or mnem in READONLY:
        return '0' in rs, False, False
    nwrite = 2 if mnem == 'ldp' else 1      # ldp writes both destinations
    writes, reads = rs[:nwrite], rs[nwrite:]
    if '0' in reads:
        return True, False, False           # read before any write: consumed
    return False, '0' in writes, False

WINDOW = 10

def verdict(i):
    """i indexes the `blr x30`. Walk forward until x0's fate is decided."""
    for j in range(i + 1, min(i + 1 + WINDOW, len(insns))):
        _, mnem, ops = insns[j]
        read, write, undecided = touches(mnem, ops)
        if read:      return 'CONSUMED', j
        if write:     return 'DISCARDED', j
        if undecided: return 'UNDECIDED', j
    return 'UNDECIDED', min(i + WINDOW, len(insns) - 1)

# ---- find patchable call sites and where their Function came from ----------
ENTRY = re.compile(r'^x30, \[x(\d+), #0x(7|f)\]$')
LDR_PP = re.compile(r'^x(\d+), \[x27, #(0x[0-9a-f]+)\]$')
LDR_REG = re.compile(r'^x(\d+), \[x(\d+), #(0x[0-9a-f]+)\]$')
ADD_PP = re.compile(r'^x(\d+), x27, #(0x[0-9a-f]+), lsl #12$')

def pool_offset(i, reg):
    """Walk back from the entry-point load to the pool load that produced `reg`.

    Two forms appear: a direct `ldr xR, [x27, #imm]`, and the split form a large
    offset needs -- `add xR, x27, #hi, lsl #12` then `ldr xR, [xR, #lo]`. The
    offset is reassembled rather than assumed: this is the value handed to the
    trace, and a stale one reads a different pool entry without complaining.
    """
    for j in range(i - 1, max(i - 6, -1), -1):
        _, mnem, ops = insns[j]
        if mnem != 'ldr':
            continue
        m = LDR_PP.match(ops)
        if m and m.group(1) == reg:
            return int(m.group(2), 16)
        m = LDR_REG.match(ops)
        if m and m.group(1) == reg and m.group(2) == reg:
            lo = int(m.group(3), 16)
            for k in range(j - 1, max(j - 4, -1), -1):
                _, m2, o2 = insns[k]
                a = ADD_PP.match(o2) if m2 == 'add' else None
                if a and a.group(1) == reg:
                    return (int(a.group(2), 16) << 12) + lo
            return None
    return None

sites = []                                  # (blr_index, pool_offset, entry_off)
for i, (_, mnem, ops) in enumerate(insns):
    if mnem != 'ldur':
        continue
    m = ENTRY.match(ops)
    if not m or i + 1 >= len(insns) or insns[i + 1][1] != 'blr':
        continue
    sites.append((i + 1, pool_offset(i, m.group(1)), '0x' + m.group(2)))

# ---- apply the locator ------------------------------------------------------
STUR_FIELD = re.compile(r'^x(\d+), \[x(\d+), #(0x[0-9a-f]+)\]$')
STR_STACK  = re.compile(r'^x(\d+), \[x15\]$')

def has_field_init_signature(blr_i):
    """`routeBValue()` in a stripped release: allocate a RouteBThing, initialise
    its three fields at +0x7/+0xf/+0x17, push the receiver as argument 0, call.
    Structural because a shipped App.framework binary carries four symbols and
    none of them is Dart's.

    EVERY CLAUSE HERE IS LOAD-BEARING. The first draft asked only "are there
    stores to +0x7, +0xf and +0x17 somewhere in the preceding window", and that
    matched 77 sites per release -- ordinary void calls preceded by unrelated
    field writes -- each contributing a DISCARDED verdict about a call this gate
    was never asked about. A locator that over-matches does not merely add noise:
    it manufactures exactly the finding under test, which is the failure this
    whole investigation has been repeatedly bitten by. So the shape is required
    in full: same base register, ascending offsets, and that same register pushed
    as the receiver before the call.
    """
    base, seen, push_at = None, [], None
    for j in range(max(blr_i - 20, 0), blr_i):
        _, mnem, ops = insns[j]
        if mnem == 'stur':
            m = STUR_FIELD.match(ops)
            if m and int(m.group(3), 16) in (0x7, 0xf, 0x17):
                if base is None:
                    base = m.group(2)
                if m.group(2) == base:
                    seen.append(int(m.group(3), 16))
        elif mnem == 'str' and base is not None:
            m = STR_STACK.match(ops)
            if m and m.group(1) == base and len(seen) == 3:
                push_at = j
    return seen == [0x7, 0xf, 0x17] and push_at is not None

if locator == '--symbol' and symrange:
    lo, hi, resolved = symrange
    picked = [s for s in sites if lo <= insns[s[0]][0] < hi]
    what = f"symbol {resolved} at 0x{lo:x}-0x{hi:x} (resolved in {symsrc})"
elif locator == '--symbol':
    picked = [s for s in sites if sym_of.get(s[0]) == locarg]
    what = f"symbol {locarg}"
elif locator == '--at':
    want = int(locarg, 16)
    picked = [s for s in sites if insns[s[0]][0] == want]
    what = f"the site at {locarg}"
elif locator == '--pool-offset':
    want = int(locarg, 16)
    picked = [s for s in sites if s[1] == want]
    what = f"pool offset {locarg}"
else:
    picked = [s for s in sites if has_field_init_signature(s[0])]
    what = "fixture signature (three field initialisers, then a call)"

print(f"binary          : {binary}")
print(f"patchable sites : {len(sites):,} in the whole binary")
print(f"locator         : {what}")
print(f"located         : {len(picked)}")
print()

if not picked:
    print("RESULT: NOT LOCATED")
    print()
    print("No call site matched the locator, so nothing was measured. This is NOT")
    print("a pass: a target whose call site cannot be found is a target whose")
    print("result-consumption is UNKNOWN. Check the locator before reading any")
    print("device result — with --symbol, confirm the binary carries Dart symbols")
    print("(a shipped App does not; its dSYM does).")
    sys.exit(2)

# MULTIPLE SITES MUST NOT COLLAPSE TO THE WORST ONE.
#
# A caller with several patchable calls -- read a value, read another, then call a
# void method -- legitimately discards the void call's result, and "worst verdict
# wins" reports that as the fold. Measured: `_ProbeBodyState._routeBRead` in release
# 32 has three sites, two storing their result into a field and one calling
# `setState`, which returns void. Collapsing them produced RESULT DISCARDED for a
# release whose targets are both consumed -- a false fold report from the very gate
# built to stop false attributions.
#
# So a DISCARDED verdict is only claimed when the located set IS the site in
# question. More than one site is AMBIGUOUS: every verdict is printed, and the exit
# is 2 (measurement incomplete), never 1.
if len(picked) > 1:
    print(f"{len(picked)} sites matched this locator. Verdicts, in address order:")
    print()
    for blr_i, off, entry in picked:
        addr, _, _ = insns[blr_i]
        v, at = verdict(blr_i)
        offs = f"0x{off:x}" if off is not None else "not derivable"
        print(f"site 0x{addr:x}   pool offset {offs}   entry {entry}   {v}")
        for j in range(blr_i, min(at + 1, len(insns))):
            a, m, o = insns[j]
            print(f"      {a:>8x}: {m:<6} {o}")
        print()
    print("RESULT: AMBIGUOUS — more than one call site matched, so no single verdict")
    print("is claimed. A void call discards its result legitimately, and a caller")
    print("with several calls will always contain one. Name the site you mean:")
    print()
    print("    --at 0x<address of the blr>        (from the list above)")
    print("    --pool-offset 0x<offset>           (if you know the target's slot)")
    print()
    print("This is measurement incomplete, not a pass and not a fold.")
    sys.exit(2)

worst = 0
for blr_i, off, entry in picked:
    addr, _, _ = insns[blr_i]
    v, at = verdict(blr_i)
    offs = f"0x{off:x}" if off is not None else "not derivable"
    print(f"site 0x{addr:x}  ({sym_of.get(blr_i) or 'no symbol'})")
    print(f"  pool offset   : {offs}   entry offset: {entry}"
          f"  ({'unchecked' if entry == '0xf' else 'checked'})")
    for j in range(blr_i, min(at + 1, len(insns))):
        a, m, o = insns[j]
        print(f"      {a:>8x}: {m:<6} {o}")
    print(f"  VERDICT       : {v}")
    print()
    worst = max(worst, {'CONSUMED': 0, 'DISCARDED': 1, 'UNDECIDED': 2}[v])

if worst == 0:
    print("RESULT: RESULT CONSUMED — a patch's return value can reach the app.")
    sys.exit(0)

if worst == 2:
    print("RESULT: UNDECIDED — the instructions after the call did not settle")
    print("whether x0 is read. Widen the window or read the site by hand; do not")
    print("treat this as a pass.")
    sys.exit(2)

print("RESULT: RESULT DISCARDED — THE CALL SITE IGNORES WHAT THE CALL RETURNS.")
print()
print("The release body of this target returns a compile-time constant, so the")
print("type-flow analysis substituted that constant at the call site. The call")
print("still runs and Route B's dispatch still works; the returned value is dead")
print("before it can be observed. A patch against this release CANNOT change what")
print("the app displays, and no runtime trace downstream can tell you why.")
print()
print("Remedy — make the RELEASE body opaque to constant propagation, which is")
print("the idiom every other target in the fixture already uses:")
print()
print("    @pragma('vm:never-inline')")
print("    String value() =>")
print("        DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-rel' : 'X';")
print()
print("`vm:never-inline` does NOT cover this: it stops the body being spliced")
print("into the caller, not the RESULT being replaced. See")
print("selfhost/engine/killgate/target.dart, which recorded the same finding on")
print("2026-08-09, and releases 25-30, which repeated it.")
sys.exit(1)
PY
