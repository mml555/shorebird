# MAOT-5 (#69) — not trampolines, not the instrument: an elimination chain

## Two framings retracted

**"super does not observe the cell"** — retracted last round: the paired
control failed identically, so it was never super-specific.

**"a Stage-2 integration regression: #67 static path + trampolines"** — also
refuted, this round. With trampolines **OFF** the same fixture fails:

```text
tramp OFF: call.0=OLD-CONTROL | diagnostic swap=0 -> call.1=OLD-CONTROL
                              | REAL install=0    -> call.2=OLD-CONTROL
tramp ON : call.0=OLD-CONTROL | diagnostic swap=0 -> call.1=OLD-CONTROL
                              | REAL install=0    -> call.2=OLD-CONTROL
```

Trampolines are not implicated in either configuration.

## The instrument is not implicated either

`Dart_MaotInstallForTesting` — the production path m3/#67 proves green — was
run on the **same declaration in the same process** and also returned success
while the call kept returning `OLD-CONTROL`. So this is not an artefact of
the diagnostic swap.

## Everything that can be checked, checks out

| check | result |
|---|---|
| call site cell-lowered | `call_sites = 1` |
| blocking escapes | `escapes = 0` — fully installable |
| pool slot identity | `pool[index] IS the cell = YES` |
| swap landed on the right cell | `cell.implFunction = Function 'controlNew'` |
| cell halves consistent | `cell.implCode == implFn.CurrentCode = YES` |
| real install path | returns `0` |
| trampolines | fails OFF and ON |

A declaration that is selected, seeded, lowered, unblocked and successfully
installed — whose call site provably loads the right cell — still executes
the release body.

## What this leaves

`m3` (#67) is green and proves this exact mechanism works for `tiny`. So the
difference is between **m3's fixture and this one**, not in the mechanism.

The next step is narrow and the tooling already exists: dump
`callControl`'s final instructions in *this* fixture with
`--maot_dump_caller_code`, as was done for the super pair, and compare
against m3's working caller. If the cell-load sequence is absent here, the
question becomes why lowering was counted but not emitted; if it is present,
the divergence is below it.

I did that dump for the **m5super** fixture, not this one, and should not
assume it carries over.

## Not claimed

* No conclusion about super. Its result is contaminated by this same failure.
* No claim that #67 is affected: m3 is green and unchanged.
* No disposition touched, no fix attempted, no #64 cell moved.
* `super/unproven` stays blocking; `MonomorphicSmiableCall` paused.
