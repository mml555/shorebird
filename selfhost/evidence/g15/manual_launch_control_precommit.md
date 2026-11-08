# MANUAL-LAUNCH CONTROL — precommit

Written 2026-08-17, **before the taps.** Tests whether `arm2_verdict.txt`'s
`NEW-kill` reproduces in its ORIGINAL configuration, with the launch method as
the only remaining suspect.

## Why this run exists

`hybrid_method_control_verdict.txt` showed that a run on the byte-identical engine
binary to the historically-working one produced `OLD-kill`. So the engine cell was
never the operative variable, and the leading candidate is the **launch method**:
every `OLD-kill` run used `idevicedebug` (debugserver attached); every `NEW-kill`
observation was a by-hand tap.

`arm2_verdict.txt`'s WHY BY HAND section warned about exactly this.

## The specimen — NOTHING of mine in it

| element | state | verified |
|---|---|---|
| app bundle | release 91's **original**, unmodified `Runner.app` | signature is the ORIGINAL `Apple Development: Pesach Brody (BRDNYM22XL)`; `codesign --verify --deep --strict` passes; I never wrote to this directory |
| engine | the app's own shipped `Flutter.framework` | `__TEXT,__text` = `136e3d64441c31c6c031fb3099eb58b45032220a515f87347d23ab11f7034aac`, **byte-identical to `80e493e4`'s published engine** and to `gate2_verdict.txt`'s recorded arm-2A value. (File hashes differ because Xcode re-signs and thins embedded frameworks — the section is the right comparator) |
| snapshot | release 91's `App.framework` | LC_UUID `E8665B59-FA7F-3933-8006-007FD00CC28E` |
| patch | **patch 59** — arm 2's exact 531 B artifact | bytes unmodified; on `stable` |
| device state | updater state deleted, alternation marker removed | patch re-downloads fresh, `boot_attempt_count` starts at 0 |

**No hybrid. No re-signing. No uploaded marker. No forced arm.** The only
deliberate intervention is deleting updater state so the patch is re-reached by a
real download — nothing is asserted.

## THE LAUNCH METHOD IS THE VARIABLE UNDER TEST

**The app MUST be launched by tapping its icon.** `idevicedebug`, `ios-deploy -d`,
`--justlaunch`, or any debugserver-attached path **invalidates the run**, because
that is precisely the difference being tested.

Screenshots via `idevicescreenshot` are fine — that reads the framebuffer and
attaches no debugger. Pulling files via `ios-deploy --download` between launches
is fine for the same reason.

## THE OUTCOME TABLE, precommitted

| observation | what it licenses |
|---|---|
| **`NEW-kill` on a render launch, patch `Installed`** | `arm2_verdict` REPRODUCES. The confound is in my method, and the follow-up is a **one-variable-at-a-time method bisect** — keep release and patch bytes fixed and reintroduce debugger attachment, then re-signing/hybridisation, then any other launch-path change, separately, until the flip appears |
| **`OLD-kill` on a render launch, patch `Installed`** | `arm2_verdict`'s configuration **no longer reproduces at all**. That is a larger and different finding — about the device, the OS, or the control plane — and needs its own investigation. It would NOT implicate the launch method, and it would put arm A's original `OLD-kill` in a new light |
| **no admissible render while `Installed`** | no control result. Preserve without interpretation |

## Admissibility — the same four, unchanged

1. the screen shows release 91's rendered UI (`G15 arm 2` + `route B value:`) and
   **no `launch <id>` line**;
2. the trace line count increases across the observed launch (patch activated on
   it);
3. `patches/1/state.json` = `Installed`, bracketed before and after;
4. patch active on that boot, trace `rc=0`, schema `v=4`.

**A screen read after `Bad{BootCrash}` is inadmissible** — that is the error made
once already in this cycle.

## Expected shape of the tap sequence, so the operator is not surprised

The fixture self-alternates and this is by design, not a fault:

* **odd taps** — a white launch screen, then the app vanishes. That is `arm:kill`,
  the fixture SIGKILLing itself.
* **even taps** — a blue screen reading `G15 arm 2` and `route B value: …`.

The first tap or two also let the updater download patch 59. `arm2_verdict`
observed exactly this pattern across four taps.

## STAGED PRE-STATE, verified 2026-08-17 before the taps

Read-only verification; nothing launched.

    patch 59                    track: stable                    (fetchable)
    /Library/Application Support   NO shorebird directory        (cleared; the
                                   updater will re-create it and re-download on
                                   the first tap, counter starting at 0)
    /Documents                  g15_armed ABSENT  -> TAP 1 IS A KILL LAUNCH
                                g15_receipt present but INERT — it is a leftover
                                from the release-96 era; release 91 predates the
                                receipt instrumentation and will not append to it,
                                so it must NOT be read as this run's evidence

The device is an iPhone 7 / iOS 15.8.8, `8cb4bc98…`, wired.

**The run is now blocked solely on the physical taps.** No further preparation is
possible without contaminating the variable under test.

## Scoring restrictions carried forward

* structural `tpool_*`/pool fields do NOT participate (this engine emits v4 and
  has none);
* boot-counter state is NOT read here — it belongs to the tombstone/retry lane;
* **arm A stays INCONCLUSIVE**, and is not re-scored by this run;
* **Claim 1 unchanged**: instrument established; positive locator not yet proven.
