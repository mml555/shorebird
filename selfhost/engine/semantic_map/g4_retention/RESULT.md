<!-- cspell:words dartaotruntime dill bytecode dynmod devirtualize -->
# SM1-G4 — retention contract and measured cost

**Gate:** [#53](https://github.com/mml555/shorebird/issues/53) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07 · **Verdict: `checks_failed=0`,
`RETENTION_ENFORCEMENT=PARTIAL`.**

The harness is sound and every check was falsified. The *system* does not meet
one of #53's requirements, and that is the gate's substantive result rather than
a defect in the measurement:

> **Only one of the four retention classes fails closed. Two fail OPEN — the
> module loads, and the call site silently returns the release's own answer.**

Transcript: [`evidence/g4_retention.txt`](evidence/g4_retention.txt) ·
structured: [`evidence/g4_retention.json`](evidence/g4_retention.json) ·
confound: [`evidence/confound_pragma.txt`](evidence/confound_pragma.txt) ·
arms: [`evidence/arms.txt`](evidence/arms.txt) ·
curve: [`evidence/scale_curve.txt`](evidence/scale_curve.txt) ·
falsifications: [`evidence/falsification.txt`](evidence/falsification.txt).
Reproduce: `run_g4.sh` (`REMEASURE=1` rebuilds the cost curve).

## The confound runs first, and it is fatal

G0 recorded it as `VM_ENTRY_POINT_RETAINS_INDEPENDENTLY`: `@pragma('vm:entry-point')`
retains a symbol regardless of the contract, and SL1-G6A's
`missing_retained_import` control passed while measuring nothing for exactly
that reason.

The sharper half of the confound is that **the two mechanisms are
indistinguishable downstream**, and that is verifiable in the shipped compiler
rather than argued:

- `pkg/vm/lib/transformations/dynamic_interface_annotator.dart` lowers di.yaml's
  `callable:` list into real `@pragma('dyn-module:callable')` annotations;
- `pkg/vm/lib/transformations/pragma.dart` routes that pragma through the **same**
  `getEntryPointTypeFromOptions` handler as `vm:entry-point` — the cases sit at
  lines 184 and 253 — and both yield a `ParsedEntryPointPragma`.

So "retained by the contract" and "retained by a pragma" look identical at load.

**Presence is asserted against the built kernel, not the source text.** A source
grep cannot tell a pragma from a comment about one — this gate's own subject
explains the confound in its header — and di.yaml's entries never appear in the
source at all. `lib/dump_pragmas.dart` reads the annotations off the kernel and
splits them by origin:

    built with NO contract      source-pragma retained=0   contract retained=0
    built WITH the contract     source-pragma retained=0   contract retained=3

### The mechanism control

Asserting absence is not enough; the two mechanisms have to be shown *separable*
on this subject. `probe/host.dart` and `probe/host_pragma.dart` are identical
apart from a single annotation on the unnamed constructor:

| subject | `callable` withheld | result |
|---|---|---|
| clean | yes | **rc=134**, VM aborts |
| `@pragma('vm:entry-point')` on `Target()` | yes | **rc=0**, runs normally |

The pragma **masks** the withheld contract. An arm measured on such a subject
would pass while measuring nothing, which is precisely SL1-G6A's failure.
`run_g4.sh` refuses to score at all unless this reports
`PRAGMA_CONFOUND=CONTROLLED`.

**A correction the control forced.** The first version put the pragma on
`Target.work`, but the abort was on `Target.` — the unnamed constructor, which
the VM resolves first when a module instantiates a subtype. The pragma has to be
on the *same declaration* whose retention was withheld, or the control shows
nothing. Both hosts now declare `Target();` explicitly so they differ by exactly
one annotation.

## No instrument was used

SL1 read execution mode with `functionExecutionMode`, but that is a **banked
patch** applied only to the SL1 lane build. The frozen map lineage's
`dart:_internal` does not export it, and adding an instrument is outside this
gate's boundary. Retention is therefore measured **behaviourally**, through
mechanisms the frozen lineage actually ships.

The frozen lineage turned out to need no substrate split at all: its
`host_release_arm64` build already carries `dart_dynamic_modules = true`, so the
contract derivation and the load arms run on the same lineage as G0–G3.

## The arms: withhold each retention class in turn

Five builds differing by exactly one contract entry. `full` is the control — if
it does not dispatch to the patch, no refusal below is attributable.

| withheld | outcome | category |
|---|---|---|
| *(none — control)* | patch subtype answered | `CONTROL_DISPATCH_OK` |
| `callable` | VM aborts: `bytecode_reader.cc:1172 Unable to find function Target.` | **`FAILS_CLOSED`** |
| `extendable` | loads, call site returns `AOT-TARGET` | **`FAILS_OPEN`** |
| `can-be-used-as-type` | indistinguishable from the full contract | `NO_OBSERVABLE_EFFECT` |
| `can-be-overridden` | loads, call site returns `AOT-TARGET` | **`FAILS_OPEN`** |

### The finding

#53 requires each withheld class to **fail closed at load with an attributable
category**. Two do not. `extendable` and `can-be-overridden` produce a patch
that loads successfully and is then **silently ignored** — the call site
devirtualizes to the release's own body and answers `AOT-TARGET` while the patch
sits loaded and inert.

That is the failure mode this project has repeatedly been bitten by: success
reported, nothing done. It is recorded as a FINDING and is deliberately **not**
collapsed into the pass/fail axis — `checks_failed` counts only what would make
the measurement untrustworthy, and the enforcement result is reported separately
as `RETENTION_ENFORCEMENT=PARTIAL`. A green tick beside "every withheld class
fails closed" would have been the exact over-claim this lane exists to prevent.

`can-be-used-as-type` had no observable effect **on this shape**. That is
reported as "this corpus does not establish that it is required", not as "it is
not required".

`can-be-overridden` failing open is the same fact SL1-G4 established from the
compiler side — without it the optimizer devirtualizes the call site — now
observed from the runtime side on the frozen lineage.

## The contract, stated per declaration

#53's stop condition is: if retention can only be stated per library or per
release, stop and classify. It can be stated **per declaration** — all 23
declarations in the frozen corpus name their own entries — so the gate proceeds.

    callable             21 declarations
    can-be-used-as-type  15
    extendable           15
    can-be-overridden     6

Each row carries the **measured** enforcement, not the contract's intent, so a
consumer cannot mistake "the contract requires it" for "the runtime enforces
it". `gen_retention_rows.dart` **refuses to run** without `--enforcement`:

    gen_retention_rows: --enforcement is required: whether withholding a class
    actually stops a patch is measured by this gate's arms, never assumed

## The cost curve: measured, not extrapolated

SL1-G6B measured **+16,704 bytes (+1.88%)** for one declared-patchable member
and said explicitly that the number must not be multiplied naively. It must not.

| N | contract absent | contract present | delta | marginal | per member |
|---:|---:|---:|---:|---:|---:|
| 0 | 838,520 | 879,432 | **40,912** | — | n/a |
| 1 | 838,728 | 879,720 | 40,992 | 80 | 40,992 |
| 2 | 838,816 | 879,888 | 41,072 | 80 | 20,536 |
| 4 | 838,984 | 880,216 | 41,232 | 80 | 10,308 |
| 8 | 839,320 | 880,872 | 41,552 | 80 | 5,194 |
| 16 | 840,000 | 882,200 | 42,200 | 81 | 2,638 |
| 32 | 841,384 | 884,880 | 43,496 | 81 | 1,359 |
| 64 | 844,144 | 890,240 | 46,096 | 81 | 720 |
| 128 | 866,152 | 917,584 | **51,432** | 83 | 402 |

**The cost is a fixed floor plus a small marginal, not a per-member price.**

    delta(N) ~= 40,912 + ~82 N

At N=0 — *zero* patchable members — the contract still costs **40,912 bytes**:
that is the price of making the class extendable, nameable as a type, and its
constructor callable. Each additional patchable member then costs about **82
bytes**.

Naive multiplication of SL1's figure predicts **2,138,112 bytes** at N=128. The
measurement is **51,432** — the naive extrapolation overestimates by **42×**.

**Why the two single-member figures differ, stated rather than reconciled away.**
SL1's +16,704 was measured on `g4_host_solo`, a host with five call shapes over
a dispatch hierarchy; this gate's N=1 is 40,992 on a simpler host. Both are "one
declared-patchable member" and they differ by 2.5×, which is itself the point:
the per-member figure is dominated by **host shape**, not by the member, so it
is not a portable constant in either direction.

The curve was re-measured from scratch during the falsification pass and came
back byte-identical, so these figures are reproducible across independent builds.

## Every check was falsified

| mutation | must break | observed |
|---|---|---|
| confound reports `NOT_CONTROLLED` | the whole gate | refuses to score; `checks_failed=1` |
| control did not dispatch | attribution | "every refusal below is unattributable" |
| an arm is `UNCLASSIFIED` | category attribution | "its outcome is not attributable to the withheld entry" |
| rows claim `UNMEASURED` enforcement | the contract map | "23 row(s) claim a contract class whose enforcement was never measured" |
| drop N≥16 from the curve | release-scale claim | "missing N=[16, 32, 64, 128], so it was not measured at release scale" |

Plus the generator's own refusal: `gen_retention_rows.dart` will not emit a
contract at all without measured enforcement.

**The restore is worth reading.** The first restore attempt still reported
FAILED, correctly: mutation 5 truncated `scale.json`, and `run_g4.sh` reuses
that file rather than rebuilding an expensive curve every run — so restoring the
sources was not enough, and `REMEASURE=1` was required. A harness whose
"restored" run passes without rebuilding the mutated artifact would be
certifying a state it never re-measured.

The arm category surface is read from `run_arms.sh`'s own source, carrying
forward SM1-G3 round 3's rule that an inventory must be derived from the thing it
describes. That reader caught its own first version: it anchored `CAT=` to line
start and so missed the control arm's mid-line assignment, which surfaced as a
"stray category" failure rather than passing quietly.

## Acceptance (#53)

- [x] Retention contract derived per patchable declaration — 23 rows, each
      naming its own entries; the stop condition is not triggered
- [~] Every withheld-retention arm fails closed with a category — **every arm is
      categorised, but only `callable` fails closed.** `extendable` and
      `can-be-overridden` fail OPEN; recorded as findings, never as passes
- [x] Pragma-absence is asserted before any retention arm is trusted — against
      the built kernel, with a control showing a pragma *masks* a withheld
      contract, and the gate refuses to score without it
- [x] Release-scale retention cost measured, not extrapolated — nine points to
      N=128, and the naive extrapolation is shown to overestimate by 42×

## Not established by this gate

- **Whether the two fail-open classes can be made to fail closed.** G4 measures;
  it does not change the compiler or the contract format. What a release should
  do about a retention class that cannot be enforced at load is a G5/G7 policy
  question.
- **Whether `can-be-used-as-type` is required in general.** It had no observable
  effect on this shape. A shape that names the class in a type position would be
  needed to decide it.
- **No real application.** Wonderous and LocalSend stay frozen in G0; the subject
  is a single-class probe and the cost family is generated.
- **The cost curve is host-shaped.** The floor and marginal are measured on this
  probe. A real release's floor depends on how many classes it opens, which this
  gate does not sample.
- **Nothing about load latency or RSS.** SL1-G6B measured those; this gate
  measures retained AOT bytes only.
