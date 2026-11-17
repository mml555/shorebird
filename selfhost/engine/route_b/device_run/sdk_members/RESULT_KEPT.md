# SDK instance members on a device, second release: members kept on purpose

This repeats `RESULT.md` on a release built so that the dart: SDK members the counter release lacked are kept. Read the scope first.

## Scope: read this first

- The release is the same bare `flutter create` counter app and probe stubs as `RESULT.md`, at engine cell `2fc41d3f` (Flutter
  `5c60356c`), version `1.0.0+64`, bundle id `dev.selfhost.untab`, but **the members were kept on purpose**, two ways:
  unreachable call sites (below) and a widened `--sdk-members` list (81 named members instead of 4).
- So these results answer **"is it safe when the release keeps the member?"**, not **"does an ordinary app keep it?"**. A key that is
  SAFE here is SAFE only if a release really keeps that member; this measurement says nothing about which members a real app keeps.
  The counter release (`RESULT.md`) is still the only measurement of what a plain app keeps, and of one app only.
- SAFE still means "resolved in that release". A SAFE key needs a second, different app before it is trusted, and a `thin` SAFE key
  (fewer than 2 probes or fewer than 2 runtime classes) rests on little.

Data: `result_kept/members.tsv` (one verdict per key, 426 keys), `result_kept/results.tsv` (one row per probe, 1514), `result_kept/side_by_side.tsv`
and `.md` (counter and kept verdicts per key, the lists below), `result_kept/comparison.md` (against #209), `result_kept/kept_check*.tsv`
(what the snapshot profile says per probe and per key), `result_kept/gen/` (probe list). `cli_sdk_members.patch` is the one change to the CLI.

## Method

- Same 1514 probes, one patch carrying all bodies, same runner, `merge_raw.py`, `tables.py` and `compare.py` as `RESULT.md`.
- Measurement CLI: the **pre-#209 devrun CLI at `d7e5325eb`**, not a CLI with #209's allow-list, plus `cli_sdk_members.patch`, which
  adds the 77 typed SDK members of the 224 keys that threw in the counter release to `routeBRetainedSdkMembers`
  (the class and member names are in the patch).
- Release changes (`gen_device_probe.py`, `KEPT_CALLS=1`): a `keptCalls()` function, called only under
  `Platform.numberOfProcessors > 1000000` (never true, but the compiler cannot prove it), holds one non-inlined call per typed probe
  (receivers built as in the probe, or a tear-off). `KEPT_DYNAMIC_SELECTORS` adds a call on a `dynamic` receiver for the 31 selectors the
  first build still missed. The app's behaviour is unchanged.
- **Retention gate** (`check_kept.py`, run by `release_probe.sh` before anything is signed or installed): reads
  `route_b_snapshot_profile.json`, maps each non-dynamic probe to the VM class of its runtime receiver (`_OneByteString`, `_Smi`, `_Double`,
  `Duration`, ...), and requires real code (not a lazy-compile stub) for the member on that class. The run stops when a target
  key is missing or stubbed. The gate is validated on the counter release (members the device throws on show MISSING).
- Builds and what the gate said for the 224 keys that threw in the counter release:

| build | what kept the members | target keys still MISSING or STUB |
| --- | --- | --- |
| 1 | unreachable typed call sites | 53 |
| 2 | plus call sites on `dynamic` receivers | 52 |
| 3 | plus `--sdk-members` for every typed member of those keys | **0** |

- The call sites alone could not keep `num`/`int`/`double` members (`abs`, `floor`, `/`, `<=`, `unary-`, ...), `String.compareTo`/`indexOf`/
  `codeUnitAt`, `DateTime`/`Duration` getters, `Timer`, `Offset` and `Size` getters; `--sdk-members` kept all of them. So the
  retention list is the mechanism that works. For 67 of the 121 typed target keys that turned SAFE the call sites alone had
  already kept the member; for 54 only `--sdk-members` did (`side_by_side.tsv`, column `kept_by`; the build 3 release had both).
- The class mapping was checked on the build 3 profile: `Offset`, `Size`, `Timer`, `DateTime` and `Duration` now map and are REAL. 76 probes
  stay UNMAPPED (`Stream.value`/`from_iterable` receivers, none of them target keys).
- Device: iPhone 7, iOS 15.8.8, upgrade installs only, never uninstalled.
- Activation: the patch had 1514 - 62 targets. The same 10 targets as in the counter release aborted the patch while it was
  activated (`StreamSubscription.cancel` on controller and broadcast streams, in all 4 forms, and `Map.addAll` on a const map in 2
  forms); they were attributed and left out by the same loop (`iter_k.sh`), so activation aborts are not retention problems.
  Patches 1 and 2 never started the sweep: the syslog had stopped, so patch 1's launches showed nothing and the updater marked it bad;
  patch 2 died in activation. Patch 12 ran. The first sweep call (150 launches) and the second (85) were needed; every probe had
  finished by launch 85 of the second.

## Totals

| probe verdict | count |
| --- | --- |
| RESOLVES | 953 |
| THROWS (NoSuchMethodError) | 263 |
| ABORTS | 246 (185 are `dynamic` probes) |
| NOT-RUN | 52 |

| key verdict | counter release | kept release |
| --- | --- | --- |
| SAFE | 136 (18 thin) | **286** (62 thin, 224 not thin) |
| THROWS | 224 | 40 (all `dynamic#`) |
| CRASH, observed on the device | 55 (11 typed) | 90 (4 typed, 86 dynamic) |
| CRASH(host) | 4 | 3 |
| PARTIAL | 7 | 7 |

Per key, counter release (rows) against kept release (columns); the complete lists are in `result_kept/side_by_side.md`:

| counter \ kept | SAFE | THROWS | CRASH | CRASH(host) | PARTIAL |
| --- | --- | --- | --- | --- | --- |
| SAFE | 136 | 0 | 0 | 0 | 0 |
| THROWS | **141** | 40 | 43 | 0 | 0 |
| CRASH | 9 | 0 | 46 | 0 | 0 |
| CRASH(host) | 0 | 0 | 1 | 3 | 0 |
| PARTIAL | 0 | 0 | 0 | 0 | 7 |

## What moved

- **THROWS to SAFE: 141 keys** (121 typed, 20 `dynamic#`; 44 of them thin). Every one of the 121 typed keys that threw is now SAFE: with the
  member kept, a typed call resolves. They are listed with their kept-by in `result_kept/side_by_side.md`.
- **THROWS to CRASH: 43 keys, all `dynamic#`.** A call by name on a `dynamic` receiver, which threw in the counter release, now
  aborts the process when the member is kept (185 dynamic probes abort). Keeping a member does not make the dynamic form safe;
  the dynamic form is the more dangerous one. The 40 dynamic keys that still throw are all `dynamic#`.
- **CRASH to SAFE: 9 keys**: `Iterable.any/contains/every/isEmpty/isNotEmpty/last`, `List.sort`, `dynamic#tearoff:any`,
  `dynamic#tearoff:toSet`. In the counter release those aborted because the member was missing; kept, they resolve.
- **Typed keys that still crash: 4**: `StreamSubscription.cancel` (and its tear-off), `Map.addAll`, `String.endsWith`.

## Still MISSING or STUB with `--sdk-members`

All 224 target keys are REAL in the profile. Outside the targets (members that were SAFE or crashing in the counter release) the profile
still shows no real code for: `String.get:isNotEmpty`, `int.&`, `int.<<`, `Iterator.moveNext`, `Iterator.get:current` (MISSING), and
`String.endsWith`, `int.get:isEven` (STUB). The SAFE ones resolve anyway (`int.&`, `int.<<`, `Iterator.*`); the crashing ones
(`String.endsWith`, with the stub, and the two `CRASH(host)` keys) stay crashes or untried. These were not retention targets,
so no `--sdk-members` entry was added for them.

## Comparison with #209

`result_kept/comparison.md`. #209 accepts 75 keys; the kept device run agrees on 74 and disagrees on `dynamic#tearoff:cancel` as before.
It refuses 161 keys that are SAFE here and not thin (51 thin). Under the scope above that is "safe when kept", so it is no argument for
accepting them without a retention check; it does show that for a typed call the crash risk is not the problem once the member is kept.

## Caveats

- 52 probes never ran: the 17 host-abort probes (`excluded_ids.tsv`), 10 activation-abort probes, and the dynamic and tear-off forms
  of `& addAll clamp putIfAbsent moveNext`, which make the CLI refuse the patch exactly as in `RESULT.md`. They were not retried.
- The kept release contains the call sites and the retained members of the whole list, so a `kept_by` of `call sites and --sdk-members` does
  not say which one alone would have sufficed; the build 2 profile only says the call sites kept it.
- The sweep needed about 235 launches. `sweep.sh` had a bug that let it keep launching after `SWEEP_DONE` on a large syslog (the `grep -q`
  and `pipefail` interaction); it now stops at the first `SWEEP_DONE`.
- The caveats of `RESULT.md` about the updater's bad-patch list and the 6 s timer apply unchanged. Patch 1 of this release was marked bad,
  so the sweep ran as patch 12 of the same release.
