# MAOT-5 (#69) — distinctness fix: succeeded; two other failures isolated

## The authorized change worked

`installed=N → distinct=N`, at every population:

| installed | distinct post-dedup |
|---|---|
| 1 | 1 |
| 3 | 3 |
| 6 | 6 |
| 7 | 7 |
| 13 | 13 |

Previously **every** population collapsed to `distinct=1`.

It was fixed by using the pool mechanism normally, not by working around it.
`ObjectPoolBuilder`'s own header describes the intended flow: accumulate in an
intermediary pool parented to the global one, then **commit** with
`TryCommitToParent()` at the end of a successful compilation. Committing is
what advances the next builder's `base_index_`. Not committing left every
trampoline with the same `base_index_` and its cell at local index 0, so every
trampoline encoded the same pool offset and had identical instruction bytes.
`ProgramVisitor::Dedup` then merged them, and one `Code` shared by N
declarations branches through **one** cell.

Normal function compilation retries when the commit fails because the global
pool grew underneath it (`PrecompileParsedFunctionHelper::Compile`); this does
the same. No dedup was disabled and nothing was marked artificially
non-deduplicable.

At N=6 the serializer sees **6 distinct trampolines** and writes all of them
(`maot=1` × 6 across 1616 Codes) — so a distinct trampoline is a
serializable object.

## Gate: NOT PASS

Two failures remain. **Neither is the dedup invariant**, and neither was
visible before it was repaired.

### 1. One trampoline crashes the program at runtime

| N | snapshot | runtime | observed |
|---|---|---|---|
| **0** | ok | **rc=0** | `tiny.0=OLD-TINY`, `tiny.1=NEW-TINY` |
| **1** | ok | **rc=-6** | `tiny.0=OLD-TINY` printed, then SEGV |
| 6 | ok | rc=-6 | SEGV before `tiny.0` |

N=0 is a clean control: without trampolines the #67/#68 path still replaces
correctly. **A single trampoline is sufficient to crash.**

This is new information. The trampoline had never executed before — every
earlier failure was at snapshot time — so obligations 1, 2 and 3 (entry
behaviour, register correctness, release-body pinning) were untestable. They
are now testable, and the first observation is that the emitted code faults.

### 2. Serialization still fails at N ≥ 7

Deterministic across three trials: rc=-6, **173 Codes entered, all 173
completed**, last line `END_CODE 172`. N=6 completes 1616.

An earlier reading of `END_CODE 1615` for N=7 was a **stale trace file**, not
a result; it is withdrawn. The determinism check is what caught it.

The Code cluster's own counters were not captured — that edit silently failed
to land and the omission was only noticed afterwards, so whether the
population is truncated to 173 or the loop is cut short remains unproven.

## Correction to the previous checkpoint

I wrote that "the 6→7 boundary is a symptom, not the cause". With
distinctness repaired the boundary persists unchanged, so that was wrong.
Merging was real and would have been semantically fatal, but it was not
causing the serializer crash.

## Not claimed

* No dispatch form is proven; no #64 cell moves.
* The cross-wiring test could not run: it needs a program that executes, and
  the runtime crashes with even one trampoline.
* No fix attempted for either remaining failure.
