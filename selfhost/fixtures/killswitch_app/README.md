# `killswitch_app` — G15 arm 2

> A **good** patch, killed before launch success is banked, must still be
> `Installed` and selected on the next boot. A `Bad{BootCrash}` here is a
> failure of G15's design, not a success of the safety mechanism.

## Why a fixture exists for this at all

G15's real risk is not that a broken patch survives — it is that a **working one
gets tombstoned**. `detect_boot_crash_on_init` infers *"this boot crashed"* from
*"the breadcrumb is still set"*, and that is an inference from **absence of
evidence**: equally consistent with a patch that broke Dart and with the user
swiping the app away during launch, the iOS launch watchdog (`0x8badf00d`), or
jetsam under memory pressure.

No arm built only from good launches and broken patches can observe that failure.
The first version of G15's design had no such arm, which is how it nearly shipped
a change that would tombstone good patches.

## How the kill lands in the right window

> **CORRECTED 2026-08-14.** This section used to say that `Engine::Run` *invokes*
> `main()`, so a death inside `main()` necessarily precedes `Run` returning. That
> is **wrong, and it is the mechanism whose correction moved the whole seam
> search**: `_delayEntrypointInvocation` (`isolate_patch.dart:298`) POSTS `main`
> to a `RawReceivePort` and returns, so `InvokeMainEntrypoint` →
> `LaunchRootIsolate` → `Engine::Run` all return **before one line of user Dart
> runs**. Do not restate the old reading; see
> `evidence/g15/crashbackout_control_verdict.txt`.

What survives the correction is what the arm actually needs: the process dies
**inside `main()`**, which is before any seam that observes user Dart can report
success, and after the boot breadcrumb is set. The boot therefore records neither
success nor failure — exactly the state a swipe-away leaves behind.

That makes the arm **deterministic**. There is no timing window to hit and no
external tooling: the app kills itself at a point that is, by construction, inside
the window under test. Which *seam* that window belongs to is the open question;
the arm does not depend on the answer.

## The alternation, and why it is not a convenience

`main()` consults a marker in the app sandbox:

| marker | behaviour |
|---|---|
| absent | create it, then `SIGKILL` this process |
| present | delete it, then run normally |

So launches alternate kill / run / kill / run. G15's design requires arm 2 to be
run **more than once** — a single survival is consistent with the kill having
landed outside the window by luck — and alternating delivers that without anyone
reaching into the sandbox between launches.

It also avoids an **uninstall**, which would reset iOS Local Network consent and
leave the app blocked on a modal before any code runs. That trap has already cost
this project a device session.

`SIGKILL`, not `exit()`: jetsam and the watchdog do not let a process wind down,
and a clean exit could run teardown the real cases never run — which might report
an outcome and defeat the entire arm. If `SIGKILL` were somehow not delivered,
`main()` throws rather than falling through to `runApp`, because a rendered screen
would make the arm silently vacuous.

## Why not `twoengine_app`

Its `_boot()` ends in `runApp()` and **both** entrypoints call it, so it is not
headless. The earlier G15 design's arm 4 assumed otherwise and was a false green
on exactly that ground.

## The receipt — read this BEFORE the screen, on every arm

`/Documents/g15_receipt` is an **append-only phase log**, written by both the
native and the Dart half of the app, and it is the fixture's primary instrument.
The screen is secondary.

| line | proves |
|---|---|
| `native launch` | the process reached `didFinishLaunchingWithOptions` |
| `native engine` | the implicit `FlutterEngine` was created |
| `dart <id> dart-main-entered` | `main()` ran its **first statement** |
| `dart <id> boot-probe-returned:X` | `bootProbe()` — **the patch target** — returned `X` |
| `dart <id> arm:kill` / `arm:render` | the alternation decided |
| `dart <id> first-frame` | Flutter actually drew |

**The last line present names the exact point the launch reached**, so a gap
between two consecutive phases localises the failure to one step. `<id>` ties
lines to one launch, and the same id is printed on screen, so a screenshot and a
set of receipt lines can be matched rather than assumed to correspond.

### Why it was rebuilt

Two results have now been lost to a signal whose failure mode mimicked the state
it was meant to discriminate:

1. The `HOME`-derived marker path threw, `main` died before rendering, and a
   blank screen was indistinguishable from the kill arm working.
2. `6d00e95c` put `bootMark = bootProbe();` **ahead of** the marker write. That
   put the receipt behind the very function arm B exists to make throw, so on the
   arm where it matters most the marker can never move. The verdict written from
   it — *"`main()` DID NOT RUN… not at all"* — was **not supported**: an unmoved
   marker is equally consistent with `main()` being entered and dying on its
   first statement.

Hence the invariants in `lib/main.dart`: the receipt is written **first**,
`bootProbe()` is **not** wrapped in `try/catch` (the seam under test must see the
unhandled throw), an instrument fault renders red rather than killing, and the
native half exists because no Dart-side instrument can separate *"Dart never
started"* from *"the app never really launched"*.

## Reading the result

**Every row below is conditional on the receipt first.** If `dart-main-entered`
is absent for the launch under test, nothing on the screen is an arm result.

| observation | verdict |
|---|---|
| receipt shows a killed launch, then the next launch reaches `first-frame` and shows the PATCHED value | **arm 2 passes** — a good patch survived a death inside the success window |
| same, but the value is the RELEASE value | the patch was tombstoned: `Bad{BootCrash}` on a patch that never failed. **A failure of the design** |
| `dart-main-entered` present, `boot-probe-returned` absent | `bootProbe()` threw or never returned. On the **unpatched** release that is a fixture/pipeline defect; on the **patched** one it is the Dart-phase boot failure arm B is trying to cause |
| `native engine` present, `dart-main-entered` absent | the engine started and user Dart did not. **Not a patch result** — this is the state the 2026-08-14 control could not name |
| `native launch` present, `native engine` absent | the process launched and the engine never came up — investigate the install, not the patch |
| no receipt lines at all for this launch | the app did not run. Check the container path and the install before interpreting anything |

## Cutting the release — pass `--export-method development`

```sh
shorebird release ios --export-method development
```

Without it the export fails with **`No Accounts`** and **`No profiles for
'dev.selfhost.killswitchProbe' were found`** — *after a successful archive*, which
is what makes it read as a broken developer account rather than a wrong flag.

The cause is that `flutter build ipa` defaults to the **app-store** export method,
and the profile that covers this bundle id is the **wildcard development** profile
`SK85S6YZP9.*`. There is no distribution profile on this rig, so app-store export
can never resolve one.

`prepare_killswitch_fixture.sh` injects `DEVELOPMENT_TEAM`, which is necessary and
**not sufficient** — the team fixes *signing*, the export method fixes *which profile
is looked for*. Measured here 2026-08-14: with the team correctly set to
`SK85S6YZP9`, the export still failed until the method was changed.
