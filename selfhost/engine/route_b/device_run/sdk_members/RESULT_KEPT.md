# SDK instance members on a device, second release: members kept on purpose
<!-- cspell:words callform -->

This repeats `RESULT.md` on a release built so that the dart: SDK members the counter release lacked are kept. Read the scope first.

## Scope: read this first

- One app, one engine cell, one device: the bare `flutter create` counter app and probe stubs of `RESULT.md`, at engine cell `2fc41d3f`
  (Flutter `5c60356c`), version `1.0.0+64`, bundle id `dev.selfhost.untab`, on one iPhone 7 (iOS 15.8.8). Nothing here is claimed beyond that.
- The members were **kept on purpose**, two ways: unreachable call sites in the probe app, and a widened `--sdk-members` list (81 named
  members instead of 4). So the results answer **"is it safe when the release keeps the member?"**, not **"does an ordinary app keep it?"**.
- **They hold only for a release built with `cli_sdk_members.patch`**, which adds 77 members to `routeBRetainedSdkMembers`. That patch is
  not in main (main keeps 4 names, and its comment calls the list a budget), and its snapshot-size cost is not measured here. Widening
  the CLI's allow-list without widening retention gives THROWS (the counter release); widening retention costs snapshot size.
- SAFE still means "resolved in that release". A SAFE key needs a second, different app before it is trusted, and a `thin` SAFE key
  (fewer than 2 probes or fewer than 2 runtime classes) rests on little. Even "not thin" can be two receivers that share an implementation
  (`String` one_byte and two_byte). Receivers that were not probed (`SplayTreeMap`, `LinkedHashMap`, typed-data lists, an `Iterable` from
  `map`/`where`, user subclasses) are outside every SAFE.
- **A tear-off probe only creates the closure; it never calls it.** So a `#tearoff:` key is SAFE here only when its probes resolved
  **and** its call-form key (the same member without `tearoff:`) is SAFE. Otherwise it is `UNCALLED`, and `callform_verdict` in
  `members.tsv` says why (for example `String#tearoff:endsWith` is UNCALLED because `String#endsWith` aborts). A SAFE tear-off key
  still means only "the closure could be made and its call form is SAFE". Follow-up, not done here and with no new device run: make the
  probe call the closure with suitable arguments and measure again.
- **No `dynamic#` key may be widened from this run.** The retention gate does not cover dynamic keys (they have no typed probe to check),
  185 dynamic probes abort the process, and 43 dynamic keys moved from THROWS to CRASH once the member was kept. A by-name call on a
  kept member is the dangerous form.

Data: `result_kept/members.tsv` (one verdict per key, 426 keys), `result_kept/results.tsv` (one row per probe, 1514), `result_kept/side_by_side.tsv`
and `.md` (counter and kept verdicts per key, the lists below), `result_kept/comparison.md` (against #209), `result_kept/kept_check_build{1,2,3}*.tsv`
(what the snapshot profile says per probe, and per key for builds 2 and 3), `result_kept/sweep_logs/` (the sweep result lines behind
`raw_results.tsv`, with the app container path scrubbed), `result_kept/gen/` (probe list). `cli_sdk_members.patch` is the one change to the CLI.
Reproduce: `merge_raw.py result_kept raw_results.tsv 'sweep_logs/iterK*.txt' 'sweep_logs/sweepK*.txt'`, then `tables.py` and `compare.py` as in `RESULT.md`,
then `side_by_side.py result result_kept`. `result/` was regenerated with the tear-off rule; the counts in `RESULT.md` are the earlier ones.

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
  key is missing or stubbed. UNMAPPED probes pass the gate. The gate is validated on the counter release (members the device throws
  on show MISSING). It can only check typed probes, so it covers the 121 typed target keys; the 103 `dynamic#` target keys are not checked.
- Builds and what the gate said for the 121 typed keys among the 224 that threw in the counter release (53, 52 and 0 keys counted before dropping the dynamic ones):

| build | what kept the members | target keys still MISSING or STUB |
| --- | --- | --- |
| 1 | unreachable typed call sites | 53 |
| 2 | plus call sites on `dynamic` receivers | 52 |
| 3 | plus `--sdk-members` for every typed member of those keys | **0** |

- The call sites alone could not keep `num`/`int`/`double` members (`abs`, `floor`, `/`, `<=`, `unary-`, ...), `String.compareTo`/`indexOf`/
  `codeUnitAt`, `DateTime`/`Duration` getters, `Timer`, `Offset` and `Size` getters; `--sdk-members` kept all of them. So the
  retention list is the mechanism that works. For 66 of the 120 typed target keys that turned SAFE the call sites alone had
  already kept the member; for 54 only `--sdk-members` did (`side_by_side.tsv`, column `kept_by`; the build 3 release had both).
- The class mapping was checked on the build 3 profile: `Offset`, `Size`, `Timer`, `DateTime` and `Duration` now map and are REAL. 76
  probes stay UNMAPPED (`Stream.value`/`from_iterable` receivers and a few others); **15 target keys have unmapped probes** (`Stream`
  `listen/map/where/toList/get:first/get:isBroadcast` and their tear-offs, where `kept_in_profile` rests on the one mapped probe;
  `StreamController.get:sink` and `StateError.message`, all unmapped; `Map` `containsValue/get:isNotEmpty/tearoff:addAll/tearoff:containsValue`,
  1 of 4). Their device probes still resolved, so the verdicts stand, but the gate did not check them.
- Device: iPhone 7, iOS 15.8.8, upgrade installs only, never uninstalled.
- Activation: the patch had 1514 - 62 targets. The same 10 targets as in the counter release aborted the patch while it was
  activated (`StreamSubscription.cancel` on controller and broadcast streams, in all 4 forms, and `Map.addAll` on a const map in 2
  forms); they were attributed and left out by the same loop as in the counter run, so activation aborts are not retention problems.
  Patches 1 and 2 never started the sweep: the syslog had stopped, so patch 1's launches showed nothing and the updater marked it bad;
  patch 2 died in activation. Patch 12 ran. The first sweep call (150 launches) and the second (85) were needed; every probe had
  finished by launch 85 of the second.

## Totals

| probe verdict | count |
| --- | --- |
| RESOLVES | 953 |
| THROWS (NoSuchMethodError) | 263 |
| ABORTS | 246 (236 in the call, 10 while the patch was activated; 185 are `dynamic` probes) |
| NOT-RUN | 52 |

| key verdict | counter release (`result/`) | kept release (`result_kept/`) |
| --- | --- | --- |
| SAFE | 112 (18 thin) | **242** (60 thin, 182 not thin) |
| UNCALLED (tear-off, call form not SAFE) | 24 | 44 |
| THROWS | 224 | 40 (all `dynamic#`) |
| CRASH, observed on the device | 55 (11 typed) | 90 (4 typed, 86 dynamic) |
| CRASH(host) | 4 | 3 |
| PARTIAL | 7 | 7 |

(Before the tear-off rule the same tables read SAFE 136 and 286, UNCALLED not existing; the 24 and 44 UNCALLED keys were SAFE.)

Per key, counter release (rows) against kept release (columns); the complete lists are in `result_kept/side_by_side.md`:

| counter \ kept | SAFE | UNCALLED | THROWS | CRASH | CRASH(host) | PARTIAL |
| --- | --- | --- | --- | --- | --- | --- |
| SAFE | 112 | 0 | 0 | 0 | 0 | 0 |
| UNCALLED | 3 | 21 | 0 | 0 | 0 | 0 |
| THROWS | **120** | 21 | 40 | 43 | 0 | 0 |
| CRASH | 7 | 2 | 0 | 46 | 0 | 0 |
| CRASH(host) | 0 | 0 | 0 | 1 | 3 | 0 |
| PARTIAL | 0 | 0 | 0 | 0 | 0 | 7 |

## What moved

- **THROWS to SAFE: 120 keys, all typed** (42 thin). With the member kept, a typed call resolves, and for a tear-off key its call form is
  SAFE too. 66 of them were already kept by the call sites, 54 only by `--sdk-members`. The list, with `kept_by`, is in
  `result_kept/side_by_side.md`. The 20 `dynamic#tearoff:*` keys that looked like THROWS to SAFE are UNCALLED: their call forms throw or crash.
- **THROWS to UNCALLED: 21 keys** (20 `dynamic#tearoff:*`, and `Map#tearoff:addAll`, whose call form `Map#addAll` crashes).
- **THROWS to CRASH: 43 keys, all `dynamic#`.** A call by name on a `dynamic` receiver, which threw in the counter release, now aborts
  the process when the member is kept. Keeping a member does not make the dynamic form safe. **Do not widen any `dynamic#` key from this
  run**: the gate does not cover them, 185 dynamic probes abort, and 43 keys went from THROWS to CRASH. The 40 `dynamic#` keys that still
  throw stay unusable.
- **CRASH to SAFE: 7 keys**: `Iterable.any/contains/every/isEmpty/isNotEmpty/last` and `List.sort`. In the counter release those aborted
  because the member was missing; kept, they resolve. (`dynamic#tearoff:any` and `dynamic#tearoff:toSet` moved CRASH to UNCALLED.)
- **Typed keys that still crash: 4**: `StreamSubscription.cancel` (and its tear-off), `Map.addAll`, `String.endsWith`.

## Still MISSING or STUB with `--sdk-members`

None of the 121 typed target keys. Outside the targets (members that were SAFE or crashing in the counter release) the profile still shows
no real code for: `String.get:isNotEmpty`, `int.&`, `int.<<`, `Iterator.moveNext`, `Iterator.get:current` (MISSING), and `String.endsWith`,
`int.get:isEven` (STUB). `int.&`, `int.<<` and `Iterator.*` resolve anyway; `String.endsWith` aborts, and `String.get:isNotEmpty` and
`int.get:isEven` are CRASH(host), untried on the device. These were not retention targets, so no `--sdk-members` entry was added for them.

## Comparison with #209

`result_kept/comparison.md`. #209 accepts 75 keys; the device agrees on 74 and disagrees on `dynamic#tearoff:cancel`, as before. It also
accepts 16 keys that are THROWS or UNCALLED here, mostly tear-offs (`dynamic#tearoff:split`, `Set#tearoff:remove`, ...), which is the
tear-off problem above, not a measurement of the member. #209 refuses 135 keys that are SAFE here and not thin (49 thin).
Under the scope above, that is "safe when kept with the 77-member patch", one app, one engine cell, one device. It is evidence about
what a kept member does, not a reason to accept those keys without widening retention, and it ignores the 4 typed crashes.

## Caveats

- 52 probes never ran (NOT-RUN): 16 host-abort probes (`excluded_ids.tsv`) and 36 dynamic and tear-off probes of
  `& addAll clamp putIfAbsent moveNext`, which make the CLI refuse the patch exactly as in `RESULT.md`. A further 10 probes were left out
  of the patch because they abort it during activation and count as ABORTS (`map_addAll__const__d` was a host abort in the counter
  release and is an activation abort here, which is why the host-abort count is 16 and not 17). So 62 probes are left out of the patch.
  None were retried.
- The kept release contains the call sites and the retained members of the whole list, so a `kept_by` of `call sites and --sdk-members`
  does not say which one alone would have sufficed; the build 2 profile only says the call sites kept it.
- The 246 ABORTS are 236 aborts in the call (the sweep logs hold 236) and the 10 activation aborts. 234 of the 236 have a VM
  `unreachable code` message in the sweep's debugger output; the other 2 do not, and may be harness-side (the harness kills the app on the
  next launch after an idle period). I did not check them one by one.
- The sweep needed about 235 launches. `sweepK2.txt` carries about 100 extra `SWEEP_DONE` lines from before the `sweep.sh` fix (a
  `grep -q` under `pipefail` failed on a multi-GB syslog, so the sweep kept launching after it was done); the merge ignores them.
  `sweep.sh` now stops at the first `SWEEP_DONE`, and also stops with an error when the syslog shrinks or does not grow during a launch.
- The caveats of `RESULT.md` about the updater's bad-patch list and the 6 s timer apply unchanged. Patch 1 of this release was marked bad,
  so the sweep ran as patch 12 of the same release.
- `kept_check_build1.tsv` has no per-key file; build 2 and 3 have one. `kept_check_build3.tsv` is the final release's per-probe check.
