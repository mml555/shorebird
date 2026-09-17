# STAGE26 — ARM64_AOT_INSTANCE_DISPATCH_MATRIX

Fork `1a20e5b12a2` (clean), stamped by `m2/build_maot.sh`.

## 1. Result

**25 of 25 cells PASS. No N/A required, no BLOCKED cell.**

| subject | direct | virtual | interface | dynamic | super |
|---|---|---|---|---|---|
| method | PASS | PASS | PASS | PASS¹ | PASS |
| getter | PASS | PASS | PASS | PASS¹ | PASS |
| setter | PASS | PASS | PASS | PASS¹ | PASS |
| operator | PASS | PASS | PASS | PASS¹ | PASS |
| callable | PASS | PASS | PASS | PASS¹ | PASS |

¹ established earlier as the subject matrix (STAGE21–22); the other 20 cells are
this stage, each through the production judge at 43 checks.

## 2. Route mapping, taken from the VM's accounting

The matrix must describe final AOT routing, so the mapping is read from
`indirect_call_sites_emitted` (registry dump) and the dispatch-table slot
counts (trampoline shape dump) — not from source syntax.

| cell | indirect cell sites | dispatch-table slots | route |
|---|---|---|---|
| direct | **1** | 0 | caller reads the cell inline (#67); anchor is the pool-held cell reference |
| super | **1** | 0 | same |
| virtual | 0 | **1** | dispatch table → declaration trampoline → cell |
| interface | 0 | **1** | dispatch table → declaration trampoline → cell |
| dynamic | — | — | switchable call → declaration **or** dyn-invocation-forwarder → cell |

Uniform across all five subjects.

**Two anchor types appear, both already accepted**: the declaration trampoline
(virtual/interface, and the declaration route of dynamic), and the pool-held
cell reference of #67 (direct/super). No materially new anchor type appeared,
so no stop condition was hit.

**virtual and interface share one mechanism.** Recorded as two cells because
they are two source forms that both genuinely reach dispatch-table routing —
not one mechanism counted twice, and not a devirtualisation artifact.

## 3. A correction to my own instrumentation

An intermediate disassembly classifier reported that the **getter** subject
routed `direct`/`super` through inline cell indirection while the other four
subjects used a plain pc-relative call — i.e. that the route map was not
uniform. **That was wrong.** The classifier pattern-matched `ldur x30, [x, #0x7]`,
and a real cell indirection elsewhere uses `#0xf`, so it misread four subjects.

The VM's own `indirect_call_sites_emitted` counter reports `1` for direct and
super on **every** subject. The mapping in §2 comes from that counter, not from
the pattern matcher, and the earlier per-subject difference is retracted.

## 4. Acceptance standard actually applied

Every one of the 20 cells went through the production judge, not a replay of an
older route classification. Per cell:

`installable=True`, `optimizer_escapes=0`, `blocking_records=<none>` at all
three stages; `OLD → StageReplacement(v2) → NEW → StageReplacement(v3) → NEW2`;
version `1 → -102 → -103`; frozen identities (declaration Function, declaration
CurrentCode, trampoline Code, trampoline entry, dispatch cell, release body)
unchanged as addresses; implementation identities (cell implFunction, cell
implCode, pinned body) advancing at both stages; no self-cycle; and the
cross-wiring control `Other` — a mutable declaration sharing the selector —
unchanged on every identity and in behaviour.

All four routes of a subject are installed **in the same run**, so each is
judged against the same frozen program rather than a private one.

## 5. Traversal regression rerun at this HEAD

Required before declaring the matrix. `PINNED_TRAVERSAL verdict=PASS` on all
five new dispatch fixtures (all non-leaf), and the six-row subject suite still
passes here: 53 checks per row, four non-leaf rows, suite non-vacuous.

## 6. Not claimed

#69 is not closed — that disposition is the PM's. Scale remains separate and
untouched (four declarations per fixture). No #70, no #64 promotion. Tear-offs
beyond the method route remain a separate surface.
