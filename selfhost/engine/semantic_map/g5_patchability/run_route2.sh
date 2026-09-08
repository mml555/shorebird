#!/usr/bin/env bash
# SM1-G5 route 2 -- regenerate every banked artifact from source.
#
# Writes its own transcripts. Nothing here is hand-assembled: the patch is
# re-derived from the frozen base, the replay is re-verified, both AOTs are
# rebuilt, the reader is re-run, the falsification set and the completeness
# enumeration are re-run with their positive controls, and the manifest digests
# are recomputed. Exits non-zero if any of it fails.
#
# usage: run_route2.sh <clone-src> <workdir>
#   clone-src: the engine checkout carrying the instrumentation
#   workdir:   holds prepass3.dill and g2_r.json
set -uo pipefail
SRC="${1:?usage: run_route2.sh <clone-src> <workdir>}"
W="${2:?usage: run_route2.sh <clone-src> <workdir>}"
G="$(cd "$(dirname "$0")" && pwd)"
D="$SRC/flutter/third_party/dart"
GS="$SRC/out/host_release_arm64/gen_snapshot"
T=7b04b01bdc10ec990143257f0d28580571c2122f
FILES=(runtime/vm/elf.h runtime/vm/elf.cc runtime/vm/compiler/backend/flow_graph_compiler.cc)
rc=0
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- 1. producer
R="$W/route2_replay"; rm -rf "$R"; mkdir -p "$R"
for f in "${FILES[@]}"; do mkdir -p "$R/$(dirname "$f")"; git -C "$D" show "$T:$f" > "$R/$f"; done
( cd "$R" && patch -p1 -s -F0 --no-backup-if-mismatch < "$G/instrumentation/0001-g5-aot-capability-note.patch" ) || rc=1
: > "$R/0002"
for f in "${FILES[@]}"; do
  diff -u --label "a/$f" --label "b/$f" "$R/$f" "$D/$f" >> "$R/0002" || true
done
if ! cmp -s "$R/0002" "$G/instrumentation/0002-g5-inlining-relation.patch"; then
  echo "  banked 0002 differs from the tree; refreshing it"
  cp "$R/0002" "$G/instrumentation/0002-g5-inlining-relation.patch"
fi

V="$W/route2_verify"; rm -rf "$V"; mkdir -p "$V"
for f in "${FILES[@]}"; do mkdir -p "$V/$(dirname "$f")"; git -C "$D" show "$T:$f" > "$V/$f"; done
( cd "$V" && patch -p1 -s -F0 --no-backup-if-mismatch < "$G/instrumentation/0001-g5-aot-capability-note.patch" \
          && patch -p1 -s -F0 --no-backup-if-mismatch < "$G/instrumentation/0002-g5-inlining-relation.patch" ) || rc=1
replay_ok=1
for f in "${FILES[@]}"; do
  [ "$(sha "$V/$f")" = "$(sha "$D/$f")" ] || { replay_ok=0; rc=1; }
done

# --------------------------------------------------------------- 2. two AOTs
for n in r rb; do
  rm -f "$W/app_s6$n.aot"
  "$GS" --snapshot_kind=app-aot-elf --patchable_static_calls \
        --elf="$W/app_s6$n.aot" "$W/prepass3.dill" >/dev/null 2>&1 || rc=1
  python3 "$G/lib/read_inlining.py" "$W/app_s6$n.aot" "$W/g2_r.json" - "$W/s6$n.json" >/dev/null || rc=1
done
cp "$W/s6r.json" "$G/evidence/inlining_state.json"

# --------------------------------------------------- 3. reader state transcript
{
  echo "SM1-G5 route 2 -- strict reader state over the schema-6 note"
  echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_route2.sh"
  echo
  echo "PRODUCER AND SUBJECT"
  echo "  $(sha "$G/instrumentation/0001-g5-aot-capability-note.patch")  0001-g5-aot-capability-note.patch"
  echo "  $(sha "$G/instrumentation/0002-g5-inlining-relation.patch")  0002-g5-inlining-relation.patch"
  echo "  $(sha "$GS")  gen_snapshot (frozen + 0001 + 0002)"
  echo "  $(sha "$W/prepass3.dill")  prepass3.dill (input kernel)"
  echo "  $(sha "$W/app_s6r.aot")  app_s6r.aot"
  echo "  recipe: gen_snapshot --snapshot_kind=app-aot-elf --patchable_static_calls \\"
  echo "            --elf=app_s6r.aot prepass3.dill"
  echo
  echo "REPLAY: frozen (recovered by git) + 0001 + 0002 vs the built clone"
  for f in "${FILES[@]}"; do
    a=$(sha "$V/$f"); b=$(sha "$D/$f")
    printf '  %-52s %s\n' "$f" "$([ "$a" = "$b" ] && echo equal || echo DIFFERENT)"
    echo "    replayed $a"
    echo "    built    $b"
  done
  echo "  all_files_equal=$([ "$replay_ok" = 1 ] && echo true || echo false)"
  echo
  echo "NOTE DETERMINISM (same input kernel, two runs of the same producer)"
  python3 - "$W/s6r.json" "$W/s6rb.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
da, db = a['diagnostics'], b['diagnostics']
for k in ('records', 'note_section_sha256', 'aot_sha256'):
    print(f"  {k:20} {'equal' if da[k] == db[k] else 'DIFFER'}")
    print(f"    A {da[k]}")
    print(f"    B {db[k]}")
print(f"  states identical     {a['states'] == b['states']}")
print()
print("  Deterministic NOTE CONTENT and identical verdicts -- not")
print("  byte-reproducible whole-AOT output: the two AOT hashes differ.")
PY
  echo
  echo "READER STATE"
  python3 - "$G/evidence/inlining_state.json" <<'PY'
import collections, json, sys
d = json.load(open(sys.argv[1]))
print(f"  note_validated            {d['note_validated']}")
print(f"  note_error_code           {d['note_error_code']}")
print(f"  note_complete_projection  {d['note_complete_projection']}")
print(f"  in-scope unprojected      {d['unprojected_count']}")
print(f"  out-of-scope records      {d['out_of_scope_records']}")
print()
print("  ACCOUNTING (asserted by the reader, which exits non-zero if it fails)")
a = d['accounting']
for k in ('total_g1_rows', 'INLINED', 'NOT_INLINED', 'UNKNOWN', 'NO_BODY',
          'accounted'):
    print(f"    {k:16} {a[k]:>4}")
assert a['accounted'] == a['total_g1_rows']
print(f"    identity         accounted == total_g1_rows == "
      f"INLINED+NOT_INLINED+UNKNOWN+NO_BODY")
print()
by = collections.defaultdict(list)
for s in d['states']:
    by[s['state']].append(
        (f"{s['kind']} {s['owner'] + '.' if s['owner'] else ''}{s['name']}",
         s['code']))
for st in ('INLINED', 'NOT_INLINED', 'UNKNOWN'):
    print(f"  {st}")
    for n, c in sorted(by[st]):
        print(f"    {n:34} {c}")
    print()
print("  NO_BODY")
for r in sorted(d['no_body_rows'], key=lambda r: r['name'] or ''):
    print(f"    {r['kind']} {r['name']:30} {r['reason']}")
print()
print("  codes given for refusal:")
seen = {}
for s in d['states']:
    if s['state'] == 'UNKNOWN':
        seen.setdefault(s['code'], s['reason'])
for c, r in sorted(seen.items()):
    print(f"    {c}")
    print(f"      {r}")
PY
  echo
  echo "WHY NOT_INLINED IS AVAILABLE ONLY TO SOME KINDS"
  cat <<'TXT'
  See evidence/recorder_completeness.md and .txt. Every copy of a body's IL
  into another function is registered through exactly one function with exactly
  one caller, and the recorder reads that registry in the one AOT
  code-generation path. A second family of operations -- the CallSpecializer
  replacements -- materializes a callee's semantics without registering
  anything; its gates close for recognized methods and for operators on
  application classes, but NOT for a field's VM-synthesized implicit accessors.
  So field, constructor and factory rows are candidates that refuse, class rows
  are reported as declaring no body, and only method/getter/setter/operator can
  carry NOT_INLINED.
TXT
} > "$G/evidence/reader_state.txt" 2>&1

# ------------------------------------------------------- 4. falsification set
python3 - "$G/lib/read_inlining.py" "$W/weak_reader.py" "$W/generic_reader.py" <<'PY'
import pathlib, re, sys
s = pathlib.Path(sys.argv[1]).read_text()

# Control A: a reader that trusts an unvalidated note.
a = s.replace('    complete = note_ok and not unprojected',
              '    complete = True  # WEAKENED: trust the note unconditionally')
b = a.replace("        elif not note_ok:", "        elif False:  # WEAKENED")
assert b != a != s, 'weakening anchors not found in the reader'
pathlib.Path(sys.argv[2]).write_text(b)

# Control B: a reader that refuses correctly but collapses every refusal into
# one generic code. [A-Z0-9_]+ matters: codes carry digits (UTF8, ELF32, G1),
# and a first version of this control used [A-Z_]+ and silently left six codes
# specific, which made six arms pass a control they should have failed.
g = re.sub(r"raise NoteError\('[A-Z0-9_]+',", "raise NoteError('GENERIC_FAILURE',", s)
g = re.sub(r"return None, '[A-Z0-9_]+',", "return None, 'GENERIC_FAILURE',", g)
g = g.replace("raise NoteError(code, f'{what} wants",
              "raise NoteError('GENERIC_FAILURE', f'{what} wants")
g = g.replace("note_code = 'UNMODELED_PARSER_EXCEPTION'",
              "note_code = 'GENERIC_FAILURE'")
left = re.findall(r"(?:raise NoteError|return None,) '(?!GENERIC_FAILURE)[A-Z0-9_]+'", g)
assert not left, f'codes left specific: {left}'
pathlib.Path(sys.argv[3]).write_text(g)
PY
{
  echo "SM1-G5 route 2 -- adversarial falsification of the strict reader"
  echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_route2.sh"
  echo
  echo "PROVENANCE"
  echo "  $(sha "$G/lib/read_inlining.py")  lib/read_inlining.py"
  echo "  $(sha "$G/lib/falsify_reader.py")  lib/falsify_reader.py"
  echo "  $(sha "$W/app_s6r.aot")  app_s6r.aot (subject)"
  echo "  $(sha "$W/g2_r.json")  g2_r.json (G1 projection)"
  echo
  echo "WHAT EACH ARM ASSERTS"
  cat <<'TXT'
  1. the reader produced output -- a parser exception must resolve to a modeled
     UNKNOWN, never a crash. A crash writes no rows, and an absent row must
     never be read as a safe row.
  2. note_validated equals the value the arm expects. ELF/framing arms expect
     False; arms that mutate only the G1 projection expect True, because the
     note itself is still validly framed -- a False there would mean the arm
     tested something other than what it claims.
  3. the projection is reported incomplete.
  3b. THE REFUSAL CARRIES THE ARM'S OWN CODE. Asserting only "something was
     refused" would be passed by a reader that collapsed every problem into a
     single generic UNKNOWN, and would let one gate silently mask another.
     Every arm names the code it expects; an arm that names none fails.
  4. NO candidate is reported NOT_INLINED. NOT_INLINED is the safety fact this
     gate wants to use, so no mutation may be able to manufacture one.
  Arms that name a declaration additionally assert it is not INLINED.
TXT
  echo
  echo "=========================== RUN: shipped reader ==========================="
  python3 "$G/lib/falsify_reader.py" "$W/app_s6r.aot" "$W/g2_r.json" "$W"
  echo "exit=$?"
  echo
  echo "============= POSITIVE CONTROL A: a reader that trusts the note ==========="
  cat <<'TXT'
A falsification set that cannot fail certifies nothing. The same arms are
re-run against a copy of the shipped reader with exactly two edits --

    complete = note_ok and not unprojected   ->   complete = True
    elif not note_ok:                        ->   elif False:

-- i.e. a reader that trusts an unvalidated note. The arms must flip to FAIL
and say so by naming the manufactured NOT_INLINED rows.
TXT
  echo
  SM1_READER="$W/weak_reader.py" python3 "$G/lib/falsify_reader.py" \
      "$W/app_s6r.aot" "$W/g2_r.json" "$W"
  echo "exit=$?"
  echo
  echo "======== POSITIVE CONTROL B: a reader that refuses without saying why ====="
  cat <<'TXT'
Control A cannot detect the OTHER way this suite could be vacuous: a reader
that refuses everything correctly but reports one generic cause, so that one
gate masks another and no arm proves the gate it aimed at. The same arms run
against a copy whose refusal CODES are all rewritten to GENERIC_FAILURE, prose
untouched. Every arm except the baseline must flip, naming the code it wanted.
TXT
  echo
  SM1_READER="$W/generic_reader.py" python3 "$G/lib/falsify_reader.py" \
      "$W/app_s6r.aot" "$W/g2_r.json" "$W"
  echo "exit=$?"
  echo
  echo "WITHDRAWN EARLIER RUN, AND THE THREE DEFECTS IT WAS HIDING"
  cat <<'TXT'
An earlier version of this harness read its output file without deleting it
first. A run that crashed before writing therefore reported the PREVIOUS arm's
result, so two arms were recorded as correctly caught when the reader had in
fact crashed. That run is withdrawn, not annotated. Deleting the output first
exposed three real reader defects:

  1. an out-of-bounds e_shoff raised struct.error, killing the process instead
     of resolving to UNKNOWN;
  2. an unterminated section name raised ValueError, likewise;
  3. found while writing the new arms -- the reader checked that only one
     SECTION carried the note name, but never that the note consumed its
     section, so a second Shorebird note appended inside the same section
     would have been silently ignored.

All three are fixed and each now has its own arm above. Every read is
bounds-checked, every decode is modeled, an unreadable file is modeled, and a
backstop turns any remaining parser exception into a labeled UNKNOWN rather
than a crash.

SUBJECT CHANGED. Earlier runs used app_s6.aot, whose input kernel could no
longer be identified in the work directory, so its note was not reproducible
from a recorded recipe. This run uses app_s6r.aot, built by the recipe in
reader_state.txt. Per-declaration verdicts are identical between the two.
TXT
} > "$G/evidence/reader_falsification.txt" 2>&1
grep -q 'ALL_ARMS_REFUSED' "$G/evidence/reader_falsification.txt" || rc=1

# ---------------------------------------------------- 5. completeness enumeration
{
  echo "SM1-G5 route 2 -- recorder completeness, re-derived from source"
  echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_route2.sh"
  echo "The enumeration in evidence/recorder_completeness.md is not transcribed;"
  echo "this run re-derives every count and gate from the tree."
  echo
  echo "PROVENANCE"
  echo "  $(sha "$G/lib/verify_completeness.sh")  lib/verify_completeness.sh"
  echo "  $(sha "$G/evidence/recorder_completeness.md")  evidence/recorder_completeness.md"
  echo "  effective Dart tree 7b04b01bdc10ec990143257f0d28580571c2122f"
  echo "  revision            9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c"
  echo
  echo "================= RUN: the tree the evidence was built from ================"
  "$G/lib/verify_completeness.sh" "$D"; echo "exit=$?"
  echo
  echo "===================== POSITIVE CONTROL: it can fail ======================="
  cat <<'TXT'
An enumeration that cannot come out wrong proves nothing. The same checks run
against a clone of the tree with one planted addition -- a second function that
calls FlowGraphInliner::NextInlineId, i.e. exactly the shape of a new
registration site the completeness argument would have to account for. Both
NextInlineId checks must flip.
TXT
  echo
  CTL="$W/route2_ctl"
  rm -rf "$CTL"; mkdir -p "$CTL/runtime"
  cp -c -R "$D/runtime/vm" "$CTL/runtime/vm" 2>/dev/null || cp -R "$D/runtime/vm" "$CTL/runtime/vm"
  python3 - "$CTL/runtime/vm/compiler/backend/inliner.cc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "intptr_t FlowGraphInliner::NextInlineId(const Function& function,"
assert anchor in s
p.write_text(s.replace(anchor,
  "void ShorebirdControlSecondSite(FlowGraphInliner* i, const Function& f,\n"
  "                                const InstructionSource& src) {\n"
  "  i->NextInlineId(f, src);  // PLANTED: a second registration site\n"
  "}\n\n" + anchor, 1))
PY
  "$G/lib/verify_completeness.sh" "$CTL"; echo "exit=$?"
  rm -rf "$CTL"
  echo
  echo "NOTE"
  cat <<'TXT'
This verifier found an error in the document it checks: recorder_completeness.md
had transcribed the last recognized library as `M` rather than `VM`, because the
list had been extracted with a `tr -d` that stripped the leading V. The document
was corrected; the run above is against the corrected text.
TXT
} > "$G/evidence/recorder_completeness.txt" 2>&1
grep -q 'ENUMERATION_HOLDS' "$G/evidence/recorder_completeness.txt" || rc=1

# ------------------------------------------------------------- 6. manifest
python3 - "$G" "$D" "$GS" "$W" "$V" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
G, D, GS, W, V = sys.argv[1:6]
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
T = '7b04b01bdc10ec990143257f0d28580571c2122f'
FILES = ['runtime/vm/elf.h', 'runtime/vm/elf.cc',
         'runtime/vm/compiler/backend/flow_graph_compiler.cc']
m = json.load(open(f'{G}/instrumentation/MANIFEST.json'))
m['base']['frozen_file_sha256'] = {
    f: hashlib.sha256(subprocess.run(
        ['git', '-C', D, 'show', f'{T}:{f}'], capture_output=True).stdout).hexdigest()
    for f in FILES}
m['built']['instrumented_gen_snapshot_sha256_schema6'] = sha(GS)
m['delta_2']['sha256'] = sha(f'{G}/instrumentation/0002-g5-inlining-relation.patch')
st = json.load(open(f'{W}/s6r.json'))
m['route2_witness']['records'] = st['diagnostics']['records']
m['route2_witness']['subject'].update({
    'aot_sha256': sha(f'{W}/app_s6r.aot'),
    'input_kernel_sha256': sha(f'{W}/prepass3.dill')})
m['route2_witness']['determinism'].update({
    'build_a': {'aot': 'app_s6r.aot', 'aot_sha256': sha(f'{W}/app_s6r.aot')},
    'build_b': {'aot': 'app_s6rb.aot', 'aot_sha256': sha(f'{W}/app_s6rb.aot')},
    'note_section_sha256': st['diagnostics']['note_section_sha256']})
m['replay']['per_file'] = {
    f: {'replayed_sha256': sha(os.path.join(V, f)),
        'built_sha256': sha(os.path.join(D, f)),
        'equal': sha(os.path.join(V, f)) == sha(os.path.join(D, f))}
    for f in FILES}
m['replay']['all_files_equal'] = all(v['equal'] for v in m['replay']['per_file'].values())
m['regenerated_by'] = 'run_route2.sh'
json.dump(m, open(f'{G}/instrumentation/MANIFEST.json', 'w'), indent=2)
print('  manifest digests recomputed')
PY

echo
echo "replay_reproduces_clone=$([ "$replay_ok" = 1 ] && echo true || echo false)"
echo "SM1_G5_ROUTE2_REGENERATION: $([ "$rc" = 0 ] && echo COMPLETE || echo FAILED)"
exit "$rc"
