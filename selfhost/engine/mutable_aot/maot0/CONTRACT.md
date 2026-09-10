<!-- cspell:words devirtualization megamorphic monomorphic canonicalization unmodeled UNMODELED patchability arity nonNullable -->

# The universal Dart patchability contract — MAOT-0 (#63)

**Status: the contract is established. Universal support is `NOT_PROVEN`, and
0 of 104 rows are `PROVEN`.** That is the correct reading of a program on its
first day, and this file exists to make it impossible to report otherwise
later without evidence.

[`matrix.json`](matrix.json) is the authority. This file explains it; it adds
no rows and decides no verdict. Where the two disagree, `matrix.json` is right
and this file is a bug.

---

## The promise, stated precisely

> Within a **fixed native Flutter/Dart engine and application binary**, any
> change expressible in Dart can be delivered as a patch, subject only to
> explicit migration semantics where the desired transformation of existing
> live state is inherently ambiguous.

Two things in that sentence are load-bearing and are routinely collapsed:

1. **"Fixed native binary"** — we fork and change the Dart VM, the CFE, the
   AOT compiler and the Flutter engine as freely as the program needs, *before
   a release is cut*. Once shipped, that binary does not change. Everything
   the promise covers happens in Dart, on top of it.
2. **"Subject only to explicit migration semantics"** — a change is not
   unsupported merely because the runtime cannot guess what the developer
   meant. Those two failures look identical in a naive matrix and are entirely
   different engineering problems.

## Four semantics, never one status

Every row carries four independent axes. Collapsing any two of them is the
specific error #63 was written to prevent.

| axis | question |
|---|---|
| `code_representability` | Can the patched program shape exist and execute in the running process under the fixed native binary? |
| `dispatch_correctness` | Does **every** supported invocation path observe the current implementation after installation? |
| `live_state_compatibility` | What happens to state that already exists — frames, heap objects, closures, continuations, caches, canonical constants? |
| `semantic_migration` | When the transformation of existing state is not uniquely determined by the code change, what developer-authored migration is required, and how is it executed? |

Worked example, and the reason the split matters:

```dart
// release                          // patch
class User {                        class User {
  String fullName;                    String firstName;
                                      String lastName;
}                                   }
```

* `code_representability` — **achievable**. The new class shape can exist.
* `dispatch_correctness` — **achievable**. New code reaches the new members.
* `live_state_compatibility` — **needs a versioned layout**. Instances already
  in the heap have the old shape.
* `semantic_migration` — **developer-authored, necessarily**. `"Ada Lovelace"`
  splits into `("Ada", "Lovelace")` only because a human knows it should.
  Nothing in the code says so, and a runtime that guesses is worse than one
  that asks.

This is `TS-03` plus `RS-01`. It is **not** "unsupported Dart". Calling it that
would be a category error the matrix is built to prevent — and the gate asserts
it, by requiring the ambiguous rows to be classified
`developer_migration_required` rather than pushed out of scope.

## Row states, and how they are derived

Axis values are `UNMODELED` → `DESIGNED` → `IMPLEMENTED` → `PROVEN`, plus
`NOT_APPLICABLE`.

`NOT_APPLICABLE` is deliberately **not** on that scale. It asserts the axis does
not exist for this row, and it **requires a written justification** — because
waving away all four axes is the cheapest possible way to make a hard row look
finished. A row whose every axis is `NOT_APPLICABLE` derives `UNMODELED`, never
`PROVEN`; that is arm `N19`.

**A row's state is never stored.** It is `min()` over the applicable axes, in
[`lib/contract.py`](lib/contract.py). A stored status would be a second answer
that no longer has to agree with the axes it summarises.

A row may only be `PROVEN` when it also carries an executable `gate_id` and an
`evidence` reference whose file exists and whose digest matches. Axes alone are
an assertion; evidence is what makes it a finding.

## The 100% rule

```
universal_dart_patchability == PROVEN
  iff  there is at least one in-scope row
  AND  every in-scope row derives PROVEN from its applicable axes
  AND  every such row carries a gate_id and a digested evidence reference
  AND  no blocking structural finding was raised
```

There is no threshold anywhere in that function. Row-state counts are
published and labelled `DIAGNOSTIC`; nothing compares against them.

Two arms hold this down rather than a comment asking nicely:

* **`N02`** — 99.04 % of in-scope rows `PROVEN` still yields `NOT_PROVEN`.
* **`N03`** — deleting a row from an otherwise fully proven matrix does not buy
  a 100 % claim; the constructs it covered become uncovered and the aggregate
  refuses.

And the control that makes those mean anything:

* **`P1`** — a matrix whose every in-scope row is genuinely `PROVEN`, with real
  evidence files and matching digests, **does** reach `PROVEN`. Without this,
  "fail closed" would be indistinguishable from a gate that can only ever
  refuse, which measures nothing.

## Where the required rows come from

A coverage check whose required-row list is the matrix itself cannot fail. So
the list is derived from the compiler and runtime this program intends to fork,
and frozen into [`universe/`](universe):

| universe | source | entries |
|---|---|---|
| `U1` kernel | every node class and node-kind enum value in `pkg/kernel/lib/src/ast/*.dart` | 330 |
| `U2` VM runtime | every heap class in `runtime/vm/object.h` reaching `Object` | 89 |

Extracted from Dart tree `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c`, with the
extracted paths clean, per-file digests recorded, and the extractor's own
digest recorded. The freeze re-derives **byte-identically**, which the gate
checks whenever a Dart tree is reachable — and the gate runs correctly without
one, so no result here depends on an external disk.

Every one of the 419 entries is named by a row, absorbed by a declared blanket,
or explicitly excluded with a reason. **No entry is merely absent.** The
declaration, type, constant, identity and runtime-state tiers are covered
**row by row** — of their 216 entries, 170 are named individually and 46 are
excluded by a declared class with a written reason. Only body
content, program-structure containers, abstract node bases and kernel
serialization helpers may be claimed wholesale, and each blanket is a written
row (`BL-01`…`BL-04`) rather than an omission.

> **Body content is one rule, not 186.** Every expression, statement, pattern
> and initializer node is covered by whichever body row owns the enclosing
> declaration, because no body-content node has patch semantics independent of
> the declaration containing it. That is a judgement, so it is written down as
> `BL-01` where it can be argued with.

## The fixed-native-binary boundary

Machine-readable in `matrix.json` as `boundaries`, cited by id from any row
that leaves scope. A row cannot go out of scope without naming one (`N15`), and
cannot name one that does not exist (`N16`).

| id | excluded |
|---|---|
| `NB-1` | native platform source (iOS/Android/macOS/Windows/Linux) |
| `NB-2` | Flutter engine and Dart VM C/C++ changes **after** release |
| `NB-3` | native plugin ABI changes |
| `NB-4` | new native symbols |
| `NB-5` | asset and shader transport |
| `NB-6` | store distribution policy |
| `NB-7` | backend rollout, targeting and delivery |

`NB-2` is the one worth restating: **we change the engine and VM freely before
a release**. The boundary is that the *shipped* binary is fixed, not that the
fork is off-limits.

## The lock, and why it has two layers

`matrix.lock.json` digests the promotable part of every row — axis states,
scope, gate id, evidence binding — and the gate refuses on drift. It is
advanced only by `run_maot0.sh --accept-lock`, which refuses while any
non-lock blocking finding stands.

A single layer would fall to the obvious attack: promote a row *and* regenerate
the lock. So the layers are independent —

* **`N08`** — promoting a row without advancing the lock is caught as drift.
* **`N09`** — promoting a row **and** regenerating the lock is *still* refused,
  because the promotion has no evidence behind it.

## What every later issue must do with this file

1. **Consume these row ids.** #64 builds a fixture per row and must not keep a
   second list; every row already names its `gate_id`.
2. **Report per axis, not per row.** "MAOT-3 is done" is not a claim this
   contract can record. "`EB-01.dispatch_correctness` is `PROVEN`, evidence at
   `<path>`, digest `<sha>`" is.
3. **Advance the lock deliberately**, in the commit that supplies the evidence.
4. **Never quote a percentage as closure.** Report it if useful; the gate
   ignores it.
5. **If a row turns out to be wrong, fix the row.** A later issue discovering
   that a construct needs three rows rather than one is the contract working.
   Silently widening a row to swallow the difference is not.

## What MAOT-0 deliberately did not do

No CFE, AOT compiler, VM, optimizer, Route B, CLI, patch-format, migration or
Flutter change. The gate asserts this rather than promising it: it fails if
anything under `packages/`, `bin/`, `scripts/`, `selfhost/engine/route_b`,
`selfhost/engine/route_b_di`, `selfhost/engine/dart-fork` or
`selfhost/engine/semantic_map` is modified — using `git status --porcelain`, not
`git diff`, because an untracked new file is exactly how scope leaks.

## Known limitations of this contract

Stated here rather than discovered later:

* **The universes are structural, not semantic.** They enumerate what the
  compiler and runtime can *represent*. A Dart feature that introduces no new
  Kernel node and no new VM heap class — a purely static rule, say — would not
  appear, and would need a row added by judgement. The gate cannot catch that
  class of omission, and no gate built on these two sources could.
* **The universes are pinned to one Dart revision.** When the MAOT fork's Dart
  tree diverges, `universe/` must be re-derived; the gate will report `DIFFERS`
  rather than quietly comparing against a stale freeze.
* **Row granularity is a judgement.** 104 rows is a defensible decomposition,
  not a derived one. The falsification arms prove the gate enforces whatever
  decomposition is committed; they do not prove the decomposition is the right
  one.
* **`expected_post_patch` is prose.** It is precise prose that #64 must turn
  into executable assertions, but until #64 does, it is intent rather than
  a test.

## Reading the evidence

```
./run_maot0.sh                 -> evidence/maot0.txt, maot0.json,
                                  maot0_falsification.json
./run_maot0.sh --accept-lock   -> advances matrix.lock.json, then re-gates
DART_TREE=<path> ./run_maot0.sh -> also re-derives the frozen universes
```

22 falsification arms in both directions, plus the driver's own assertions.
The record's every computed value names the decision that consumes it, and the
gate fails if any value is computed that no decision reads — or if a declared
consumer names a value the record does not produce.

Every figure quoted in this file is derived from the record by
[`lib/check_contract_doc.py`](lib/check_contract_doc.py) and required to appear
here verbatim, so a matrix change that does not reach this prose fails the
gate. Prose drifting from the data it describes is worse than prose that says
nothing, because a reader trusts the sentence rather than the JSON.
