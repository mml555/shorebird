# G15 gate 2 — precommitted outcomes

Written **before** the releases are cut and before any launch, 2026-08-14.
Nothing below is edited afterwards; the verdict goes in a separate file.

## What is being run

The **repaired** fixture (append-only phase receipt at `/Documents/g15_receipt`,
receipt written as the first statement of `main()` ahead of the patch target),
**unpatched**, on device `R1`, twice:

| arm | release | cell | why this engine |
|---|---|---|---|
| **2A** | `killswitch_probe 1.0.4+1` | `80e493e4` (patches 0009 + 0010) | the engine `1.0.3+1` failed on **and** `1.0.2+1` passed on. The only engine where the failure can reproduce or be cured |
| **2B** | `killswitch_probe 1.0.5+1` | `40eaa0ef` (PROVEN lineage) | separates "the fixture works" from "the fixture works on the G15 engine" |

No patch is installed in either arm. Gate 2 asks one question — **does unpatched
`main()` execute, and can the instrument say so** — and nothing about backout.

## Reading rule, and it binds every row

**The receipt is read before the screen, and only lines carrying the launch id
printed on that screen count.** A screenshot without matching receipt lines is
not evidence about that launch. Two launches per arm minimum, because the fixture
alternates kill/render and a single launch cannot show both branches.

## Precommitted outcomes

| # | observation | verdict |
|---|---|---|
| 1 | launch A: `native launch` → `native engine` → `dart-main-entered` → `boot-probe-returned:boot-ok` → `arm:kill`, blank screen. launch B: same through `arm:render` → `first-frame`, screen shows `boot: boot-ok` / `route B value: OLD-kill` | **GATE 2 PASSES.** The instrument can distinguish all three states and the fixture is admissible for the three-arm gate. Note this does NOT by itself explain `1.0.3+1` — see row 5 |
| 2 | `native launch` and `native engine` present, **`dart-main-entered` absent** | **GATE 2 FAILS, and the failure is LOCATED**: the engine starts and user Dart does not. `1.0.3+1` reproduced. This is an engine/snapshot startup finding, not a fixture bug, and it would be the first positive observation of that state — the 2026-08-14 control could only guess at it |
| 3 | `dart-main-entered` present, **`boot-probe-returned` absent** | **GATE 2 FAILS, and the cause is exact**: `bootProbe()` throws or never returns on an **unpatched** release. Since `dynamic_interface.yaml` retains the whole of `package:killswitch_probe/main.dart`, this would say a Route-B-retained function is unsafe to CALL during boot — a Route B finding, not a fixture bug, and it would explain `1.0.3+1` completely |
| 4 | `native launch` present, `native engine` absent | the process launched and the engine never came up. **Not a gate-2 result** — investigate the install/embedding before interpreting anything |
| 5 | gate 2 PASSES on `1.0.4+1` (row 1) while `1.0.3+1` failed | **The `1.0.3+1` failure is UNEXPLAINED and must be recorded as unexplained.** "The repair fixed it" is not licensed: the repair changed the receipt, not anything that plausibly starts Dart. Record the residual openly rather than closing it by coincidence |
| 6 | red **INSTRUMENT FAULT** banner, either arm | **NOT AN ARM RESULT.** The marker or receipt mechanism failed; fix it before reading anything else on that screen |
| 7 | no receipt file, or no lines for the launch id on screen | the app did not run, or native and Dart disagree about the sandbox. First check: do `native` and `dart` lines appear in the SAME file? If not, `NSHomeDirectory()` and `Directory.systemTemp.parent` do not agree on this device and the fixture's two halves are writing to different places |
| 8 | 2A and 2B disagree (one passes, one does not) | the difference is the ENGINE, and that is exactly what arm 2B exists to isolate. Record which engine, and do not generalise from the passing one |

## What CANNOT be concluded from gate 2, whatever it shows

* nothing about crash-backout, tombstoning, or `0010`'s retry counter — no patch
  is in play;
* nothing about the `_runMain` seam, which gate 3 has already shown is not
  deliverable from `R3` until the platform-dill split is repaired;
* nothing about `1.0.3+1`'s cause unless row 2 or row 3 fires. Rows 1 and 5
  leave it open by construction.

## Rig state this arm mutates

* `~/.shorebird` `bin/internal/engine.version`: `40eaa0ef` → `80e493e4` → back to
  `40eaa0ef` for 2B. Claimed in §17.
* device `R1`: `killswitch_probe` upgraded in place, **not uninstalled** —
  uninstalling resets iOS Local Network consent and blocks the app on a modal
  before any code runs.
* the fixture's `pubspec.yaml` version and `shorebird.yaml`.

The CLI is deliberately **not** re-synced with `G4.1c`'s landed changes, so that
the fixture is the only variable against releases `1.0.2+1`/`1.0.3+1`.
