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

### Negative control: unrelated constant propagation must survive

`plainConst()` is ordinary and NOT selected; `callPlainConst()` is the same
wrapper shape as `callControl()`. Both halves are `vm:never-inline` on purpose
— if `plainConst` could be inlined, a literal at the caller would prove
nothing, because inlining would put it there whether or not propagation still
worked.

Measured structurally in `_main`'s own final code, same binary, both runs:

| literal loaded by `_main` | P1 off | P1 on |
|---|---|---|
| `"PLAIN-CONST"` @ pool #6512 — ordinary, not selected | **YES** | **YES** ✓ |
| `"OLD-CONTROL"` @ pool #624 — mutable, selected | **YES** (the defect) | **NO** ✓ |

P1 removes the fold for the mutable declaration and leaves unrelated
propagation exactly where it was.

### Blast radius on the correctness fixture

```
selected               11
cleared_declarations    7      distinct mutable declarations whose constant was stripped
cleared_applications   14      invocation results stripped
member summaries traced 1830
downstream summaries whose inferred constant changed:  1
    1 -> 0   package:m5fold/...::callControl
```

One downstream summary changed, and it is the intermediary itself. `callX` did
not change — its result was never constant — and `callPlainConst` did not
change. This is the small-fixture number, not a scale number; the scale lane
is what decides.

## 8. Scale lane — the blast radius at the upper bound

Corpus: the m4 scale rig's representative Flutter application (MaterialApp, a
StatefulWidget with an AnimationController, a 500-row ListView.builder),
compiled against the real `package:flutter`. Selection is
`MAOT_SELECT_ALL_NON_SDK=1` — every non-SDK declaration with a body, app and
framework alike. **This is the upper bound, not a typical posture.**

Fork `013b3b14a96`, clean, both lanes.

| metric | P1 off | P1 on | delta |
|---|---|---|---|
| selected declarations | 7,399 | 7,425 | +26 |
| AOT elf bytes | 43,519,248 | 43,707,936 | **+188,688 (+0.43%)** |
| kernel bytes | 27,325,680 | 27,359,224 | +33,544 (+0.12%) |
| compile seconds | 42.61 | 40.99 | −1.62 |
| optimizer decisions recorded | 82,184 | 82,573 | +389 |
| devirtualizations recorded | 11,244 | 11,371 | +127 |
| prevented inlines | 1,366 | 1,374 | +8 |
| indirect call sites | 17,913 | 18,113 | +200 |

Reading these honestly:

- **+0.43% AOT growth** at the absolute upper bound — every non-SDK
  declaration mutable at once.
- **The compile-time delta is not a speedup.** One sample per lane, and the
  sign is negative, which no mechanism here predicts. It is noise, and it is
  reported as noise rather than as a result.
- **The selected count itself moves (+26), which is the mechanism showing
  through.** Constants drive dead-code elimination; removing them keeps more
  code alive, so more declarations survive to be indexed, and the AOT grows.
  The size delta and the declaration delta are the same effect seen twice.

### A measurement error caught before it was reported

The first attempt at the trace-derived counts was wrong and would have been
reported as a result. `MAOT_P1_TRACE` named one path and the writer truncated,
so every `gen_kernel` call in a multi-lane run overwrote the previous one. The
two traces being compared were different lanes:

```
trace_off: selected 26590    <- the select-all lane
trace_on:  selected 0        <- the CONTROL lane; nothing selected, cleared 0
```

`cleared 0` there means "wrong lane", not "no effect", and the two are
indistinguishable from the number alone. The trace now appends one record per
compilation and the comparison asserts both records name the same lane rather
than trusting the filename.

### Corrected trace counts

Both records name the same lane (26,590 selected), so this is like for like.

| | value |
|---|---|
| mutable declarations whose constant was cleared | **444** |
| invocation results cleared (applications) | 2,213 |
| member summaries traced | 10,163 |
| **downstream summaries whose inferred constant changed** | **52** (all constant -> not) |

The two selection numbers are different things and should not be compared:
26,590 is `maotSelectedIds` on the UNSHAKEN component, 7,399 is what survives
tree shaking into the registry.

The shape of this is the useful part: **444 declarations had a constant
stripped, and only 52 other summaries changed as a result.** The escape is
real but narrow -- most mutable constants never reach an intermediary whose
own result is constant, which is the same boundary the CX arm measured on the
fixture.

A whole-program count of members with a constant result reads 3,505 -> 3,470,
but those totals are over slightly different member sets, because P1 changes
what survives tree shaking. The like-for-like figure is the 52 above; the
totals are context, not the measurement.

## 9. Optimizer/gate regressions under P1

m4 run with `MAOT_P1_CLEAR_MUTABLE_CONSTANTS=1` and the P3 rule relaxed, so
P1's effect is what is being measured:

| | P3 (shipped interim) | P1 prototype |
|---|---|---|
| arms failed | 6 of 19 | **2 of 19** |
| conditions unmet | 12 of 24 | **3 of 24** |
| `tiny` | `OLD-TINY -> OLD-TINY -> OLD-TINY` | `OLD-TINY -> NEW-TINY -> NEW-CONST` |
| `install.unreachable` | `-3` | `0`, version `PATCH_CODE:v2` |
| `immutableCaller.1` | `OLD-TINY/OLD-CONST` | `NEW-TINY/NEW-CONST` |
| `folded` (the new arm) | refused (`-3`) | **observed** (`install 0`, `NEW-FOLDED`) |

P1 restores what the interim posture gives up. The new regression arm has now
exercised **both** of its branches — refusal under P3, observation under P1 —
which is what an invariant-shaped arm should be able to do.

`scale_measurements_recorded` failed only because the scale evidence named an
older fork commit; regenerated.

### The two arms that still fail, and why it matters

**H04 and H17 go vacuous under P1.** Both are falsification arms that REMOVE
the constant-folding protections and require the defect to appear:

```
H04  folding re-enabled:  8 call sites emitted, 0 escapes, install 0, call NEW-TINY
H17  both layers removed: 0 decisions, install 0 succeeds, caller NEW-CONST
```

Neither produced the defect. They disable the front-end suppression and the VM
backstop — but P1 is a third layer they do not know about, and it removes the
constant during the analysis, so there is nothing left to fold.

Two honest readings, and the difference matters:

1. **As run**, P1 was forced on for every build in the suite, the
   defect-injection builds included. The arms could not produce the defect
   because the mechanism they were trying to defeat was still on.
2. **If P1 ships as default**, the same thing happens permanently.

Either way the conclusion is the same and it is a precondition, not a
footnote: **P1 cannot become the default until H04 and H17's injection also
disables P1.** An arm that can no longer produce the defect can no longer
prove the gate detects it, and a green H04/H17 under P1 today would be exactly
the vacuous pass this programme refuses.

The arms are currently RED, so nothing is being falsely certified. They are
failing for the right reason and saying so.

## 10. The P3 fail-open surface, measured

`index()` runs after TreeShaker and SignatureShaker, which replace member
nodes, while the analysis keyed its summaries on the members that existed
before them. For any member whose summary cannot be found, the constant-return
test silently answers "no" — the wrong direction for a fail-closed posture.

At Flutter scale, counted rather than argued:

```
selected 26590    selected_without_summary 3
```

**3 declarations out of 26,590.** The node identity survives the shakers for
everything else. Those three would be answered "not constant" by P3 whatever
they return, so they are the fail-open surface; it is small enough to name
rather than estimate, and it is now a number that a later run can be compared
against.

## 11. Where this leaves the decision

Everything the ruling asked for is measured. What the PM rules on:

- **P1 works and is cheap at the upper bound.** +0.43% AOT, 52 downstream
  summaries changed out of 10,163 traced, and it restores m4 from 12 unmet to
  3 unmet.
- **P1 has a precondition that is not optional.** H04 and H17 go vacuous under
  it. Their injection must also disable P1 before P1 can be default. The same
  will be true of P2 or of any mechanism that removes the constant earlier
  than the layers those arms know about.
- **P3 and P1 are independent.** Authorizing P1 is also a decision about
  narrowing or retiring the P3 rule, because P3 keys on the declaration's own
  summary result, which P1 does not change.

Not claimed: that #68 is ready to close, that super is resolved, or that the
interim posture is acceptable as a resting state.
