# G15 ARM B — CRASH-BACKOUT, PRECOMMITTED BEFORE THE DEVICE RUN

2026-08-16. Written after the patch was published and BEFORE any launch.
Arm B was precommitted in `gate5_arms_precommit.md` and named in
`arm2_verdict.txt` as never run: *"NOT crash-backout … G15's §15 gate 'a
Dart-phase crash backs the patch out' is NOT closed by this."*

## THE SPECIMEN

Release **101** (`1.1.0+1`), LC_UUID `cfae3af589b934368b04edcf4478abe0`,
preserved. Patch 1 replaces `bootProbe()` with a body that THROWS:

    release : DateTime.now().millisecondsSinceEpoch == -1 ? 'UNREACHABLE-BOOT' : 'boot-ok'
    patch   : DateTime.now().millisecondsSinceEpoch == -1 ? 'UNREACHABLE-BOOT'
              : throw StateError('G15 arm B: deliberate Dart-phase boot failure')

`bootProbe()` is called from `main()` BEFORE `runApp()`, so the throw lands in
the Dart phase of startup — which is exactly the gate's subject.

## WHY THE FIXTURE HAD TO BE REPAIRED FIRST

On release 100 `bootProbe` was `=> 'boot-ok'` — a foldable constant, measured
**NOT LOCATED** (0 surviving call sites, 8-byte stub). Patching it would have
attached cleanly and silently done nothing, and the arm would have scored a
false PASS-looking "no crash". The opaque guard was added, and the static
pre-check against release 101 now reports:

    bootProbe  0xaf3b8-0xaf438 (128 B)   located: 1   site 0xaf3dc   VERDICT: CONSUMED

This is the `routebvalue_repair_verdict.txt` lesson applied BEFORE spending a
device cycle rather than after.

## STIMULUS

Ordinary launches only. No force-quit timing, no SIGKILL, no external stimulus.
The crash is supplied by the patch itself — that is the entire point of the arm,
and it is what makes arm B measurable where the pre-success termination lane
(`tombstone_lane_FINAL.md`) was not: the fixture's ~60 ms window versus a ~250 ms
human floor is irrelevant when the specimen crashes itself.

## SCORING ROWS — FROZEN

| # | observation | verdict |
|---|---|---|
| 1 | receipt shows `dart-main-entered` and **no** `boot-probe-returned`; patch marked `Bad{BootCrash}` after **ONE** launch; a `PatchInstallFailure` event is queued; next launch runs the RELEASE (`boot-ok`, `OLD-kill`) | **PASS by the intended mechanism** |
| 2 | same receipt evidence, but retirement needs **TWO** launches | PASS of the gate, but via `detect_boot_crash_on_init()`'s threshold, NOT `report_launch_failure()`. Record which path fired |
| 3 | app HANGS on a white screen without a process death; patch still retired | PASS of backout, **FAIL** of "crash" — the Dart throw did not terminate the process |
| 4 | app hangs and the patch is **never** retired | **FAIL** — a broken patch is unrecoverable without a manual `--rmtree` |
| 5 | `boot-probe-returned:boot-ok` appears with patch 1 active | **VOID** — the patch attached but did not execute; re-check foldability |

## PREDICTION, STATED BEFORE THE RUN

**Row 3.** Based on the accidental `StateError` observed during the
delayed-main lane, I expect the app to hang on a white screen rather than die,
with the updater still marking the patch `Bad` and running the plain release on
the next launch after a force-quit. Rows 1 and 3 differ ONLY in whether the
process actually terminates — and that difference is the arm's real content,
because §15's gate says *crash*, not *fails to render*.

If row 3 lands, the honest reading is that the gate is closed for BACKOUT and
still open for CRASH, and the two must not be merged in the ledger.

## WHAT THIS ARM CANNOT CLAIM

* Nothing about `routeBValue`, untouched here and still at its release value.
* Nothing about non-boot-phase crashes — a throw after `runApp()` is a different
  lane with different machinery.
* Nothing about the pre-success termination rows 1-4, which remain structurally
  unmeasurable on this rig and are parked.
