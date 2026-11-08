# P6 · custom target — Arm B precommit

Written **before** the release is cut. Arm A (`engine/route_b/evidence/
p5_target_arm_a.md`) is closed and its outcome does not gate this arm: it asked
whether a *wrong* target can be exploited on the host and found no exploit. This
arm asks a different and purely positive question.

## The workflow under certification

> Release and patch an app whose entry point is **not** `lib/main.dart`.

Nothing else. Not "is `--target` safe" — that stayed open provenance in Arm A,
deliberately, and this arm does not reopen it.

## Rig custody

| item | state |
|---|---|
| device | iPhone 7 / iOS 15.8.8 / `8cb4bc982ddf6437b1952520edee80f898196c74`, **wired**. Confirmed with `idevice_id -l` and `ios-deploy -c`, since `devicectl` is blind to iOS 15 |
| holder | **this same P6 lane**, held continuously across flavor → defines → obfuscation. No foreign experiment holds it, so there is no hand-back to coordinate — this is *continuing* custody, and saying so is the record |
| installed fixture | the signed `flavored_app` bundle from the obfuscation arm |
| active patch | the obfuscation arm's patch |
| supersession | this arm installs a **new** release built from a different entry point, which replaces that state. Every prior arm's evidence is already banked in its own `VERDICT.md`, so nothing is lost by superseding it |
| participation | not part of any lifecycle/telemetry measurement — `MEASUREMENT_MODE.md`'s release-108 specimen and `dev.selfhost.airgapProbe` are untouched |

## The observables, fixed now

`lib/main_b.dart` renders its own screen — a layout that exists nowhere else in
the fixture, so which `main()` ran is directly visible rather than inferred.

| row | value | role | expectation after the patch |
|---|---|---|---|
| `entry` | `TARGET-B` | **control** | **unchanged.** `main.dart` does not import `main_b.dart`, so a default-target build cannot show this at all. Its presence is what proves the non-default entry produced the program |
| `release` | `CT-RELEASE-1` | **control** | **unchanged.** Separates "the patch executed" from "the device quietly picked up a different release" |
| `custom target` | `CUSTOM-TARGET-V1` | **the target** | reads **`CUSTOM-TARGET-V2`** |

## What counts as certification

All three, together, from a **by-hand icon tap**:

1. a baseline tap showing `TARGET-B` / `CT-RELEASE-1` / `CUSTOM-TARGET-V1`;
2. a patch built against that release **with the same `--target`**, published
   through the real producer path;
3. a later tap showing `CUSTOM-TARGET-V2` while both controls are unchanged.

## What does NOT count

* `shorebird release` or `shorebird patch` exiting 0. Per the P6 status
  vocabulary, a clean exit is not certification — the row is
  `SUPPORTED BUT UNCERTIFIED` until the device shows V2.
* Any launch with a debugger attached. `--justlaunch`, `ios-deploy -d`,
  `idevicedebug` all invalidate a run (`evidence/g15/
  manual_launch_control_precommit.md`). Install with `ios-deploy -b <bundle>`
  and **no** `-d`, which installs without starting anything.
* A rollback. It is hand-back hygiene, not evidence.
* `strings` finding `CUSTOM-TARGET-V2` in the patch artifact. That shows the
  compiler saw it, not that the device executed it.

## Negatives stay off the phone

No cross-target pair goes to the device — that was Arm A's host-only question
and it is answered. Nothing suspect (wrong flavor, wrong define, wrong target,
mismatched obfuscation, mangled identity) is installed here.

## Failure handling

If the device shows `CUSTOM-TARGET-V1` after a correct publication, the row is
recorded `SUPPORTED BUT UNCERTIFIED` with the observation attached. It is not
retried into a pass, and the fixture is not edited to make it pass.
