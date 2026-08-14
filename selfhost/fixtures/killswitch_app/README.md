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

After patch `0009`, launch success is banked when **`Engine::Run` returns**, and
`Engine::Run` is what invokes `main()`. So a process that dies *inside* `main()`
dies before `Run` returns: the boot records neither success nor failure — exactly
the state a swipe-away leaves behind.

That makes the arm **deterministic**. There is no timing window to hit and no
external tooling: the app kills itself at a point that is, by construction, inside
the window under test.

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

## Reading the result

| observation | verdict |
|---|---|
| after a killed launch, the next launch renders and shows the PATCHED value | **arm 2 passes** — a good patch survived a death inside the success window |
| the next launch renders the RELEASE value | the patch was tombstoned: `Bad{BootCrash}` on a patch that never failed. **A failure of the design** |
| the app does not render at all | not an arm-2 result — investigate the install before interpreting anything |
