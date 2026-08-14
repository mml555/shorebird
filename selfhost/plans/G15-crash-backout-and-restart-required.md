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

## The seam, RE-CHOSEN 2026-08-14 from source — supersedes §1 of the design below

`0009` shipped the design below and **FAILED on device**, then the control run
showed the device arm could not have measured what it claimed. The seam question
was therefore re-answered by reading the R3 tree instead of the rig, and the
answer is exact.

### Why no point inside `Engine::Run` can ever work

`InvokeMainEntrypoint` (`runtime/dart_isolate.cc:882`) does not call `main`. It
calls `dart:ui::_runMain` (`lib/ui/hooks.dart:406`), which calls
`_startMainIsolate` → `_delayEntrypointInvocation`
(`third_party/dart/sdk/lib/_internal/vm/lib/isolate_patch.dart:298`):

```dart
final port = RawReceivePort();
port.handler = (_) { port.close(); ...; entryPoint(); };
port.sendPort.send(null);
```

`main` is **posted to the message queue**. `InvokeMainEntrypoint` returns true
once the message is sent, `LaunchRootIsolate` returns, and `Engine::Run` returns
`RunStatus::Success` (`shell/common/engine.cc:293`) — **all before one line of
user Dart has run.** So `0009` is not "too early by a margin"; it is structurally
incapable of observing a Dart-phase outcome, and so is every other point inside
`Run`. The crash-backout verdict's stated mechanism ("executes while `Engine::Run`
is still on the stack") is wrong; the observation it drew from was real.

### The seam, located

`third_party/tonic/dart_message_handler.cc`, `OnHandleMessage` — one
message-loop turn:

```cpp
result = Dart_HandleMessage();        // :115  <-- the first normal turn IS main()
error  = CheckAndHandleError(result);
...
if (error) { UnhandledError(result); } // :133  <-- POSITIVE failure signal
```

Both signals the gate needs exist at one place, **one turn after `Run`**.

### The three requirements, and why this seam is the only candidate that meets all three

| | requirement | `Engine::Run` (`0009`) | first frame | **first turn + `UnhandledError`** |
|---|---|---|---|---|
| 1 | a good boot eventually banks success | yes | **not always** — a headless or background-prewarm launch may never render, and two of those tombstone a GOOD patch via the counter | yes — every live isolate pumps a first turn |
| 2 | a `main()` throw positively reports failure before success is banked | **no, in principle** | only by ABSENCE, costing 2 crashes | **yes, positively**, same turn |
| 3 | a kill before the success point stays retryable | proven (arm 2) | window widens to all of startup | window widens by ~one turn — the smallest increment that satisfies 1 and 2 |

Requirement 3 is the one that punishes the obvious fix, and the counter's exact
semantics are what make it sharp: `0010` counts **consecutive un-succeeded boots
of the same patch** against `BOOT_FAILURE_THRESHOLD = 2`. So a later success point
does not merely widen a window — it widens the window in which **two** benign
deaths tombstone a good patch. Arm 2 proved n = 1 survives *at `0009`'s seam*;
that result does not transfer to a later seam and must be re-run wherever the seam
lands.

**First-frame's rehabilitation is partial, not complete.** `0010`'s counter does
answer the original objection (a single benign death no longer tombstones). But
the control run surfaced a second objection the counter does not answer: a launch
that legitimately never renders never banks success at all, so the patch stays
un-succeeded forever and the counter eventually works against a **good** patch.
Positive failure reporting removes the need to infer a crash from silence, which
is what makes the earlier seam viable — so first-frame is no longer needed.

**The two mechanisms compose, and that is the point `0009` missed.** `0009` tried
to make one signal do both jobs. Split them: `UnhandledError` reports a crash
POSITIVELY, and `0010`'s counter handles ABSENCE — which, once crashes report
themselves, can only mean a benign death. Each covers exactly what the other
cannot.

### The four questions asked of `OnHandleMessage` — ANSWERED FROM SOURCE, and it FAILS three

Asked before instrumenting anything, precisely because "inside `Dart_HandleMessage`"
is the kind of nearby property `0009` died on. The seam does not survive them.

**1. Is this specifically the message that invokes `main()`? NO — it is an ordinal,
not an identity.** `OnHandleMessage` handles whatever is at the head of the queue.
tonic tracks `handled_first_message()` but only to decide pause-on-start. Nothing
pins `main`'s port message to the first turn; any other message delivered first
(timer, platform message, plugin-registrant callback) banks success before `main`
runs. That is `0009` again, displaced by one turn.

**2. What exact return means success?** `Dart_HandleMessage()` returning a
non-error handle with `error == false` after `CheckAndHandleError`. Its meaning is
narrow and exact: *that message's handler ran to completion without an unhandled
error.* For a synchronous `main`, that is `main` returning. See question 4 for
what it means otherwise.

**3. Does a startup unhandled error actually arrive at `UnhandledError(result)`?
ONLY IF THE APP LETS IT — and that is disqualifying.** There is a Dart-side hook
above the C++ one: `lib/ui/hooks.dart:399`

```dart
@pragma('vm:entry-point')
bool _onError(Object error, StackTrace? stackTrace) =>
    PlatformDispatcher.instance._dispatchError(error, stackTrace ?? StackTrace.empty);
```

and `_dispatchError` (`platform_dispatcher.dart:1456`) returns `_onError!(error,
stackTrace)` when the app installed one. Returning **true means handled**, the VM
does not propagate, `Dart_HandleMessage` returns no error, and tonic's
`UnhandledError` **never fires**. Installing `PlatformDispatcher.instance.onError`
returning true is the documented, mainstream Crashlytics/Sentry pattern. So the
C++ seam's coverage is **application-controllable**: an ordinary error-reporting
app would make a broken patch report success. A safety contract whose correctness
depends on application code is not a safety contract.

**4. `async main`? THE SEAM MEASURES SCHEDULING, NOT COMPLETION.** `_runMain`
discards the entrypoint's return value in both branches, and
`_delayEntrypointInvocation`'s handler discards it too — so an `async main`'s
Future is unawaited. `Dart_HandleMessage` therefore returns success as soon as the
**synchronous prefix up to the first `await`** completes. The common startup shape

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();   // <-- success already banked before this
  runApp(const App());
}
```

banks success before any of the awaited startup work has run, and a patch that
breaks it fails in a later turn. **This is exactly `0009`'s failure mode at one
turn's remove**, and it is the reason this seam cannot be adopted as-is.

### The candidate that survives all four: wrap the entrypoint in `_runMain`

The invocation of `main` has a name in source, so the seam should bind to that
name rather than to a turn ordinal. `lib/ui/hooks.dart:406` is that name:

```dart
@pragma('vm:entry-point')
void _runMain(Function startMainIsolateFunction, Function userMainFunction, List<String> args) {
  startMainIsolateFunction(() {
    ...
    userMainFunction();   // <-- the exact invocation; return value currently DISCARDED
  }, null);
}
```

Wrapping this call site answers all four:

| question | why the wrapper answers it |
|---|---|
| 1 identity | it **is** `main`'s invocation. No ordinal reasoning, no assumption about queue order |
| 2 exact signal | sync return vs thrown object are distinguishable at the call site |
| 3 coverage | the `catch` sits INSIDE the closure, so it observes the throw **before** `_onError`/`PlatformDispatcher.onError` can consume it. Not app-controllable |
| 4 `async main` | capture the discarded return value; if it is a `Future`, bank on its **completion** and report failure on its **error**. That is completion of startup work, not its scheduling |

Feasibility, stated honestly: `hooks.dart` ships in `sky_engine`, and this fork
already builds and serves its own `sky_engine.zip` from the overlay (`R11`, cell
`40eaa0ef`), with the CONSUMED copy verified to carry our modifications. So the
delivery channel exists and is audited. **But no existing patch touches
`hooks.dart`** — this would be the first, and `R3` must confirm the patched
`hooks.dart` actually reaches the AOT kernel the release compiles against. Until
that is confirmed the candidate is *located*, not *built*.

#### The one open question on this candidate, recorded rather than assumed

**A `main` that never returns and never completes never banks success** — and
with `0010`'s counter, two such boots tombstone a GOOD patch. This is the same
generic-success-contract failure that disqualifies first-frame, so it must not be
waved through here. Shapes to check before building: an `async main` awaiting
something long-lived after `runApp`, and an app whose `main` intentionally does
not return. If they are real, the wrapper needs a second banking condition
(whichever of *main returned* / *its Future completed* / a bounded fallback comes
first) — and that fallback must be chosen with the same four questions, not
assumed.

### The A/B experiment, and the liveness receipt it must carry

Same release, same patch machinery, same device, three arms:

| arm | patch | required observation |
|---|---|---|
| A | good patch | reaches the candidate signal, banks success, renders |
| B | `main()` throws | does NOT bank success, `PatchInstallFailure` queued, patch `Bad{BootCrash}`, backed out |
| C | good patch, killed before the signal | retried, NOT tombstoned — arm 2's result, re-earned at the new seam |

**Every arm must assert the fixture's marker moved before the screen is read.**
The control run found `main()` was not executing at all while the screen showed
the same blank white as a crash. A seam experiment on that fixture would measure
nothing and look like a caught-or-missed crash either way. The marker file is a
per-launch receipt that `main()` ran, it survives `SIGKILL`, and it is now a
REQUIRED precondition of every G15 arm rather than an arm-2 implementation
detail.

---

## The design

> **§1 below is SUPERSEDED by the seam section above** (2026-08-14). It is kept
> because its reasoning is why `0009` was built, and the correction is only
> legible beside it. §2 (the counter) and §3 (no deadline) stand — §2 shipped as
> `0010` and is PROVEN on device.

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

> **REFUTED ON DEVICE 2026-08-14. The row above is wrong about what `Engine::Run`
> proves.** Implemented as `0009`, the seam was placed at `Engine::Run` returning —
> and `Run` reports that the entrypoint was **invoked**, not that it succeeded. A
> patch throwing inside `main()` therefore banked **three consecutive successes**
> while crashing every launch (`last_booted_patch: 1`, `boot_attempt_count: 0`,
> patch still `Installed`, no `PatchInstallFailure`).
>
> So "root isolate past `main()`'s prologue" is not reachable by watching `Run`'s
> return value: `Run` returns *before* the prologue's outcome is known. The table's
> middle row describes the right PROPERTY and the wrong OBSERVATION POINT, and the
> distinction is the lesson — the design reasoned about when patched Dart has run,
> then picked a signal that fires whether or not it did.
>
> Part 2 (the counter) is unaffected and PROVEN. Candidate replacements are in
> `evidence/g15/crashbackout_verdict.txt` under *Where the seam actually belongs*,
> including first-frame, whose original objection is now mitigated by part 2.

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
