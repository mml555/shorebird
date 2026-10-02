# FOLDABILITY — paired control, PRECOMMIT

2026-08-17, **before the fixture is edited and before any build.**
Mirror of `target_kind_precommit.md`: **target kind is held FIXED (both
top-level); body foldability is the only intentional variable.**

## Why this is now the leading candidate

* `target_kind_verdict.txt` **experimentally eliminated target kind** — a
  top-level function's replacement executes on iOS (`NEW-TOP` on screen).
* `manual_launch_control_verdict.txt` **removed the release-91 counterexample**
  that previously blocked the fold/inlining family: `gate5_armA_fold_refuted.txt`
  rejected it on the grounds that 91 worked with the same shape, and 91's
  `NEW-kill` is no longer admissible as a proven working baseline.
* The surviving structural correlate is pool presence, and it tracks behavior:
  working targets `TPOOL_UNIQUE`, the failing target `TPOOL_ABSENT`.

## THE FIXTURE SHAPE

Two zero-argument top-level functions, identical signatures, same caller,
symmetric storage and display. The ONLY intentional difference is whether the
guard is compile-time foldable.

    // release
    String foldConst() =>
        1 == 2 ? 'UNREACHABLE-CONST' : 'OLD-CONST';

    String foldOpaque() =>
        DateTime.now().millisecondsSinceEpoch == -1
            ? 'UNREACHABLE-OPAQUE'
            : 'OLD-OPAQUE';

    // patch
    String foldConst() =>
        1 == 2 ? 'UNREACHABLE-CONST-PATCH' : 'NEW-CONST';

    String foldOpaque() =>
        DateTime.now().millisecondsSinceEpoch == -1
            ? 'UNREACHABLE-OPAQUE-PATCH'
            : 'NEW-OPAQUE';

Both top-level; both zero-arg; both called from `_routeBRead()`, the same caller
as every proven target; both stored in state and displayed adjacently.

### NO PRAGMAS ON EITHER — and a THIRD corpus difference, discovered while deciding

**`killswitch_app` carries ZERO `vm:never-inline`.** Its failing target is:

    String routeBValue() => 'OLD-kill';        // no pragma, no annotation

Every PROVEN `airgap_probe` target carries `@pragma('vm:never-inline')`. So the
historical corpora differ in **three** ways, not two:

    1. target kind        member vs top-level          -> REFUTED (target_kind_verdict)
    2. body foldability   constant vs opaque           -> UNDER TEST HERE
    3. pragma presence    never-inline vs none         -> NEWLY IDENTIFIED, uncontrolled

This pair is therefore written **pragma-free on both halves**, which matches the
failing target's shape and avoids introducing difference 3 into the very
experiment meant to isolate difference 2. Adding `vm:never-inline` — even
identically — would change the optimizer behaviour being measured.

**THE RISK THIS ACCEPTS, precommitted rather than discovered:** without
`vm:never-inline`, either function may be INLINED into `_routeBRead` outright. An
inlined callee is not reached through its `Function`, so its patch cannot take
effect. **If BOTH render OLD, inlining — not folding — may be the cause**, and
that maps to the table's "failed to reproduce" row, NOT to a foldability verdict.

The follow-up in that case is the SAME pair with `@pragma('vm:never-inline')`
applied identically to both. That remains a valid foldability test, because the
fixture's own documentation records that a literal is constant-folded by
type-flow analysis **even under `vm:never-inline`** — "the call still runs, its
RESULT is simply replaced at the call site" (`lib/main.dart:52-56`, citing
`selfhost/engine/killgate/target.dart`). So the pragma suppresses inlining
without suppressing the folding under test.

### Display

`member kind` and `top-level kind` are **PRESENTATION-RETIRED** for this specimen —
proof anchored to `evidence/g15/target_kind/screen_NEW-MEMBER_NEW-TOP.png` — and
replaced by `const fold` and `opaque fold`. Row count stays at **nine**; nothing
is compressed. `param`/`two params` remain presentation-retired (anchor:
`releases/38/r38_two_PARAM.png`). Their calls stay in place in every case.

Visible: `release`, `asset`, `assets patch`, `route B value` (OLD-rel control),
`private class` (OLD-pc control), `route B note`, `const fold`, `opaque fold`,
`code patch`.

## THE BEHAVIOURAL TABLE, precommitted — this is the verdict

| screen | interpretation |
|---|---|
| `NEW-CONST` + `NEW-OPAQUE` | **foldability REFUTED** |
| `OLD-CONST` + `NEW-OPAQUE` | **foldability ISOLATED as the discriminator** |
| `NEW-CONST` + `OLD-OPAQUE` | **contradicts the hypothesis**; investigate separately |
| both `OLD-*` | experiment **failed to reproduce Route B execution**; NO foldability verdict (see the inlining risk above) |
| any `UNREACHABLE-*` | body/control defect; **INVALIDATE** the run |

Unchanged controls required on the SAME screenshot, as with release 40:
`route B value: OLD-rel` and `private class: OLD-pc`.

## POOL STATE — SCORED SEPARATELY, AND SECOND

**Behaviour first.** `tpool_status` is recorded per target and does NOT define the
behavioural verdict.

| pool reading | what it licenses |
|---|---|
| const `ABSENT` + opaque `UNIQUE`, with `OLD-CONST` / `NEW-OPAQUE` on screen | **the strongest available result**: foldability, pool presence and behaviour all split together in one controlled specimen |
| both `UNIQUE`, only opaque renders | **pool presence is NOT the mechanism** |
| both `ABSENT`, opaque renders | `ABSENT` is again shown COMPATIBLE with successful execution |
| any `AMBIGUOUS` | preserve multiplicity; report both indices; **choose no slot** |

## THE STATIC PRE-CHECK — required BEFORE the device run

**"foldConst" must be more than a source-level label.** Before installing, the
shipped release bytes must be inspected far enough to establish that the two
call sites genuinely differ in the intended optimisation dimension:

* the CONSTANT arm's result is statically substituted or its call eliminated at
  the caller;
* the OPAQUE arm is a real, surviving call.

Method: locate both symbols in release 41's dSYM, disassemble `_routeBRead`'s
region in the preserved `App`, and show the asymmetry. The exact lowering need
not be predicted in advance — only that the artifact exhibits the distinction.

**If the release shows NO such asymmetry, the experiment does not test what it
claims** and is reported as unrun rather than scored. That check is what makes
this stronger than "two functions whose source looks foldable".

## Admissibility

1. both new rows visible in ONE screenshot with `code patch: N`;
2. `route B value: OLD-rel` and `private class: OLD-pc` unchanged on it;
3. both targets attached — `applied 2/2 targets` in one container preferred;
4. `rc=0`, `bc_post=1`, `uep_post_is_interpret_call=1` per target, so `OLD-CONST`
   is distinguishable from "never attached";
5. patch `Installed` bracketed before AND after; trace delta attributable to the
   launch; release preserved with LC_UUID asserted;
6. the static pre-check above passed.

**Attachment evidence does not substitute for the screen** — release 91's lesson.

## Standing claims, unchanged by this precommit

* Route B iOS end-to-end execution: **PROVEN** (six specimens, incl. a top-level).
* Target kind: **REFUTED** as a discriminator.
* release-91 `NEW-kill`: **contradicted**; not a working baseline.
* Arm A: **INCONCLUSIVE**.
* Claim 1: instrument established **and positive locator proven**; only
  `AMBIGUOUS` remains unexercised.
