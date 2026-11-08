# The launch crash, classified — 2026-08-27, new cell `4792f0ec`

Reported by the operator: *"it opened and then disappeared in under a second"* on
the third by-hand launch; the fourth launch rendered `SIGN-V2` and stayed up.
Captured live this time, unlike the Arm C occurrences whose reports were lost.

## What the device recorded

Four SpringBoard bootstraps, four processes:

    17:53:49  pid 49031   base release      SIGN-V1
    17:54:25  pid 49039   base release      SIGN-V1
    17:54:56  pid 49043   patch 1           <- THE CRASHING LAUNCH
    18:00:40  pid 49085   patch 1           SIGN-V2, stayed alive

## The crashing process got everything right first

`pid 49043`, in order:

    Preparing next boot.
    Verifying patch signature...
    Patch signature is valid
    Prepared boot of patch 1.
    active path: …/shorebird_updater/patches/1/dlc.vmcode
    active patch is a Route B container
    ROUTEB: hook entered

and then, from artifacts rather than syslog:

    dlc.vmcode.routeb.trace   TWO rbtrace records — one per activation, so 49043
                              activated Route B, rc=0
    success_diag.log          pid=49043 patch=1 raw_boot_attempt=1
                              prior_ambiguous_attempts=0

`report_launch_success` is reported **from Dart**, on `main` completing or the
first framework frame. So pid 49043 reached Dart, ran the patched code, and
banked a successful boot — and only then disappeared.

Its `ROUTEB: activated …` / `ROUTEB: applied 1/1 targets` lines are missing from
the syslog while pid 49085's are present. That is a syslog **drop**, not a
failure: the trace file carries a record for both launches. Noted because the
absence of a log line was very nearly read as a refusal.

## Therefore the crash is DOWNSTREAM of everything Signing tests

Positively excluded, because each completed inside the crashing process:

| stage | evidence it completed |
|---|---|
| signature verification | `Patch signature is valid` |
| boot selection | `Prepared boot of patch 1.` + active path |
| launch attribution | `success_diag` names **patch 1** |
| Route B activation | second `rbtrace` record, `rc=0` |
| Dart `main` | success is reported from Dart, and it was reported |

The crash is after `main` began and after success was banked. It is not a
boot-selection, verification, attribution, or activation failure.

## No lifecycle damage, and the reason is not luck

    next_boot_patch: 1   last_booted_patch: 1   currently_booting_patch: null
    boot_attempt_count: 0   last_boot_attempt_patch: null
    patch 1: Installed, artifact present
    P1 = c97c93f10b3248082fd5f54fe59274f042cd03a6b0189db552c7a2db71ac5a7e (1687 B)

Success had already cleared the breadcrumb, so the next launch's
`detect_boot_crash_on_init` correctly saw no boot in flight — no `Bad{BootCrash}`,
no ambiguity counted, no retry consumed. Both `raw_boot_attempt=1` entries confirm
each boot was a fresh first attempt.

## Still not fully explained

**No crash report exists.** Two `idevicecrashreport --keep` pulls, the second
deliberately delayed, returned only unrelated `SiriSearchFeedback` and
`DifferentialPrivacy` files — no `Runner`, no `JetsamEvent`. For a
development-signed app (`get-task-allow: true`) a Dart or native crash would
normally produce one. Its absence is consistent with the process being terminated
by the system rather than crashing on a signal, but that is inference, not
evidence, and it is recorded as such.

**Pattern worth stating, not yet proven.** Both this crash and both Arm C
occurrences happened on the FIRST launch that activated a NEWLY INSTALLED patch;
the immediately following launch was clean each time. One occurrence per install,
never on an already-established patch. That is three-for-three across two cells,
which is suggestive and nothing stronger — n=3, no mechanism, and no report.

## What this does and does not license

* It does **not** license calling the crash benign. It is unexplained.
* It does **not** point into the updater, Route B activation, or engine
  initialization — those are positively shown to have completed in the crashing
  process. So on the precommitted three-way rule it is not the blocker branch.
* It does **not** touch the signature boundary, which is what Signing certifies.
* The rejection/recovery launches remain to be run, and the rule that a
  recurrence there must be captured and classified before certification stands
  unchanged.

## Preserved here

    syslog_window.log          3,632 lines spanning all four launches
    updater_state_snapshot/    pointers, per-patch state, success_diag, rbtrace
    second_pull/               the delayed crash-report pull
