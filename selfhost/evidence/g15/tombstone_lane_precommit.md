# Tombstone / retry lane — PRECOMMIT

2026-08-18, **before any device run.** Read `tombstone_lane_reconciliation.md`
first: it settles the apparent contradiction from preserved evidence and produces
the hypothesis this precommit tests.

## THE QUESTION, narrowly

> Given a patch that has ATTACHED but has not reached the success latch, what
> exact sequence of launch failure, retry-counter mutation, tombstoning and
> rollback occurs across successive processes?

Scoped deliberately to lifecycle. The execution mechanism is closed (`STATUS.md`);
nothing here re-opens it.

## THE SIX TRANSITIONS, each scored SEPARATELY

Every row needs `pointers.json` + `patches/N/state.json` captured **between**
launches, not only at the end.

| # | transition | precommitted expectation | what would falsify it |
|---|---|---|---|
| 1 | **first failed boot** | `cur=N`, `count=1`, `last_booted=None`; patch stays `Installed` | `Bad` after one failure = single-strike behaviour returned |
| 2 | **retry eligibility** | next init clears `cur` ONLY, KEEPS `count=1` and `last_attempt=N`, patch retried | count zeroed at retry — makes the threshold unreachable |
| 3 | **second consecutive failed boot** | `count` reaches 2 | count resets between consecutive failures |
| 4 | **transition to Bad** | init at `count>=2` marks `Bad{BootCrash}`, `next_boot_patch=None`, count reset; a `PatchInstallFailure` event queued | tombstoned earlier/later than 2; or NO event queued (silent backout) |
| 5 | **after a confirmed successful boot** | `count=0`, `last_attempt=None`, `last_booted=N`; a subsequent single failure CANNOT tombstone | success does not zero the tally |
| 6 | **process/tool teardown masquerading as app failure** | an externally-killed boot is INDISTINGUISHABLE from a Dart-phase failure and increments the counter identically | teardown is somehow distinguished — which would be good news and must be measured, not hoped for |

**Row 6 is the operational-safety row and the reason this lane outranks the
others.** The same counter runs in production against swipe-away, the launch
watchdog and jetsam.

## THE DEVICE DESIGN — smallest discriminator, with a positive control

ONE release, ONE patch, carrying BOTH:

* a **deliberately controlled boot failure** — a target that throws in `main`
  BEFORE the success latch, so the boot cannot bank;
* a **positive-control successful launch path** — so a run where nothing boots at
  all is distinguishable from the transition under test.

The killswitch fixture's existing alternation already provides both arms and is
NOT to be modified; its marker may be set to select which arm a launch takes.

### TOOLING CONSTRAINTS — these are part of the experiment, not conveniences

Row 6 means the harness is a confounder, so:

* **NO `idevicedebug`** for any launch whose lifecycle is being scored — its
  timeout SIGKILLs the app and manufactures un-succeeded boots (three preserved
  states are exactly that shape);
* **NO `--justlaunch`** — quits the app as lldb detaches;
* **NO `ios-deploy --download` between scored launches** — it can itself relaunch
  the app (`arm2_verdict.txt`; 7 activations vs 6 taps this cycle). State must be
  captured in a way that does not boot the app, or the capture becomes a
  transition.

**Consequence, accepted in advance:** scored launches are BY HAND, and state
capture between them must be proven non-booting or deferred. If no non-booting
capture exists, that is itself a finding to record — the current harness cannot
observe this lane without perturbing it.

## Admissibility

1. every scored transition has state captured on BOTH sides;
2. the patch's attach is established independently (`rc=0`, `bc_post=1`) so
   "never attached" is excluded;
3. launch identity tied to the receipt's launch id, as in the repair run;
4. no scored launch used a debugger-attached or teardown-prone launcher;
5. `queued_events` is read, not assumed — row 4 depends on it.

## Out of scope

`TPOOL_AMBIGUOUS`, pragma effects, the JWT issuer repair, the `audit_log`
content-read, and Android build-config enforcement. **The JWT repair especially
must NOT be interleaved** — it mutates control-plane state and would become a
second variable in a lifecycle experiment.

## Standing claims, unchanged

G15 mechanism **closed**; original arm A **INCONCLUSIVE**; Route B iOS
end-to-end **PROVEN**; Claim 1 **instrument established and positive locator
proven**.

---

# AMENDMENT 2026-08-18 — two sub-sequences, and a methodological correction

Added after `nonbooting_capture_verdict.md` qualified the observer. Precommitted
before the scored run.

## Methodological correction, kept explicit

**Finding `processcontrol` in `ios-deploy` established launch CAPABILITY, not that
`--download` launches on every invocation.** The measured positive control
overruled that inference: `--download` ran and the launch witness did not move.

`ios-deploy` stays disqualified as a scored primitive on CAPABILITY grounds — a
tool that can start a process may not sit inside a lifecycle measurement — but the
inference "it relaunched, therefore release 96's extra boots came from file
pulls" is withdrawn. Capability is not occurrence. This distinction is the same
error class as attachment-is-not-output.

## TWO SUB-SEQUENCES, deliberately not one

Rows 3-4 and row 5 are scored from SEPARATE specimens. Once sequence 1 reaches
`Bad{BootCrash}`, anything done to make it runnable again is another state
mutation, and a kill→render run on a resurrected specimen would test recovery
from tombstoning rather than reset semantics.

### Sequence 1 — CONSECUTIVE FAILURE (scores rows 3, 4, 6)

    establish pre-state  -> capture (afcclient) + witness
    manual launch #1, deliberate pre-success death
    capture + witness
    manual launch #2, deliberate pre-success death
    capture + witness
    -> score rows 3-4 ONLY from these bracketed states

### Sequence 2 — RECOVERY / RESET (scores row 5)

    FRESH equivalent starting state (new patch install reached by real download,
    never a resurrected specimen)
    manual launch #1, deliberate pre-success death
    capture + witness
    manual launch #2, allowed to render and bank success
    capture + witness
    -> score row 5 from the observed reset

## What counts as a "deliberate pre-success death"

The fixture's KILL ARM: `Process.killPid(pid, SIGKILL)` inside `main`, before
`runApp`. `arm2_verdict.txt` established it as the stand-in for exactly the
production events row 6 is about — *"the user swiping the app away during launch,
the iOS launch watchdog (0x8badf00d), or jetsam"*.

**Residual difference, stated rather than glossed:** the kill arm's CAUSE is
internal to the app while a swipe-away is external. Its SHAPE — SIGKILL before the
success latch, no Dart-phase exception, no failure report — is identical, and the
shape is what `0010`'s counter sees. A run that reaches `Bad` this way therefore
demonstrates that the counter cannot distinguish the shape; it does not by itself
prove an operator swipe produces it. **If rows 3-4 land, a swipe-away confirmation
is the natural follow-up and is NOT claimed by this run.**

Consecutive kills require the alternation marker to be ABSENT twice running. The
kill arm creates it, so it is deleted between launches **with `afcclient rm`** —
the qualified non-booting tool. That selects which arm a launch takes and touches
nothing else.

## PRESERVED TOGETHER FOR EVERY SCORED CAPTURE

1. the updater state the frozen rows name — `currently_booting_patch`,
   `boot_attempt_count`, `last_booted_patch`, `next_boot_patch`,
   `Installed`/`Bad{BootCrash}`;
2. `queued_events` — read, never assumed;
3. the launch witness BEFORE and AFTER the afcclient read, proving the read itself
   added no activation;
4. exact patch and release identity;
5. **the exact manual outcome observed for the immediately preceding launch** —
   white-screen-then-gone vs blue-screen-with-value — reported by the operator.

## No debugger or tool-driven launch anywhere inside a scored sequence

`idevicedebug`, `--justlaunch` and `ios-deploy` launches are excluded from scored
launches. The unscored `idevicedebug` observation in
`nonbooting_capture_verdict.md` is valuable precisely because it tells the
controlled experiment what it must be capable of DISPROVING.

## If row 6 lands

Two deliberately induced, otherwise-healthy pre-success process deaths producing
the terminal `Bad{BootCrash}` + `__patch_install_failure__` shape changes the
question from *"what happened to release 96?"* to a product-level safety
statement:

> the updater currently cannot distinguish certain external process deaths from
> evidence that the patch itself is bad.

**That deserves a design response, not a harness workaround.** The harness rules
above exist to measure the property, not to avoid it.

---

# AMENDMENT 2026-08-19 — the stimulus changes; the rows do not

Added after `tombstone_lane_S2_verdict.md` disqualified the self-kill arm as an
input generator. **The six frozen transitions are unchanged.** Only the mechanism
that produces a pre-success death is replaced.

## Why the self-kill arm is disqualified

`Process.killPid(pid, SIGKILL)` returned control and the process kept executing
Dart, so the fixture's guard threw and the arm delivered a **Dart-phase
exception** instead of a **process death**. Those exercise different retirement
paths — `report_launch_failure()` (engine states it) versus
`detect_boot_crash_on_init()` (breadcrumb inference) — and only the second is
governed by `0010`'s threshold, which is what rows 1-4 are about.

The fixture also discards `killPid`'s `bool`, so it cannot distinguish an
undelivered signal from an ignored one. **If the self-kill arm is ever reused, it
must record that return value before the guard.**

## The replacement stimulus: EXTERNAL termination by the operator

Better than the original, because it IS the operational question — swipe-away is
exactly what row 6 is about, and it needs no fixture change.

### Sequence A — two consecutive external deaths (rows 1-4)

    healthy patch active, Installed, counter 0
      -> manual launch
      -> OPERATOR force-quits during the pre-success window
      -> afcclient capture
      -> manual launch
      -> OPERATOR force-quits during the pre-success window
      -> afcclient capture
      -> manual launch (observe whether it was retired)
      -> afcclient capture

Question: do two consecutive external deaths produce retry-then-tombstone?

### Sequence B — external death then genuine success (row 5)

    FRESH healthy specimen
      -> manual launch
      -> OPERATOR force-quits before success
      -> afcclient capture
      -> manual launch, allowed to render
      -> afcclient capture

Question: does a real success reset the counter?

`afcclient` remains the ONLY between-launch observer.

## The pre-success window, and its honest difficulty

Success banks early — at `_runMain` completion, which for a `void main()` is
almost immediately after the first frame path begins. The operator must force-quit
BEFORE that. A force-quit that lands after success banks is not a row-1 stimulus;
it is an ordinary clean run, and the capture will show `last_booted=N, count=0`,
which is how it is detected rather than mistaken.

**Expect misses.** A launch whose capture shows success banked is DISCARDED, not
scored, and the tap repeated.

## Starting state — do NOT reuse the current one

Patch 1 is `Bad{BootCrash}` from the accidental Dart failure. **That is not a
valid starting point.** Restore the fresh pre-state the precommit requires —
updater state cleared with `--rmtree`, patch re-downloaded, attach confirmed by a
render showing `NEW-kill` and a trace line — and record that restoration
**outside** the scored transitions.

## Status of the accidental run

`tombstone_lane_S2_verdict.md` stays **explicitly unscored**. It corroborates,
usefully, that: a healthy replacement attached; Dart startup then failed; the
updater produced `Bad{BootCrash}` with the expected `engine_report` failure event;
and the process did not automatically exit or recover. None of that is a scored
row.

The fixture guard did what a good experimental guard should: it turned a broken
stimulus into an unmistakably invalid arm rather than a plausible-looking green.
