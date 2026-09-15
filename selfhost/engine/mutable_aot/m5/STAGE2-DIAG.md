# MAOT-5 (#69) — stage 2 diagnostics: steps 1–3 complete

The authorized sequence ran in order. The prototype still does not
serialize; no #64 cell moves and no dispatch form is proven.

## Step 1 — pre-serialization shape dump

Written to a file, not stderr: the stderr version produced nothing at all,
because the process segfaults moments later and the buffer is lost — which is
indistinguishable from the dump never running.

| field | trampoline | body (known-good Fn-owned) | stub (known-good) |
|---|---|---|---|
| owner | Function | Function | null |
| isFunctionCode | 1 | 1 | 0 |
| **object_pool** | **0** | **1** | **1** |
| static_calls_table | 1 | 1 | 0 |
| pc_descriptors | 1 | 1 | 1 |
| compressed_stackmaps | 1 | 1 | 1 |
| exception_handlers | 0 | 1 | 0 |
| monomorphic entry | 1 | 0 | 0 |
| size | 40 | 8 | 168 |

**One real defect found by comparison rather than guessing:** the trampoline
was the only `Code` in the program with a null `object_pool_`.
`Code::FinalizeCode` creates a tracking pool under `kNotAttachPool` only
`if (assembler->object_pool_builder().HasParent())`, and the generator handed
it the **global** builder, which is the root and has no parent. Fixed by
using a local builder parented to the global one — instructions unchanged,
since offsets still resolve into the global pool.

**It did not fix the crash.** Same faulting address. Recorded as fixed-but-not-causal.

## Step 2 — one-trampoline build

| trampolines installed | result |
|---|---|
| 0 | ok (control) |
| 1 | **ok** |
| 2, 4, 5, 6 | ok |
| **7** | **CRASH** |
| 8, 12, 13 | CRASH |

A single trampoline serializes successfully. The threshold is exactly
**6 → 7**, so this is **not a malformed trampoline** — it is a multiplicity
problem. Registry order puts `fn:recognizedish` at index 6, but whether the
boundary is that declaration or the seventh trampoline as such is **not yet
distinguished**, and the current instrumentation cannot tell them apart.

## Step 3 — class-owner variant

| owner | result |
|---|---|
| Function (13) | CRASH |
| **Class (13)** | **CRASH, identically** |

Per the ruling's own criterion this **refutes owner** as the implicated
factor. It is not a Function-owner-dependent path, so the lower-impact
registry-backed resolver design is not indicated by this evidence, and no
architectural pivot follows from it.

## Where that leaves the sequence

The ruling's branch for this outcome is explicit: *"If Class owner crashes
identically, treat owner as refuted and instrument the serializer/code-cluster
phase to locate the exact failing field/operation instead of adding guessed
metadata."*

That is the next step, and it is the right one — three shape hypotheses
(compressed stackmaps, descriptors, object pool) have now each been tested
and none was causal, which is precisely the pattern that says stop guessing
at metadata.

Two facts the instrumentation must explain together:

* one trampoline serializes, seven do not;
* the owner does not matter.

## Not claimed

* No dispatch form is proven. No #64 cell moves.
* The trampoline has never executed; obligations 1, 2, 3 and 6 remain untested.
* The 6→7 boundary is not yet attributed to a count or to a declaration.
