# P6 · manual updater API — CERTIFIED

> **Manual updater API CERTIFIED:** the application explicitly selected a track,
> checked availability without downloading, explicitly downloaded through
> `update(track:)`, staged the patch, and executed it on the next launch. A
> mismatched-track negative proved the update call itself controls eligibility.

App `manualapi-p6` (`393fb814-…`), bundle `dev.selfhost.manualApiApp`, release
**3.1.0+1** (id 123), **one** patch, **one** device client, `auto_update: false`.
iPhone 7 / iOS 15.8.8, wired. No debugger: installed with `ios-deploy --bundle`
and no `-d`/`-L`, every launch a by-hand tap, diagnosis via passive
`idevicesyslog`.

    beta   -> patch 1 LIVE, rollout 100
    stable -> no deployment row at all

## The sequence, as run

| # | action | screen | client sent | server / events |
|---|---|---|---|---|
| 0 | two launches, **nothing pressed** | `MANUAL-V1`, cur `none`, next `none` | — | **0** checks, **0** events |
| 1 | `Check stable` | — | `channel: "stable"` | 200, no download |
| 1b | `Update stable` | `returned normally`, cur `none`, next `none` | — | **0** events |
| 2 | `Check beta` | **`outdated`**, cur `none`, next `none`, `MANUAL-V1` | `channel: "beta"` | 200, **no download** |
| 3 | `Update stable` **immediately after** | `returned normally`, next `none`, `MANUAL-V1` | **`channel: "stable"`** | **0** events, no `/download/` |
| 3b | `Update beta` | `returned normally`, **next `1`**, cur `none`, `MANUAL-V1` | `channel: "beta"` | `GET /download/526e601e… 200`, `__patch_download__ 1` |
| 4 | force-quit + relaunch | **`MANUAL-V2`**, **cur `1`**, next `1` | — | `__patch_install__ 1` |

Renders: `phase0.png`, `phase1_update_stable.png`, `phase2_check_beta.png`,
`phase3_update_stable_after_check_beta.png`,
`phase3b_update_beta_staged.png`, `phase4_executed_v2.png`.

## Why each claim is earned

**`auto_update: false` holds.** Two by-hand launches with patch 1 live on beta
produced **zero** requests and zero events. It is an engine property with no Dart
introspection, so a behavioural absence is the only available proof — and the
absence is meaningful because step 1 later put a real 200 on the server from the
same client, establishing it *could* have asked. Verified in the **shipped
artifact**, not the source: the bundled `shorebird.yaml` inside
`App.framework/flutter_assets` carries `auto_update: false`.

**`checkForUpdate` does not download.** `check(beta)` returned `outdated` while
`current` and `next` both stayed `none`, no `/download/` request was made and no
event row appeared. Availability was reported without any artifact moving.

**`update(track:)` honours its own argument — the load-bearing negative.** Pressed
seconds after `check(beta)` reported `outdated`, `update(stable)` did not download
patch 1. The client log shows *why*, which is stronger than the precommit asked
for: the call issued its request on **`channel=stable`**. Eligibility was asked
about the right track in the first place, rather than a download being declined
downstream. The pair is causal:

    19:28:29  update(stable) -> channel=stable -> no download, next: none
    19:30:03  update(beta)   -> channel=beta   -> download, next: 1

Same client, ~90 seconds apart, **only the argument different**.

**`update` stages; it does not activate.** After `update(beta)`, `next patch` was
`1` while `current patch` stayed `none` and the marker still read `MANUAL-V1`, with
`__patch_download__` present and `__patch_install__` **absent**.

**The staged patch executes on the next launch.** After a by-hand force-quit and
relaunch: `MANUAL-V2`, `current patch: 1`, `__patch_install__ 1`, and the engine's
own account —

    Shorebird updater: active patch is a Route B container
    ROUTEB: parsed, targets=1, built-for=59391e36dd6a3b4489dadac4b1ffedf0
    ROUTEB: running=59391e36dd6a3b4489dadac4b1ffedf0
    ROUTEB: applied 1/1 targets, entering main

`built-for == running` also retroactively justifies fetching the release from the
server instead of installing the local archive: had the patch build's archive been
installed, or a locally rebuilt one, this is the comparison that would have been
wrong — and the failure would have looked like a manual-API defect.

## Two traps that would each have produced a false pass

**1 · `auto_update` was silently never set.** The generated `shorebird.yaml` ships
`# auto_update: false` as a **comment**, and a substring check matched it, so the
key was never written. The fixture would have run with `auto_update` defaulting
to **true**, and Phase 0 — the hinge of the whole arm — would have been
meaningless. Fixed by uncommenting the template's own line rather than appending a
second key (two keys would leave last-wins deciding it), then asserted through the
updater's real parsing rules with a check that exactly one uncommented line
exists, and finally re-verified in the shipped bundle.

**2 · The local archive was the patch build.** `shorebird patch` overwrites
`build/ios/archive`, so after publishing it held `MANUAL-V2` and zero
`MANUAL-V1`. Installing it would have put patched code straight on the device
while every reading looked perfect. The release was fetched from the control
plane instead — the only copy that is definitionally the release.

## Constant blindness, second recorded instance

The fixture's first shape used `const marker = 'MANUAL-V1'` and release 3.0.0+1
(id 122) was cut against it. The patch was **correctly refused**: *"Nothing in
this patch differs from the release, so it would install and change nothing."* A
changed const **declaration** is invisible to the coverage analyzer, which
compares procedure bodies — the same blindness the defines arm hit, reached from
the other direction. The guard was right; publishing would have left the device
on V1 forever with a green CLI. Marker moved into `markerText()` with the armor
the flavor, custom-target and obfuscation arms use, and the release re-cut as
3.1.0+1. Release 122 is left unpatched as the record.
`CONSTANT_BLINDNESS_2.md` carries the detail. **Debt sharpened, not widened: the
refusal is correct, the diagnosis is missing** — the message never says the change
lived in a constant the analyzer cannot see, which has now cost a release cycle
twice.

## What this row does NOT claim

It proves **application code** can select a track. It does **not** fix automatic
clients: `shorebird.yaml`'s `channel:` key is still rejected by the CLI's parser,
so there remains no supported configuration path onto a non-stable track. That
defect stays logged in the tracks row, and closing it is a separate product
decision — support `channel`/`track` in normal configuration, or declare
automatic updating stable-only and require this API for custom tracks.

One reading was not captured: `check(stable)`'s status string was overwritten by
the next press before a screenshot. Re-pressing it was deliberately skipped,
because that would have made the updater's most recent check `stable` and
weakened Phase 3's premise. What stands in its place: the client sent
`channel=stable`, the server answered 200, `stable` had no deployment row, and no
download followed.
