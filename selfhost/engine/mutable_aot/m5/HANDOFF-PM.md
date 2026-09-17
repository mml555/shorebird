# Mutable-AOT #69 — PM handoff and proposed next task sets

Fork `fbae05c4ab8` (clean, `fork_sources_match_head 1`), Shorebird `4198d4de1`.
Every number below comes from a stamped build; every run passes
`--maot_install_trampolines`, which is OFF by default.

---

## 1. Where the programme stands

| issue | state |
|---|---|
| #67 | ESTABLISHED |
| #68 | ESTABLISHED (re-closed; P1 mutable-constant suppression ON by default, P3 retained as fallback) |
| #69 | ACTIVE — instance-member surface complete, awaiting disposition |
| #70 | not authorized, untouched |
| #64 promotion | not claimed |

Established milestones: `ARM64_AOT_INSTANCE_STAGE_REPLACEMENT_VERTICAL_SLICE`,
`ARM64_AOT_INSTANCE_GETTER_VERTICAL_SLICE`.

---

## 2. What closed since the last ruling

### 2.1 A real defect, found and fixed (STAGE20, `fa55e06ac3e`)

The "setter crash" was **not a setter defect**. `ProgramVisitor::WalkProgram`
reaches a Function's Code only through `Function::CurrentCode()`, and
`InstallMaotTrampolines()` makes the trampoline the CurrentCode — so the
implementation **body** left program reachability, and every CodeVisitor pass
after installation silently skipped declaration bodies.
`ReplaceFunctionStaticCallEntries` stopped binding their pc-relative static
calls; `CodeRelocator::GetTarget`'s `ASSERT(target_.IsCode())` is compiled out
in product, so a null destination was dereferenced.

Falsified both ways: a **getter** whose body makes static calls crashed
identically; a **setter** whose body makes none serialized cleanly.

Fix: the registry's pins join the walk beside the dispatch-table entries, which
were already there for the same reason. One site, no architecture change.

Scope note: this defect sat inside the coverage both established slices
nominally claim — both were established on constant-string bodies with empty
static-call tables.

### 2.2 A dispatch form that was never modelled (STAGE22, `93d06e2187c`)

A dynamic call to a member **with a typed parameter** resolves to that member's
**dynamic invocation forwarder**, not the member. The registry is keyed on the
member, so nothing was attributed and the call site was never remembered — the
setter, `operator +` and `call()` reported zero observed states while a
no-argument getter, needing no forwarder, worked normally.

Disassembly settles the route: the forwarder's tail **is** the #67 cell
indirection (`pool[cell] → cell[kCellImplFunction] → blr entry_point`). It
stores no implementation identity and re-reads the cell every call.

### 2.3 Tear-offs, measured not assumed (STAGE23, `4198d4de1`)

A tear-off lowers to an implicit tear-off getter that allocates a Closure
holding an **implicit closure function**, whose code also re-reads the cell per
call. So a closure captured *before* an install still observes the new body —
it never captured a body.

`tearoff_pre` is therefore **not** semantically ambiguous in this design. The
migration question reserved for this surface would only arise for a design that
captured an implementation.

### 2.4 A hard-stop check that could return a false negative (STAGE24, `fbae05c4ab8`)

`converges` asked whether the *declaration's* CurrentCode was the trampoline —
a fact about an object the dispatch state does not store. Same `true` would
have come back had the forwarder bound an implementation body directly. Each
route is now tested on what makes it slot-preserving, and the negative control
(`--maot_disable_call_indirection`) moves the verdict from slot-preserving to
two route-named blocking records.

---

## 3. The matrix as it stands

Six rows, each a real production `StageReplacement` at V2 and V3 against a
warmed site, judged by comparing routing identities **as addresses**.

| row | subject | dispatch form observed | checks |
|---|---|---|---|
| method | instance method | MegamorphicCache via declaration | 53 PASS |
| getter | getter | MegamorphicCache via declaration | 53 PASS |
| setter | setter | MegamorphicCache via **dyn-forwarder** | 53 PASS |
| operator | `operator +` | MegamorphicCache via **dyn-forwarder** | 53 PASS |
| callable | `call()` | MegamorphicCache via **dyn-forwarder** | 53 PASS |
| tearoff | tear-off pre & post | Closure → implicit closure fn → cell | 53 PASS |

Frozen across baseline/V2/V3: declaration Function, declaration CurrentCode,
trampoline Code, trampoline entry, dispatch cell, release body, plus site pc,
cache state, entry cid, cached Function and its address. Advancing at both
stages: cell implFunction, cell implCode, pinned current body. At every stage
`installable=True`, `optimizer_escapes=0`, `blocking_records=<none>`, no
self-cycle, unrelated declaration unchanged.

**The judge is falsified, not trusted: 34 mutations, 0 undetected**, one per
hard-stop condition — false success, v3 repeating v2, refused install, each
implementation identity failing to advance, each frozen identity moving,
self-cycle, escapes > 0, blocking record, cross-wiring, cache relink, cached
function replaced, state transition, stale tear-off in either arm,
re-allocated closure, and each identity source being absent entirely.

Harness: `m5/lib/{judge_m5,matrix_m5,selftest_m5}.py`.

---

## 4. What needs a ruling

1. **Disposition on the six-row matrix.** Milestone naming is the PM's.
2. **Ratify or reject a classification I made under delegated authority:**
   `dynamic/MegamorphicCache via dyn-invocation-forwarder = SLOT_PRESERVING`,
   recorded as a *distinct* form rather than folded into the accepted record.
3. **An architecture sentence that no longer describes every route.** The
   accepted chain is `frozen cache → declaration Function → trampoline → cell →
   body`. For forwarder-routed members it is `frozen cache → forwarder
   Function → cell (direct) → body` — **the declaration trampoline is not on
   that path.** The invariant carrying those members is the stable cell
   re-read per call. Replacement works and is slot-preserving; the wording
   does not cover it.

---

## 5. Proposed next task sets

Ordered by what they de-risk, not by effort.

**A. Dispatch-mode coverage across the five subjects.** The matrix covers the
`dynamic` mode for all five subjects plus both tear-off modes for the method
subject. `direct`, `virtual`, `interface` and `super` were classified in
STAGE3–STAGE13 but were never re-run per-subject with the identity-frozen
judge. This is the largest honest coverage gap and needs no new mechanism.

**B. Tear-off arms for the other four subjects.** Tear-offs were measured only
for the instance-method subject. A getter has no tear-off; setter, operator and
`call()` do, and each carries a forwarder.

**C. Scale.** The whole matrix runs at four declarations. The
`--maot_install_trampolines` flag is off by default with the stated reason "the
mechanism does not yet serialize above a small population". The serializer
threshold is parked and nothing here disturbs that. If #69 is to close, this
has to be faced deliberately.

**D. Harden what STAGE20 exposed.** Only `ReplaceFunctionStaticCallEntries` was
*proven* to break when bodies left the walk. `DiscardCodeObjects` and the ten
per-Code rewriting passes inside `Dedup` were equally blind; they did not crash,
which is worse than crashing. The fix restored them all at once, but none has a
regression proving it. A pass-by-pass check would convert "fixed by
construction" into evidence.

**E. Anything requiring new authorization:** #64 promotion, #70, or corpus
beyond instance members — static/top-level members, constructors, factories,
async and generator bodies, closures. None touched.

---

## 6. Limits on everything above

- **ARM64 host only.** No device run in this phase.
- **Four declarations per fixture.** Not a scale result (see 5C).
- **Closure identity is language-level**, not a read of the VM's function field:
  stable `identityHashCode` plus Dart tear-off equality. Stated so it is not
  mistaken for a pointer comparison.
- **`--maot_dump_caller_code` writes to `/tmp/maot_caller_code.txt` and
  APPENDS.** A stale file reads as the current run's evidence.
- **Two traps that each produced a confident wrong answer first**, recorded so
  they are not repeated: a run without `--maot_install_trampolines` returns
  `rc=0` having installed nothing, and `Object::null()` is a real allocated
  heap object here, so a null pointer prints as a live address.

---

## 7. Evidence index

`STAGE20` body-leaves-the-walk · `STAGE21` instance matrix (§5 superseded by
STAGE22) · `STAGE22` forwarder route · `STAGE23` tear-offs · `STAGE24` route
convergence. Fixtures `m5/lib/fixture_m5_{prod,getter,setter,operator,callable,tearoff,callgetter,pursetter}.dart`.
