# STAGE 10 — the paired regression resolves to a confirmed #67 coverage hole

Status: **FINDING — reported, not applied.** No disposition changed. No fix
written. #67 remains ACCEPTED as the PM left it; this document is the proof
that it has a named, reproducible hole, and the proposal for closing it.

## 1. What the paired experiment actually showed

The PM directed a paired #67 regression: m3's exact positive control beside the
failing subject, one binary, trampolines OFF, the real install API for both.

```
A (m3 control, called directly from main):   A.0=OLD          install=0  A.1=NEW           A.2=NEW
B (reached through a never-inline wrapper):  B.0=OLD-CONTROL  install=0  B.1=OLD-CONTROL   B.2=OLD-CONTROL
fn:work    call_sites=3 escapes=0
fn:control call_sites=1 escapes=0
```

Both call sites are correct and **instruction-equivalent**, and both name the
right cell — the seeded index and the emitted PP offset agree exactly:

| declaration | seeded index | PP offset printed | offset emitted in code |
|---|---|---|---|
| `fn:work`    | 8  | 80 | `ldr x0,[x27,#80]` (×3 in `main`) |
| `fn:control` | 10 | 96 | `ldr x0,[x27,#96]` (in `callControl`) |

`callControl`'s final code is the textbook #67 sequence:

```
20: ldr  x0, [x27, #96]   ; pool[10] = the fn:control cell
24: ldur x0, [x0, #23]    ; cell[kCellImplFunction]
28: ldur x30, [x0, #7]    ; Function::entry_point_
32: blr  x30
```

Post-install identity is likewise correct **and identical** for A and B:

```
fn:work     cell.implFunction = workNew      pool[8]  IS the cell   cell.implCode == implFn.CurrentCode = YES
fn:control  cell.implFunction = controlNew   pool[10] IS the cell   cell.implCode == implFn.CurrentCode = YES
```

So the cell is right, the call site is right, the install is right, and the new
body is entered. The divergence is not in dispatch at all.

## 2. The first concrete difference between the two call paths

Disassembling `main` shows it. At every A site the returned value is used; at
every B site it is thrown away and a constant is loaded in its place:

```
A:  88: ldr x0,[x27,#80]  …  100: blr x30   →  104: mov x2, x0        ; result USED
B: 116: bl  <callControl>                    →  120: ldr x1,[x27,#6200]
                                                124: ldr x2,[x27,#152] ; result DISCARDED
```

All three B sites (`116/120/124`, `280/284/288`, `412/416/420`) load `x2` from
the **same** pool offset 152. `callControl()` is called — `vm:never-inline` is
honoured — the cell is read, the replacement body runs, and `main` ignores what
it returns.

## 3. Which variable is responsible — measured, not inferred

The paired fixture varied two things at once, so it could not attribute the
failure. Four arms in one binary, one install sequence, separating them:

| arm | reached via | return constant-inferable | after install |
|---|---|---|---|
| CD | direct from `main` | yes | `NEW` ✓ |
| CW | never-inline wrapper | **yes** | `OLD-CONTROL` ✗ |
| ND | direct from `main` | no | `NEW-ND` ✓ |
| NW | never-inline wrapper | no | `NEW-NW` ✓ |

**Wrapper-ness is refuted.** NW goes through the identical wrapper shape and
observes the replacement. **Constant-inferability alone is not sufficient
either** — CD is constant *and* observed, because on the direct edge the
existing suppression fires.

The failing combination is exactly one cell of the 2×2:

> a mutable declaration whose return value is constant-inferable, **reached
> through a non-mutable intermediary**.

## 4. Why that cell is uncovered — both layers gate on the immediate target

`pkg/vm/lib/transformations/type_flow/transformer.dart:748`

```dart
bool _callsMaotMutable(TreeNode node, Member? interfaceTarget) {
  final Member? target = node is StaticInvocation ? node.target : …;
  return target != null && _isMaotMutable(target);
}
```

used as `suppressConstant: _callsMaotMutable(node, interfaceTarget)` at :811.
For `main`'s call, `target` is `callControl`, which is **not** mutable, so the
constant survives.

`runtime/vm/compiler/frontend/kernel_binary_flowgraph.cc:3440` — the #68
constant backstop — applies the same immediate-target test:

```c
… && result_type.IsConstant() && MaotRegistry::IsMutableDeclaration(thread(), target)
```

so it did not fire either: `fn:control escapes=0`.

The deeper reason is that suppression happens at **annotation** time, not at
**analysis** time. `constantValue = type.attributes?.constant`
(`transformer.dart:613`) — the constant is an attribute of the Type flowing
through TFA. Blanking it at `_convertType` (:676) clears the annotation on the
direct call site; the Type itself, constant attribute intact, has already
propagated into the summary of every function that returns the mutable call's
result. Every caller of *that* function then folds it legitimately.

The CFE comment states the scope as a deliberate choice:
*"The direct target is what matters: an interface target says what the source
named, and #67 covers only direct/static calls."* This finding is the case that
choice does not cover.

## 5. Severity: the install reports success while nothing observes it

`install.CW = 0`. The descriptor says the replacement was installed; the cell
says the replacement was installed; the disassembly says the replacement body
ran. No caller can see it. That is precisely the failure class the #68 backstop
was written to prevent — quoted from its own comment: *"the call is still
emitted, still reaches the dispatch cell, and the caller uses the folded release
answer anyway. Path evidence looks perfect while the program ignores every
replacement."*

## 6. What this does and does not invalidate

- It **cannot** have produced a false positive anywhere. Folding substitutes the
  *release* value, so its only possible effect is to hide a replacement. No
  previously reported "NEW observed" result can have been manufactured by it.
- It **can** have produced false negatives. Any fixture whose mutable subject
  returns a constant and is reached through a non-mutable intermediary was
  measuring this hole rather than the mechanism under test.

## 7. The super divergence is the same hole — measured

The super fixture is exactly the failing cell: `Base.v() => 'OLD-BASE'` is
constant and is reached only through `Sub.viaSuper()`, a non-mutable
intermediary. So is its paired control. That is why **both** failed
identically, and why the "super does not observe the cell" framing was
retracted — the control was never a control for this variable.

Holding the super form, the `vm:never-inline` intermediary and the diagnostic
swap sequence fixed, and varying only constant-inferability:

| arm | form | return constant-inferable | swap rc | after swap |
|---|---|---|---|---|
| CS | `super.v()` via `viaSuper()` | yes | 0 | `OLD-CS` ✗ |
| NS | `super.v()` via `viaSuper()` | no  | 0 | `NEW-NS` ✓ |

`super.v()` observes the dispatch cell. The super form was never the variable.
This is consistent with the original super hypothesis — a `super` call is a
static invocation and already travels #67's path — and it removes the reason
the super rows were left `UNMODELED_BLOCKING`.

**Not applied.** `super/unproven` keeps its current disposition until the PM
rules. What changed is that its blocking reason is now explained rather than
unexplained, and the explanation is not about `super`.

## 7b. The two layers interact badly — layer 1 disarms layer 2

`MAOT_ALLOW_CONSTANT_FOLDING=1` is the program's existing falsification control
for the CFE layer. Running the same 2x2 with it set, VM backstop still on
(`-3` is `StageReplacement` refusing):

| CFE suppression | `install.CD` (direct) | `install.CW` (transitive) | `CD.1` | `CW.1` |
|---|---|---|---|---|
| ON (default) | `0` | `0` | `NEW` | `OLD-CONTROL` |
| OFF | `-3` refused | `-3` refused | `OLD` | `OLD-CONTROL` |

Two things follow, and the second was not visible before this run.

1. CD's success **depends on** the CFE suppression: with it off, CD stops being
   observed and is refused. The gate is not vacuous in either direction.
2. The backstop **is capable of catching CW** — it refuses it as soon as it can
   see the constant. In the default build it never gets the chance. The CFE
   blanks the annotation on the direct edge (`control()` inside `callControl`),
   which is exactly the evidence the backstop keys on, **while the constant
   itself still propagates through TFA into `callControl`'s summary**.

So layer 1 is not merely incomplete. It removes layer 2's evidence for the one
case that then escapes. `fn:control escapes=0` in the default build is not the
backstop deciding the case is safe; it is the backstop being handed nothing to
decide on.

`ND`/`NW` are refused by neither layer under either setting and are observed
under both, which is the expected behaviour for a call with no constant at all.

## 8. Proposal — three options, one recommendation

Presented for authorization. Nothing below is implemented.

**P1 (recommended end state) — suppress at analysis time, not annotation time.**
Clear the constant attribute on the Type a mutable declaration's summary
produces, so it never enters any caller's summary. Every transitive caller then
infers a non-constant result for free, with no call-graph fixpoint. This is the
smallest change that makes the failing cell behave, because it fixes the layer
the defect actually lives in.

**P2 (fallback) — transitive taint at annotation time.** Fixpoint over the call
graph marking any function whose result derives from a mutable call, and extend
`_callsMaotMutable` to those. More machinery, but it leaves TFA's lattice
untouched if P1 turns out to be structurally awkward.

**P3 (immediate posture, independent of P1/P2) — make the lie impossible.**
Section 7b shows the backstop already knows how to refuse this case; it is only
ever blinded to it. The minimal honest posture is therefore not new refusal
logic but preserving the evidence: have the CFE record that it suppressed a
constant at a mutable call site, so the VM refuses instead of silently
proceeding.
This does not make the case work; it converts a silent no-op into an install
refusal. On its own P3 is not an end state — it would permanently refuse a
perfectly ordinary shape (a mutable function returning a constant, called
through a helper) — but it stops `install = 0` from meaning nothing.

### Cost that must be measured before P1 or P2 is authorized

`IsMutableDeclaration` is the *selection* predicate, and under
`_maotSelectAllNonSdk` selection is every non-SDK declaration. Transitive
constant suppression would then reach most of the program, not a handful of
annotated functions. The blast radius on code size and optimizer quality at
Flutter scale is unknown and should be quantified on the m4 scale rig first.
I am not assuming it is acceptable.

### Falsification required of whichever option is authorized

Both directions, on the 2×2 and super fixtures already built:

- must flip: `CW` observes `NEW-CONTROL`; `CS` observes `NEW-CS`.
- must stay green: `CD`, `ND`, `NW`, `NS`.
- must still be able to fail: with `MAOT_ALLOW_CONSTANT_FOLDING=1` the defect
  reappears, so the gate is not vacuous.
