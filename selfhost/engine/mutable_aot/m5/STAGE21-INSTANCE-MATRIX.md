# STAGE21 — instance-member matrix after the body-leaves-the-walk repair

> **SUPERSEDED IN PART by STAGE22.** Section 5 concluded that the setter,
> operator and callable sites "do not route through" the switchable-call path.
> That is refuted. Disassembly shows all three are ordinary ARM64 switchable
> calls, identical in form to the getter's. They recorded nothing because a
> dynamic call to a member with a typed parameter resolves to that member's
> DYNAMIC INVOCATION FORWARDER, which the registry did not recognise. The
> measurements in section 5 are accurate as taken; the inference drawn from
> them was wrong. Everything else in this document stands.


Fork `c27af45252f`, built and stamped by `m2/build_maot.sh`
(`fork_sources_match_head 1`). Shorebird `9d09e938`.
`gen_snapshot` run with `--maot_install_trampolines` — the mechanism is OFF by
default and a run without it installs nothing and proves nothing.

## 1. The repair

`ProgramVisitor::WalkProgram` reaches a Function's Code only through
`Function::CurrentCode()`. `InstallMaotTrampolines()` makes the trampoline the
declaration's CurrentCode, so from that point the implementation **body** Code
was held by nothing but the registry pins, and every CodeVisitor pass scheduled
after installation silently skipped declaration bodies.

The registry's pins now join the walk beside the dispatch-table entries, which
were already there for exactly the same reason. No new runtime object, no new
replacement protocol, no change to the cell/trampoline architecture.

## 2. Matrix

Each row: production `StageReplacement` at V2 and V3 against a warmed site,
judged by comparing routing identities across the baseline/V2/V3 registry
dumps. 43 checks per row.

| row | member kind | body makes static calls | StageReplacement V2/V3 | verdict |
|---|---|---|---|---|
| method | instance method | no | 0 / 0 | PASS |
| getter | getter | no | 0 / 0 | PASS |
| setter | setter | **yes** | 0 / 0 | PASS |
| operator | `operator +` | **yes** | 0 / 0 | PASS |
| callable | `call()` | **yes** | 0 / 0 | PASS |

Frozen across all three stages, compared as addresses and not as names:
`id_declaration_function`, `id_declaration_current_code`, `id_trampoline_code`,
`id_trampoline_entry`, `id_dispatch_cell`, `id_release_body`.
Advancing at both V2 and V3: `id_cell_impl_function`, `id_cell_impl_code`,
`id_pinned_current_body`. At every stage `installable=True`,
`optimizer_escapes=0`, `blocking_records=<none>`,
`id_cell_impl_code != id_trampoline_code` (no self-cycle), and the unrelated
declaration `Beta` unchanged on every identity and in behaviour.

`id_declaration_current_code == id_trampoline_code` at every stage, which is
the architecture's own statement that the declaration routes through its
trampoline.

## 3. The acceptance judgement is falsified, not trusted

Five rows passing 43/43 on a first run is the shape of a suite that cannot
fail. `selftest_m5.py` feeds `judge_m5.py` deliberately corrupted evidence,
one mutation per PM hard-stop condition. **18 mutations, 0 undetected:**
false success (v2 still OLD), v3 repeating v2, a refused install, each of the
three implementation identities failing to advance, each of the six frozen
identities moving, cell.implCode set to the trampoline, escapes > 0, a blocking
record appearing, cross-wiring on identity and on behaviour, and the identity
fields being absent from the dump altogether.

A bug found doing this: the behaviour check was written
`A and B or C` and accepted any row whose V2 read `NEW-ALPHA`, never looking at
V3 at all. It now checks the three observations as an ordered sequence.

## 4. Two traps recorded, because each produced a wrong reading first

**A run without `--maot_install_trampolines` returns rc=0.** An 8-run flag
matrix "exonerated" the mechanism before anyone noticed `installed=0`.

**`Object::null()` is a real allocated heap object here**, so a null pointer
prints as a live address and a null destination cannot be recognised from `%p`.

## 5. Remaining blocker — dispatch-form coverage is NOT member-kind coverage

Member kind and dispatch form are different axes and only one is closed.

| row | switchable states observed | site inspector | dispatch form |
|---|---|---|---|
| method | yes | 0 (found) | megamorphic, frozen across V2/V3 |
| getter | `[2,1,1,0,1,2]` | 0 (found) | megamorphic, frozen across V2/V3 |
| setter | `[0,0,0,0,0,0]` | -1 | **unidentified** |
| operator | `[0,0,0,0,0,0]` | -1 | **unidentified** |
| callable | `[0,0,0,0,0,0]` | -1 | **unidentified** |

A zero per-declaration count is ambiguous on its own, so the miss handler now
also tallies unfiltered. The setter process records **18** switchable-call
misses and the operator and callable processes **15** each, with **zero**
attributed to the subject declaration. So the machinery works and is being
exercised; these three subject sites simply do not route through it, even after
50,008 warm iterations.

Per the standing rule that unknown forms remain blocking until proven, those
three rows carry **no dispatch-form claim**. What they do carry is a fully
verified member-kind result: real production StageReplacement, twice, with every
frozen routing identity unmoved.

One compile-time lead, not yet a conclusion: the setter reports
`indirect_call_sites_emitted=1` where the getter reports `0`, and that counter
is incremented only from `MaotRegistry::NoteCallSiteEmitted` on the #67
direct/static call indirection path in `flow_graph_compiler_arm64.cc`.

## 6. Not claimed

#69 is not closed. Tearoffs are untouched and remain a separate surface. No #70
work. No #64 promotion.
