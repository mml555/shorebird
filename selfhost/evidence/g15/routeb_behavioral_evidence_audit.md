# Route B iOS — BEHAVIORAL EVIDENCE AUDIT

2026-08-17. Read-only; no device run. Triggered by
`manual_launch_control_verdict.txt`, which showed release 91 rendering `OLD-kill`
under its own original configuration.

**The question:** *do we have any iOS Route B patched-value success whose visible
behavior is independently corroborated, rather than only operator-reported?*

**Classification is of BEHAVIORAL EVIDENCE ONLY.** Attachment evidence — `applied
1/1`, `rc=0`, `bc_post=1`, `uep_post_is_interpret_call=1`, updater state — does
**not** count. Release 91 has all of it and still renders `OLD-kill`.

## THE ANSWER: YES — FOUR INDEPENDENT SPECIMENS

| # | specimen | target (selector) | shape | claimed value | behavioral evidence | class | path |
|---|---|---|---|---|---|---|---|
| 1 | rel 31 patch 1 | `RouteBThing.value` | **class member** | `NEW-CTL` | device screenshot: `route B value: NEW-CTL` + `code patch: 1` | **STRONG** | `engine/route_b/evidence/r31_2_patched_NEW-CTL.png` |
| 2 | rel 31 patch 2 | private field read | **class member** | `NEW-PRIV` | device screenshot: `route B value: NEW-PRIV` + `code patch: 2` | **STRONG** | `engine/route_b/evidence/r31_3_patched_NEW-PRIV.png` |
| 3 | rel 32 patch 1 | `_ProbeBodyState.privateClassValue` | **class member** | `NEW-PC` | device screenshot: `private class: NEW-PC` while `route B value` stays `OLD-rel`, `code patch: 1` | **STRONG** | `engine/route_b/evidence/r32_2_patched_NEW-PC.png` |
| 4 | rel 37 patch 1 | `RouteBThing.paramValue` | **class member** | `PARAM-ARG` | control-plane request log with `param=PARAM-ARG code_patch=1`, on two independent launches — **but the raw log is NOT preserved; the value survives only transcribed into prose.** Its screenshot does NOT show the value (no `param:` field in that fixture build) | **PARTIAL** | `evidence/releases/37/verdict.txt` lines 49-59 |
| 5 | rel 38 patch 1 | `RouteBThing.two(a,b)` | **class member** | `PARAM-a-7` | device screenshot: `two params: PARAM-a-7` + `code patch: 1`, all other fields `OLD` | **STRONG** | `evidence/releases/38/r38_two_PARAM.png` |
| 6 | rel 39 patch 1 | `RouteBThing.value` (obfuscated) | **class member** | `NEW-OBF` | device screenshot: `route B value: NEW-OBF` + `code patch: 1`, other fields `OLD` | **STRONG** | `evidence/releases/39/r39_NEW-OBF.png` |
| 7 | rel 91 (1.0.2+1) | `routeBValue` | **TOP-LEVEL FUNCTION** | `NEW-kill` | operator's real-time report only. `arm2_verdict.txt` states its screenshot "is white and does NOT show tap 4" | **PARTIAL** — and now **CONTRADICTED** by `manual_launch_control_verdict.txt` | `evidence/g15/arm2_verdict.txt` |
| 8 | rel 95 / 96 | `routeBValue` | **TOP-LEVEL FUNCTION** | — | rendered `OLD-kill`; failure observations, not success claims | n/a | `evidence/g15/` |

**Every STRONG row was verified by opening the image, not by trusting its
filename** — the discipline release 91 taught. That check earned its keep at row
4: `r37_patch1_PARAM.png` is named for a value it does not display. Release 37's
own verdict says so plainly ("the file name overpromises"), to its credit.

**The four STRONG rows carry an internal control that is hard to fake:** the
unpatched fields on the same screen still read `OLD-rel` / `OLD-pc` / `OLD-ARG`.
Only the patched target changed. A wrong build, a rebuilt archive, or a fabricated
frame would move everything at once — which is exactly the false positive release
37 caught and discarded (`DISCARDED-2026-08-13.txt`: `PARAM-ARG` appeared
natively from a rebuilt archive, with `code_patch=none` as the tell).

## CONSEQUENCE — the FIRST branch applies

> *"If at least one prior iOS specimen has independently corroborated patched
> output: Route B end-to-end execution remains proven somewhere, and the current
> investigation becomes 'why this target/specimen does not execute despite
> successful attachment.'"*

**Route B end-to-end execution on iOS is PROVEN.** Four independent specimens, two
distinct fixtures' worth of target kinds (public getter, private getter, private
field, one-arg method, two-arg method), one under obfuscation. **No retraction of
the broad iOS end-to-end behavioral claim is required.**

The investigation is therefore correctly reframed as: *why does THIS target not
execute despite successful attachment?*

## AND THE AUDIT SURFACED A CANDIDATE ANSWER

Read from the preserved traces' own `sel=` fields, not from prose:

    sel=RouteBThing.value                   x7     PROVEN
    sel=RouteBThing.paramValue              x2     partial (rel 37)
    sel=_ProbeBodyState.privateClassValue   x2     PROVEN
    ------------------------------------------------------------
    sel=routeBValue                                FAILS  (rel 91/95/96)

**Every proven iOS success has a DOTTED selector — a class member. The one target
that has never rendered its patched value is the only UNDOTTED one: a top-level
function.**

`routeBValue` is declared at file scope in `killswitch_app/lib/main.dart:65`:

    String routeBValue() => 'OLD-kill';

while every success is an instance member of `RouteBThing` or `_ProbeBodyState`.

**This is a hypothesis, not a finding.** It is the first structural property that
actually separates the working set from the failing one — after two candidates
(the fold, inlining) died precisely because they did NOT separate them. It also
coheres with `TPOOL_ABSENT`: a top-level function's `Function` object need not be
reachable through the global object pool the way a class member's dispatch may
be, though that connection is unverified.

It is cheap to test and needs no new instrument: **add a top-level function
target to `airgap_probe`, the fixture with four proven successes, and patch it.**
If a top-level function fails there while its class members succeed in the same
build, the discriminator is isolated in one device cycle, with every other
variable already controlled.

## What this audit does NOT establish

* NOT that top-level functions are the cause. One structural correlation across a
  small corpus, and the corpus was not designed to vary this.
* NOT that release 91 ever worked. Row 7 remains contradicted; the audit does not
  rehabilitate it.
* NOT that release 37's `PARAM-ARG` is unsupported — the parameter-transfer claim
  it carries is independently PROVEN by row 5 (`PARAM-a-7`, screenshot). Row 4 is
  downgraded on preservation, not on plausibility, and would upgrade if the
  control plane still retains its 2026-08-13 request log.
* Claim 1 is untouched: instrument established; **positive locator not yet
  proven.**
* Arm A remains **INCONCLUSIVE**.
