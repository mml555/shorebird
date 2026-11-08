# P5-TARGET, Arm A — the exploit attempt, on the host

Harness `probes/p5_target_exploit.sh`. Host only, deliberately: the suspected
cross-target case was never installed on a phone. Arm B (the positive device
workflow) is separate and its outcome does not depend on this one.

## What was being attacked

`--target` is not part of the build-semantics authority (`RouteBBuildConfig`),
so a patch built from a different entry point is not refused on identity
grounds. The earlier five-row matrix could not turn that into a real exploit,
and both of the things that caught it were incidental. The last plausible shape
was a replacement body referring to a member **outside the retained app
libraries** — a package dependency — where whole-app-library retention stops
being the answer.

Fixture: `package:dep_probe/dep.dart` declares `depShared()` (used) and
`helperOnlyB()` (reached only from `main_b`). The patch, identical source in
every case, rewrites `sharedTarget()` in `package:app/shared.dart` so its body
calls `helperOnlyB()`.

## Setup assertion — the fixture discriminates

Before any conclusion, the release probe was asked whether `helperOnlyB` is in
each release, and it separates them:

| release | entry | artifact | probe answer for `helperOnlyB` |
|---|---|---|---|
| A | `main_a.dart` | `7a933416` | `TARGET_NOT_FOUND`, Function nodes = 0 |
| B | `main_b.dart` | `37ccf5a9` | `ONE_OR_MORE_QUALIFYING_CALLSITES`, nodes = 1 |

A non-discriminating fixture would have made every later row meaningless.

## Result

| case | release | patch target | outcome | rejection categories |
|---|---|---|---|---|
| control | A | `main_a.dart` (correct) | `COVERAGE_REJECTED` | `added=[dep.dart#helperOnlyB]` |
| suspect | A | `main_b.dart` (wrong) | `COVERAGE_REJECTED` | `added=[main_b.dart#bOnly, main_b.dart#main, dep.dart#helperOnlyB]` |

**BOTH REFUSE.** Against the interpretation precommitted in the harness header
before it ran, that is: *no exploit demonstrated; `--target` stays provenance,
explicitly open.* No target-identity gate is earned, and none was invented.

## Why "both refuse" means something here

"Both refuse" is worthless if the refusal is incidental, so the harness prints
the reason and the reason was checked. The control's refusal is the
**substantive** one: `dep.dart#helperOnlyB` is absent from release A and a patch
may not introduce members. That is the guard the fixture was built to test, and
it fires **with the correct target** — so it is not a target property at all.

Proven, not asserted, by the mechanism control: rebuild release A with the
dynamic interface retaining `package:dep_probe/` as well, hold the target
constant at A, and run the same patch.

| retained set | verdict | added |
|---|---|---|
| `package:app/` only | reject | `dep.dart#helperOnlyB` |
| `+ package:dep_probe/` | **accept** | none |

Retention scope decides membership; the target does not. The control could have
failed — had `helperOnlyB` still read as added with `dep_probe` retained, the
explanation would have been wrong and the harness says so in that branch.

## What is NOT claimed

The suspect case carries **incidental co-reasons**: `main_b.dart#bOnly` and
`main_b.dart#main` are also `added`. So the two arms differ in more than the
target, and the suspect case is **not a clean target-discriminating test**. It
is recorded, not counted. Concretely: this arm shows no exploit, and it does
**not** show `--target` to be safe. `--target` remains open provenance —
`_noteTargetProvenance` logs it and gates nothing.

One sub-shape stays untested: a member present in the release **kernel** but
dropped from the **snapshot**. Everything measured here is kernel-level
membership, which is what the coverage analyzer sees.

## Correction carried out of this arm

The fixture was built on the belief that `gen_kernel --aot` does not tree-shake,
so an unused `import 'main_b.dart'` in `main_a` would put `main_b`'s procedures
into every release kernel. That belief is **wrong**, and the measurement above
is what exposed it: `bOnly` and `main` are absent from release A despite the
import, and `helperOnlyB` moves in and out of the kernel purely with the
retained set.

TFA runs inside the `gen_kernel` pipeline, not only at `gen_snapshot`. What made
app libraries look un-shaken in g41d is the **dynamic interface retaining them
whole** — a different mechanism with the same appearance. The unused-import
trick could never have worked: the prepass kernel the interface is computed from
is itself an `--aot` kernel, so TFA had already dropped those procedures before
the interface could name them.

This supersedes the *conclusion* only. g41d's observation stands; its
explanation was underdetermined.
