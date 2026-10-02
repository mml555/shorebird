# The 0012/0013 cycle — the build/mint/release record

2026-08-17. **This file is STATE, not a verdict.** Neither claim is scored here
and neither may be scored from this file.

**THE DEVICE RUN HAPPENED.** Both claims are now scored, in their own files:

* `claim1_0012_instrumentation_verdict.txt`
* `claim2_armA_measurement.txt`

Device artifacts are preserved under `cycle96_device/`. The sections below record
how the specimen was built and verified; the "THE DEVICE RUN, and how to score
it" section further down was written BEFORE the run and is left unedited, so the
scoring criteria can be read as precommitted rather than fitted to the result.

## What the cycle produced, and how each link was checked

Every row was verified on the artifact itself, not inferred from the step before.

| link | evidence |
|---|---|
| patch `0012` applied | byte-identical to all three captured artifacts (`shorebird.cc.snapshot`, `lib_object.cc.snapshot`, `dart_route_b_trace.h`) — the handoff's step 2 was already complete |
| patch `0013` written | `0013-routeb-assert-offset-supply.patch`, compile-clean, capture invariant declared-then-verified (1 tracked file, 64 added / 3 removed, 6 untracked all pre-existing) |
| iOS engine built | `ninja exit=0`, 14m54s, `logs/ios_release_20260816-234833.log` |
| built engine carries the instruments | `rbtrace v=5`, `tpool_status=`, `assert-pool-offset supplied=`, `.assert_pool_offset`, `InterpretCall` all present; `RouteBThing.value` **absent** (landmine gone) |
| cell minted | `50bdae36f6dafbe1da17852a42e119518e8e5cf4`, donor `cd137db6…` |
| cell audited | `AUDIT CLEAN`, 20/20, incl. "served platform dill is the one the address was computed over" |
| `~/.shorebird` switched | by **real fetch**, never a stamp: cache `artifacts`/`dart-sdk`/`downloads` deleted, all 15 stamps deleted, `engine.version` set, `flutter precache --ios` refetched |
| consumed engine is the built engine | `sha256 4e2a46f1…` in cache == `4e2a46f1…` as built. Donor's was `98ff255f…` with **0** markers, so the swap is measured, not assumed |
| release cut | 96 = `1.0.7+1`, Route B path confirmed by **5,880 patchable sites (1,807/MB)** against the 100/MB threshold — release 33's non-Route-B failure showed 8 |
| release preserved | `evidence/releases/96/`, LC_UUID `ab1c1c7aa8e2397cb2ddb1904259d3fd`, preserved BEFORE the patch re-archived over `build/ios/archive` |
| shipped engine carries the instruments | release 96's own IPA: all five markers present, `RouteBThing.value` absent, `__TEXT,__text` size `0x8c0ed0` — identical to the cache binary's. File size differs (19145264 vs 19089496) because Xcode re-signs and thins, which is why the section is compared and not the file hash |
| patch published | Patch 1 (id 62), stable track, `431 B` bytecode / `709 B` container — the same shape as the arm-2 patch |
| patch content correct | `replacement_0.dart` line 4 is `String routeBValue() => 'NEW-kill';`; the 431 B bytecode carries `optionsNEW-killrouteBValue`. Read off the compiled artifact, not the CLI's success line |

The chain from source edit to shipped bytes is therefore closed **without the
device**: built → minted → published → fetched → shipped, each link measured.

## The target is unchanged

`routeBValue() => 'OLD-kill'` at `lib/main.dart:65`, called from `build()` at
`:232`. `gate5_armA_fold_refuted.txt` removed the only condition that would have
justified replacing it, so it was not replaced. The fixture source was reverted
to `OLD-kill` after the patch was compiled; the *patch* carries `NEW-kill`.

## What `0013` changed, and why claim 1 row 3 could not have run without it

`0012` deleted the `0xd4a8` / `"RouteBThing.value"` landmine — correctly. But that
special case was **the only path that ever supplied a non-zero `pool_offset`**,
and the runtime gates the demoted assertion on `pool_offset != 0`
(`runtime/lib/object.cc:1257`). Verified, not assumed: one call site, argument a
literal `0`, no env var, no second caller.

So on the tree as captured, row 3 — *the stale-offset negative control* — was
**structurally unrunnable**, and the cycle could only have returned rows 1 and 2,
which the precommit requires be reported as PARTIAL and never as "instrumentation
works". `0013` restores a supply side that is a default plus an operator override
rather than a per-selector constant.

## THE DEVICE RUN, and how to score it

Device: R1 iPhone 7 / iOS 15.8.8, **WIRED** (`8cb4bc98…`). Currently
`unavailable`; nothing on USB. This is the only remaining step.

Trace lands at **`<patch artifact path>.routeb.trace`** (`shorebird.cc:233`), i.e.
beside the installed patch under
`/Library/Application Support/shorebird/shorebird_updater/patches/1/`.

### Claim 1 first, on its own trace. All three rows or it is PARTIAL.

| row | pass condition | fail meaning |
|---|---|---|
| 1 | line begins `rbtrace v=5` | a `v=4` line means the device is not running the built engine — everything downstream is measuring the old instrument |
| 2 | `tpool_status` ∈ {3,4,5} **and** `tpool_scanned > 0` | `tpool_status=0` (NOT_REQUESTED) means the derived scan did not run — the exact defect `0012` exists to remove, reappearing |
| 3 | `pool_offset=0xd4a8` present **and** (`pool_status=4` POOL_ENTRY_NOT_FUNCTION **or** `pool_entry_equals_target=0`) **while** the derived `tpool_*` independently reports its own location in the SAME line | a green assertion proves nothing; only a FAILING one proves the two instruments are separate |

**Row 3 has a third outcome that is neither pass nor fail.** `0xd4a8` was measured
off release 26; whether it lands in range in release 96 is not knowable in
advance. If `pool_status=2` (`INDEX_OUT_OF_RANGE`), that is an instrument
artifact, **not** a row-3 result — pick a valid-but-different slot from the
derived scan's own report and re-run **on the same build** by writing it to:

```
<patch artifact path>.assert_pool_offset      # e.g.  0x7d0
```

Base-0 parse; a malformed value is reported and the default stands. The trace's
`pool_offset=` field records what was **actually** supplied, so a misread sidecar
cannot be mistaken for an honoured one. No rebuild, no new release, no new patch.

### Claim 2 only after claim 1 passes, and it is a MEASUREMENT, not an explanation

| observation | what it licenses |
|---|---|
| `tpool_status=4` UNIQUE | identity obtained. Feed `tpool_offset` to `assert_result_consumed.sh --pool-offset` against **release 95's** preserved `App` — that, and only that, retires or confirms consumption |
| `tpool_status=3` ABSENT | first positive evidence for the inlining hypothesis — but it must still explain why release 91 worked, and until it does it is a lead |
| `tpool_status=5` AMBIGUOUS | report `tpool_index` AND `tpool_index2`; feed `--pool-offset` **nothing**. Choosing one would be a confident wrong answer wearing a measurement's clothes |

**None of the three is an `OLD-kill` explanation on its own.** Arm A's
precommitted table (`gate5_arms_precommit.md`) is unchanged and still requires
`NEW-kill` on screen for a PASS. A pool measurement is not a screen.

### Release 95 — fetched, preserved, and the scoring path REHEARSED

It was not on this machine (`evidence/releases/` held 24–39 and `twoengine-*`
only). Fetched from the control plane this session and preserved at
`evidence/releases/95/` — `App`, `App.dSYM.DWARF`, `LC_UUID`.

**Provenance matches the three ways `gate5_armA_fold_refuted.txt` recorded**, and
was checked rather than assumed: App UUID, dSYM UUID and the `LC_UUID` file are
all `3A9A05AB-864F-37EA-8615-D5B4773A33F7`. The preserved `App` also differs from
release 96's, so it is not the current build wearing an old label.

`preserve_release_evidence.sh` exited before writing `RECORDED` (it also wants the
`.ipa`, which was not fetched). The two artifacts claim 2 needs are present.

**The scoring path was then rehearsed against known prior results, so a broken
instrument would surface now and not after the device run:**

* `--symbol routeBValue --symbols App.dSYM.DWARF` → resolves at `0xe9ff4`, the
  exact address in `gate5_armA_site_identity.txt`, and returns `NOT LOCATED` —
  the documented state, and the reason `--pool-offset` is needed at all.
* `--pool-offset 0x8440` → `site 0xb57d0`, entry `0x7`, **CONSUMED** —
  reproducing `gate5_armA_fold_refuted.txt`'s release-95 row exactly.

So the probe runs, resolves symbols, reads pool offsets, and reproduces two
independent prior measurements. **The only input claim 2 still lacks is the
device trace's `tpool_offset`.**

## Auth, and a rig defect found in passing

The stored user-OAuth credential **expired 2026-08-16T03:16:01Z** and refresh is
dead (`44715902`). Underneath that is a server misconfiguration:

```
PUBLIC_BASE_URL      = http://10.0.0.7:18080
SHOREBIRD_JWT_ISSUER = http://169.254.189.3:18080     <-- stale link-local
```

The server mints JWTs stamped with an address the deployment then rejects, so
**re-logging in does not fix it** — a fresh token carries the same wrong `iss`.
Exporting `SHOREBIRD_JWT_ISSUER` clears the client half; this cycle published via
`SHOREBIRD_TOKEN` (the container's bootstrap `API_KEY`, user-authorised), which is
the path the 08-16 handoff documents and the one row in the vanish table that
persisted. `credentials.json` was **not** modified.

Fixing `SHOREBIRD_JWT_ISSUER` to equal `PUBLIC_BASE_URL` is a real repair and is
NOT done here: it needs a control-plane restart, which is not something to do
mid-cycle.

## Durability content-read — PARTIAL, and deliberately recorded as such

The prerequisite is a content-read of `releases`/`patches` **and** `audit_log`.

* `releases` — **READ.** 96 present, `ios: active`; ids 89–96 dense and
  consecutive.
* `patches` — **READ.** patch 62 (`#1`), track stable.
* `audit_log` — **NOT READ.** It needs `docker exec` into `cps-ios`, which this
  session's permissions refused. The density signature the prior lane used
  (`max == count`, `sqlite_sequence` high-water == `max(id)`) is therefore
  unverified for this publish.

So publish success here is **provisional on the releases/patches half only**.
Given four publishes have previously returned success and committed nothing, that
gap is named rather than glossed. Nothing vanished as of the reads above.
