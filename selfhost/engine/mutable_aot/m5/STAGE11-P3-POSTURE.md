# STAGE 11 — P3 applied: the interim fail-closed posture for #68

Status: **P3 APPLIED** (authorized). **P1 prototyped behind a flag, not
default.** #68 REOPENED by PM ruling; #67 direct/static routing stays
ESTABLISHED. No #64 movement, MonomorphicSmiableCall still paused, serializer
still parked.

Background: `STAGE10-CONSTANT-FOLD-HOLE.md` locates the defect.

## 1. What P3 actually does

The fact that makes the escape possible is knowable per DECLARATION: does this
mutable declaration's own analysis summary produce a constant result? It is
computed where it is still knowable — in TFA, before the annotation is emitted
and blanked — carried in the #66 metadata, and turned into a `kForbidden`
decision at the kernel-load seam.

| layer | file | change |
|---|---|---|
| CFE | `type_flow/transformer.dart` | `_maotSummaryResultIsConstant`, mirroring `_convertType` exactly including the nullable-empty case that folds to the null constant |
| CFE | `metadata/maot_declaration_id.dart` | `constantReturn` field, 4th payload byte, asked only for selected declarations |
| VM | `kernel_translation_helper.{h,cc}` | reads the 4th byte |
| VM | `kernel_loader.cc` | records `constant-folding/transitive-escape-risk` as `kForbidden` |

Deliberately coarse: it blocks declarations whose constant may never actually
escape. That is the accepted trade — a false refusal over a false success.

## 2. The posture behaves as ruled

One binary, five arms, real install path:

| arm | intermediary's own result | install | observed | blocking record |
|---|---|---|---|---|
| CD direct | — | `-3` | `OLD` | `constant-folding/transitive-escape-risk` |
| **CW wrapper** | constant | **`-3`** | `OLD-CONTROL` | `constant-folding/transitive-escape-risk` |
| ND direct | — | `0` | `NEW-ND` | `<none>` |
| NW wrapper | not constant | `0` | `NEW-NW` | `<none>` |
| CX wrapper | not constant | `-3` | unchanged | (callee constant — over-approximation) |

The record appears on exactly the constant-returning declarations and `<none>`
on the others. `fn:control` is blocked by the new record **alone**, so CW is
decided by this rule and nothing else.

The forbidden outcome — `install = 0` while the release constant survives —
does not occur in any arm.

## 3. Super: refused, but over-determined — stated as such

| arm | install | observed | blocking records |
|---|---|---|---|
| CS | `-3` | `OLD-CS` | constant-escape, MonomorphicSmiableCall, SingleTargetCache, MegamorphicCache, super/unproven |
| NS | `-3` | `OLD-NS` | MonomorphicSmiableCall, SingleTargetCache, MegamorphicCache, super/unproven |

`CS` satisfies "MUST refuse", but it would refuse without the new rule: an
instance method still carries four pre-existing blockers. **The super case does
not independently demonstrate P3.** What it does show is that the new record is
present on the constant-returning `BaseC` and absent on the non-constant
`BaseN` — the rule fires exactly where it should. The load-bearing
demonstration is `fn:control`, which the new record blocks on its own.

`super/unproven` stays blocking, per the ruling.

## 4. The permanent #68 regression arm

`fixture_m4.dart` now carries the dangerous shape as a first-class subject:
`folded()` (mutable, constant return) reached through `foldedCaller()`
(non-mutable, verbatim pass-through). The verdict condition is
`transitive_constant_never_reports_false_success`, and it is written as the
invariant rather than as an implementation:

```python
folded_after == 'NEW-FOLDED'
  or (folded_install == -3 and folded_after == 'OLD-FOLDED')
```

with both readings required to be present, so a missing key cannot pass it.
It currently passes via the refusal branch.

## 5. P3 falsified in both directions

`--maot_disable_constant_escape_block` was added because the posture had no off
switch, which fails twice: it cannot be shown that the new decision is what
causes the refusals, and there is no baseline to measure P1 against.

| | `install.CW` | `CW.1` | blocking records |
|---|---|---|---|
| P3 on | `-3` | `OLD-CONTROL` | `constant-folding/transitive-escape-risk` |
| P3 off | `0` | `OLD-CONTROL` | `<none>` on every declaration |

With the rule off, the defect returns exactly: success reported, release
constant kept. The gate is not vacuous in either direction.

## 6. What P3 costs the existing m4 suite — reported, not hidden

m4 under P3: **24 conditions, 12 unmet; 19 arms, 6 failed.** Every failure
traces to the interim refusal, and the values say so:

```
install.tiny=-3   install.constantish=-3   install.unreachable=-3    <- constant returns
install.chainA=0  chain.1=NEW-A                                      <- non-constant, still installs
```

| condition | why it fails under P3 |
|---|---|
| `conservative_posture_holds`, `hot_sites_observe_replacement`, `second_replacement_advances` | require `tiny` to install; it now refuses |
| `dead_release_declaration_addressable` | `releaseUnreachable` returns a constant |
| `blocking_dispositions_actually_block`, `escape_metadata_is_consumed` | their subjects refuse before the property under test is reached |
| `injected_{inlining,recognized,retention,tfa}_defect_is_caught`, `required_falsifications_detected` | the injected defect cannot change a verdict that already refuses |
| `scale_measurements_recorded` | the scale record names an older fork commit; re-measured in the P1 lane |

**The four injected-defect arms deserve separate attention.** They do not merely
fail — under P3 they lose the ability to discriminate, because their subjects
refuse before the injected defect matters. They are currently loud (red), not
silently green, so nothing is being falsely certified today. But if P3 were to
become the resting state, those arms would need non-constant subjects to keep
testing what they test. Flagged rather than fixed: repairing them is a change
to the falsification suite, and the suite is the thing that decides.

## 7. P1 prototype — behind `MAOT_P1_CLEAR_MUTABLE_CONSTANTS=1`, not default

Placed at `_DirectInvocation`, which is the single funnel: a dispatchable
invocation resolves each target through a `_DirectInvocation`, so interface,
dynamic and super calls are covered by the same hook as static ones. The
closure attribute is preserved — `TypeAttributes` carries both, and dropping
the closure alongside the constant would change closure inference for reasons
unrelated to mutability, widening the blast radius invisibly.

Selection now has ONE definition, `type_flow/maot_selection.dart`, because the
analysis has to ask the same question the transformer asks and two copies is
how a policy and its enforcement start disagreeing.

### Correctness matrix (P1 on, P3 disabled so P1's effect is observable)

| arm | required | measured |
|---|---|---|
| CW | `NEW-CONTROL` | **`NEW-CONTROL`** ✓ flipped |
| CD | green | `NEW` ✓ |
| ND | green | `NEW-ND` ✓ |
| NW | green | `NEW-NW` ✓ |
| CX | green | `NEW-XA/OLD-XB` ✓ |

Every install returned `0`.

**P1 and P3 are independent.** P3 keys on the declaration's own summary result,
which P1 does not change; P1 stops the constant entering *callers'* summaries.
So P3 must be relaxed for P1's benefit to be observable, and once P1 is
authorized the P3 rule should be narrowed or retired — that is the PM's call,
not a side effect of landing P1.

### super under P1

| arm | install | after install | after diagnostic swap |
|---|---|---|---|
| CS | `-3` | `OLD-CS` | **`NEW-CS`** (was `OLD-CS` before P1) |
| NS | `-3` | `OLD-NS` | `NEW-NS` |

The fold on the constant-returning super case is gone. The production install
is still refused, but now only by the four pre-existing instance-dispatch
blockers — the constant-escape record is absent. As in §3, super does not
independently demonstrate anything here; `CS.2` is the measurement that moved.
