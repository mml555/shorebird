# G15 — crash-backout and restart-required, the two symptoms `0007` did not touch

> At the end, a Dart-phase failure caused by a patch backs that patch out, a patch that
> is merely interrupted does **not**, and the manual API's restart-required answer is a
> fact the updater knows rather than one it infers.

| field | value |
|---|---|
| status | **BUILT AND TAKEN TO THE DEVICE 2026-08-14 — one half PROVEN, the other MEASURED FAILING.** Cell `80e493e4` carries `0009` + `0010`. **The false-backout half PASSES on hardware, twice** (`evidence/g15/arm2_verdict.txt`). **Crash-backout FAILS** — `Engine::Run` returns `Success` when the entrypoint is merely INVOKED, so a patch throwing inside `main()` banked three successes while crashing every launch (`evidence/g15/crashbackout_verdict.txt`). **The seam in part 1 of this design is still too early and must be re-chosen** — see *Where the seam actually belongs* in that verdict. Part 2 (the counter) is correct as designed and proven. Prior status: **DESIGN, REWORKED 2026-08-14. Earns nothing.** The prior design was refuted before it was built — see *The refuted composite* — and no code exists for this one. Host reading only; no probe, no release, no device |
| owns | nothing yet. Implementation will own `R3` + a mint + `R1` |
| excludes | when implemented: every other `R3` build and every other `R1` goal. Nothing today |
| blocked by | nothing for the design. Implementation is blocked on `R3` being free and on a mint it should ride rather than pay for alone |
| unblocks | §15's two named parity gates — *"a Dart-phase crash backs the patch out"* and the truthfulness half of §8's manual API |
| device needed | `R1` for the gate; none for the design |
| mint needed | **yes**, for implementation — the change is in the engine's call site and in `vendor/updater` |
| est. shape | design: done. Implementation: a day plus a mint, and the fixture work is the long pole because the decisive arms need a process killed at a chosen moment |

**Provenance.** Written against `2f830b16`. Every Rust citation below was read in
`vendor/updater/library/src/` in this repo at that commit. The engine-side seams
(`ReportLaunchSuccess` in the `Shell` constructor) are carried from `0007`'s diagnosis and
§14b and are **not** re-verified here — `R3` was deliberately not opened.

## Why this is the piece it is

`0007` fixed the third symptom (a second engine running unpatched AOT) and is PROVEN on
device. The other two — crash-backout and restart-required — are a **different
mechanism** and share it: `ReportLaunchSuccess` fires in the `Shell` **constructor**,
before the root isolate exists, so "launch succeeded" is banked before the patch has had
any opportunity to fail.

It deliberately does **not** include the second-engine work (done), the activation model
itself, or anything about *which* patch is selected — only when a boot is judged to have
succeeded, and what follows from that judgement.

## The refuted composite, and why it is worth keeping on the page

The obvious repair is *move the success call later*. The first design did exactly that —
Seam C (first frame) with a Seam-B-derived fallback deadline — and an adversarial review
killed it before anything was built:

> Any process death inside the window leaves `currently_booting_patch` set, and the next
> init marks a perfectly good patch `Bad{BootCrash}`.

The window under that design spans the whole of startup, and the deaths that land in it
are **ordinary**: the user swiping the app away during launch, the iOS launch watchdog
(`0x8badf00d`), jetsam killing the process under memory pressure, or a launch that is
backgrounded before it ever draws. None is caused by the patch, and each would tombstone
it.

**The root cause is not the seam; it is the inference.**
`detect_boot_crash_on_init` (`cache/lifecycle.rs:665-673`) concludes "this boot crashed"
from "the breadcrumb is still set" — an inference from *absence of evidence*. Absence of
a success record is equally consistent with *crashed* and with *died for unrelated
reasons*. Moving the success point later does not add a discriminating signal; it only
grows the population of benign deaths that get misread. **A design that widens the window
without adding evidence trades one wrong answer for more of them.**

Two properties of the wrong answer make this worse than it first looks. `mark_bad` is a
**tombstone**: `record_boot_success` documents that on cleanup *"Bad tombstones survive,
others are forgotten"* (`lifecycle.rs:620-623`, `cleanup_older_than` at `:822`), so a
false `Bad` is permanent. And it is **silent** — the device reports a
`PatchInstallFailure` event whose message reads `crash_recovery: patch N failed to boot`
(`updater.rs:246-252`), so a false backout arrives labelled as a real one, and nobody
learns it was wrong.

## The design

Three parts. The first two are independent; either alone is an improvement, and the
argument for doing both is that they fail differently.

### 1. Bank success at the earliest SUFFICIENT point, not the latest safe one

The property the gate exists to test is narrow: **did patched Dart execute without the
patch breaking it?** A patch that is going to fail does so at snapshot load, isolate
spawn, or the first interpretation of a replaced body — all of which precede the root
isolate finishing `main()`'s synchronous prologue.

So the success point should be *the root isolate having executed patched Dart*, not the
first frame. Compared with the two candidates already considered:

| point | proves | window |
|---|---|---|
| `Shell` constructor (today) | **nothing** about the patch — the isolate does not exist yet | ~none, and worthless |
| root isolate past `main()`'s prologue | exactly the property in question | milliseconds |
| first frame (refuted) | more than needed — that the whole UI works | the entire startup |

This is the point that is *semantically* narrowest while being only slightly later in
wall-clock than today's. It excludes swipe-away, watchdog and jetsam almost entirely,
because each needs the app alive long enough for a human or the OS to act.

### 2. Count consecutive failures; never conclude from one

Even a millisecond window has residual benign deaths. The discriminating signal is not
available *within* a boot — but it is available *across* boots:

> A patch that genuinely breaks Dart fails **every** time. A benign death is uncorrelated
> with the patch and does not repeat.

So add `boot_attempt_count` beside the existing `boot_started_at`
(`lifecycle.rs:616-618`), increment it in `record_boot_start`, clear it in
`record_boot_success`, and have `detect_boot_crash_on_init` mark `Bad{BootCrash}` only
once it reaches **N**. Below N it re-arms the same patch and lets the next boot decide.

**The tradeoff, stated honestly:** a genuinely broken patch now costs N crashed launches
instead of one. With N = 2 that is exactly one extra crash, on a device that has already
crashed once.

**The asymmetry is the whole argument.** A *delayed* backout costs one additional crash on
a device that is already crashing, and it is self-correcting. A *false* backout
permanently removes a good patch from a device, is invisible, and is reported as a
success of the safety mechanism. This project's stated failure preference — *"erring costs
a rejected patch, never a wrong one"* — points the same way once the subject is a patch
already on a device: the cheap error is to retry, and the expensive one is to tombstone.

### 3. No deadline

The refuted composite carried a wall-clock fallback deadline. Drop it. A deadline makes
correctness a property of device speed, and trips on a slow device, a debugger
breakpoint, or a launch that is backgrounded and resumed. It adds a failure mode and no
evidence.

### What falls out for restart-required

With (1), `last_booted_patch` is only ever set for a patch whose Dart actually ran, so
*"which patch is running"* becomes a fact the updater holds rather than one it guesses,
and restart-required is `next_boot_patch != last_booted_patch`.

That is the second symptom closed by the same change, and it explains §14b's claim that
the API can report something **wrong** rather than merely unverified: today success banks
in the `Shell` constructor, so `last_booted_patch` can name a patch whose Dart never ran —
and the API will then answer "no restart needed" about a patch that is not running.

## Preconditions

1. `R3` free and GREEN — `dart_patches.sh --verify`. Check §17 before claiming.
2. `cd vendor/updater/library && cargo test --lib cache::lifecycle` → **66 passed**
   (measured 2026-08-14, on this tree, with `CARGO_TARGET_DIR` redirected out of the repo).
   This is the regression baseline; it must still pass after the state change.
3. A fixture that can be killed at a chosen moment during launch. **This does not exist**
   and building it is step 1 — see *Do not* for why `twoengine_app` is not it.

## Precommitted outcomes

Written before implementation, and deliberately including the arms the refuted design's
table could not see. **Arm 2 is the one that exists to catch this design's own worst
case; a table without it is not a table.**

| # | arm | observation | verdict |
|---|---|---|---|
| 1 | good patch, ordinary launch | success banked; `currently_booting_patch` clear; patch still active next boot | baseline. Proves nothing on its own |
| 2 | **good patch, process killed before the success point** (swipe-away or `kill -9` at a chosen moment) | patch is **still Installed and still selected** next boot | **the false-backout arm.** A `Bad{BootCrash}` here is a FAILURE of this design, not a success of the safety mechanism |
| 3 | genuinely broken patch (Dart-phase failure) | `Bad{BootCrash}` after **N** consecutive attempts — and NOT before | the gate works. Marking Bad at attempt 1 is a failure: it means the counter is not consulted |
| 4 | broken patch with one benign kill interleaved | still reaches `Bad` | counting must not reset on anything but success |
| 5 | restart-required, patch downloaded but not booted | API answers **true** | §8's row |
| 6 | restart-required, patch booted and running | API answers **false**, and it is true | today's guard can answer this wrongly; that is the point |
| — | the app merely launches and looks fine | **NOT a `G15` result** | "it worked" is the reading this gate exists to make impossible |

Arm 2 must be run **more than once**. A single survival is consistent with the kill having
landed outside the window by luck; the claim is about the window, so the kill has to be
placed deliberately and repeated.

## Exit criteria

* **BUILT** — arms 1-6 pass on the host against a real updater state directory, plus
  `cargo test --lib` green including new tests for the counter.
* **PROVEN** — arms 2, 3 and 6 on `R1`, through the real release/patch path, against a
  minted cell. Nothing less earns it. Per the status rule, a green `cargo test` earns
  **nothing**.
* **NOT RUNNABLE** — if the kill-at-a-chosen-moment fixture does not exist, say so
  rather than booking the phone.

## Do not

1. **Do not use `twoengine_app` for arm 2.** It is not headless: `_boot(String label)`
   ends in `runApp(...)` and BOTH entrypoints call it, so "engine two never draws" is
   false of that fixture. The prior design's arm 4 assumed otherwise and was a false green
   on exactly that ground.
2. **Do not reintroduce a deadline** as a "safety net". See part 3.
3. **Do not widen the window and call the residual acceptable** without arm 2 in the
   table. That is the refuted design, restated.
4. **Do not read a `PatchInstallFailure` event as evidence the mechanism worked.** Its
   message says `failed to boot` for both a real crash and a false backout.

## Open questions

* **N.** 2 is the smallest value that discriminates and costs one extra crash; 3 is more
  robust against a device with a flaky launch path and costs two. Decide with the
  asymmetry argument above in view, and record the reasoning next to the constant.
* **Where the counter lives.** `boot_attempt_count` in `pointers` beside `boot_started_at`
  is the obvious place, but `pointers` is persisted state with its own compatibility
  story — check what an older updater does when it reads a pointers file carrying a field
  it does not know.
* **Whether the engine seam can be reached from Dart at all**, or whether it needs a new
  C API entry beside `shorebird_report_launch_success`
  (`c_api/engine.rs:214`). This is the one part of the design that `R3` must confirm.
