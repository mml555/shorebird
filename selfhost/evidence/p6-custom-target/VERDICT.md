# P6 · custom target — CERTIFIED

**The workflow "release and patch an app whose entry point is not
`lib/main.dart`" works end to end on a physical device.**

Release `1.9.0+1` cut with `--target lib/main_b.dart`; patch 1 built with the
same `--target`; observed by hand on iPhone 7 / iOS 15.8.8 (`8cb4bc98…`).

| row | baseline tap | after the patch | role |
|---|---|---|---|
| `entry` | `TARGET-B` | `TARGET-B` | control — **unmoved** |
| `release` | `CT-RELEASE-1` | `CT-RELEASE-1` | control — **unmoved** |
| `custom target` | `CUSTOM-TARGET-V1` | **`CUSTOM-TARGET-V2`** | the target |

Rendered evidence: `01_patched_tap.png`, read directly rather than transcribed.

## What makes this evidence rather than a green check

**The custom target demonstrably took effect.** Checked in the shipped AOT
(`945f3d36af9b046d`) before anything reached the phone, and the discriminating
half is an ABSENCE:

| marker | origin | count |
|---|---|---|
| `TARGET-B`, `CT-RELEASE-1` | `main_b.dart` | 1, 1 |
| `CUSTOM-TARGET-V1` | `main_b.dart` | 2 (both ternary branches) |
| `FLAVORED-FIXTURE-V1`, `BAKED-INTO-RELEASE`, `obf` | `main.dart` | **0, 0, 0** |

`main.dart` is unreachable from `main_b`, so a default-target build would have
produced the exact opposite set. That is what separates "the custom target was
honoured" from "a patch landed on the program we always build".

**The screen itself identifies the entry point.** `main_b.dart` renders its own
three-row layout, which exists nowhere else in the fixture. Had `main.dart`'s
`main()` run, the device would show five different rows. So which `main()`
executed is observed, not inferred.

**The controls separate patch execution from release substitution.** `TARGET-B`
and `CT-RELEASE-1` are consts in the release; if the device had quietly picked up
a different release, they would have moved with the target.

**No debugger touched the run.** Installed with `ios-deploy --bundle` and no
`-d`/`-L`, which installs without starting anything; both observations are from
by-hand icon taps. `idevicescreenshot` attaches no debugger.

## Why `--target` is still recorded as OPEN

This row certifies the **workflow**. It does **not** claim a mismatched
`--target` is safe, and P5-TARGET stays open on purpose.

Arm A (`engine/route_b/evidence/p5_target_arm_a.md`) attempted the exploit on the
host and found none. Both the control and the suspect case were refused, and the
control's refusal is the substantive one: a replacement body calling a member
outside the retained libraries is an `added` member, **with the correct target
too**. A mechanism control proved the cause rather than asserting it — retain
`package:dep_probe/` as well, hold the target constant, and the same patch flips
to `accept`. Retention scope decides membership; the target does not.

So no target-identity gate was earned and none was invented. The suspect case
also carried incidental added members, which makes it a poor
target-discriminating test — recorded, not counted. The honest position: no
exploit demonstrated, and `--target` not shown safe. It stays logged provenance
(`releaseTarget`, plus a `P5-TARGET OPEN` line at patch time).

The wrong-target case was never installed on the phone, per the precommit, and
should not be: it is a host question and it was answered on the host.

## What this arm cost, and what it says about the rig

Three blockers, none about custom targets — all in `ARM_LOG.md`:

1. **`cps-ios` stamps a stale JWT issuer** (`169.254.189.3`, an address that no
   longer exists) while serving as `10.0.0.7`, so a fresh login would fail just
   as the expired token did. Sidestepped with the bootstrap API key; **not**
   fixed, because that needs the container recreated and `MEASUREMENT_MODE.md`
   freezes lifecycle behaviour until the sample threshold. **Open debt** for the
   measurement lane.
2. **Two `shorebird` entrypoints, same version string, different caches** — the
   repo tree's is uniformly stock, so `--patchable_static_calls` was rejected by
   the first `gen_snapshot`. Fixed by using the installed entrypoint after
   verifying no product-code delta; explicitly **not** by copying a binary into
   the stock cache.
3. **A vacuous check of my own.** I tested for the Route B flag with
   `gen_snapshot --patchable_static_calls --version` and read exit 0 as
   "supported". That test cannot fail — `--version` exits 0 whatever flags
   precede it — so the stock binary passed a check it had just failed in a real
   build, and it sent me looking in the wrong tree. The honest test is whether
   the flag name is in the binary (`strings … | grep -c
   '^patchable_static_calls$'`), which separates the caches 2-vs-0.

Also recorded: the version bump skipped `1.8.0+1` because that is the identifier
of the frozen telemetry specimen (`release 108 / 1.8.0+1, patch 1`) on this same
deployment.
