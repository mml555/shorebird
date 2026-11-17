# SDK instance members on a device: which ones crash a Route B patch

## Scope: read this first

- The release is a bare `flutter create` counter app, with one extra file of probe stubs, built at engine cell `2fc41d3f`
  (Flutter `5c60356c`). It is one release of one small app.
- **SAFE means "resolved in that release", nothing more.** It is not "safe in any Flutter release". What an AOT snapshot keeps
  (tree shaking, type-flow analysis, dispatch tables) depends on what the app uses, so another app can keep members this one
  dropped and drop members this one kept.
- The data itself shows that retention is app-specific: `String.length`, `Iterable.map` and `List.insert` have no dispatch
  entry in this release, although almost every Flutter app uses them. Nothing here supports "members the Flutter framework
  uses are retained in every release"; that claim has no evidence behind it.
- So this measurement cannot replace a per-release check, and a SAFE key needs a second, different app before it is trusted.
  What it does give is crash evidence: a CRASH is a real abort or segfault of a patch calling that member on that runtime class.
- A SAFE key can rest on little. `members.tsv` has `probes` and `runtime_classes` per key and a `thin` flag on SAFE keys with
  fewer than 2 probes or fewer than 2 runtime classes (18 keys). Crashes depend on the runtime class (`Iterable.contains` aborts
  on a const list, `List.sort` on const, filled-fixed and unmodifiable lists), so a thin SAFE key is weak.

Data: `result/members.tsv` (one verdict per key, 426 keys), `result/results.tsv` (one row per probe, 1514 probes, every one keyed),
`result/comparison.md` (against PR #209), `result/gen/` (the probe list the run used).

## Method

- Release: `shorebird release ios` by this fork's CLI, bundle id `dev.selfhost.untab`, version `1.0.0+63`. Its `main.dart` is
  `gen_device_probe.py`'s `main_release.dart`; its own code calls none of the probed members.
- Probes: 1514, the host matrix's ids (`sdk_instance_members` on #209's branch) plus device-only receivers (`StreamSubscription`,
  `dart:ui` `Size`/`Offset`, more `List`/`Iterable` receivers such as `generate`). Each is a top-level `void p_<id>()` that does
  nothing in the release; the patch replaces its body with the call on one runtime class, in one form (typed receiver, `dynamic`
  receiver, and a tear-off of each).
- Patch: one Route B patch carrying all probe bodies. The runner marks each probe with a file before calling it. An abort kills
  the process and the next launch records that probe as `ABORTS` and goes on, so a sweep takes about one launch per aborting
  probe (about 150 launches here).
- Keys: the host matrix gives each probe its key. A probe it has no key for (receivers the host did not build, such as
  `generate`, and `==`) takes `dynamic#<selector>` when dynamic, else the key its siblings of the same probe family and form carry.
  `tables.py` stops on a probe it cannot key.
- Probe verdicts: RESOLVES (ran, or threw an error that is not a NoSuchMethodError naming the member), THROWS (NoSuchMethodError
  naming the member: no dispatch entry in the release), UNATTRIBUTED (NoSuchMethodError naming another member), ABORTS (process
  died), NOT-RUN.
- Key verdicts: CRASH (a probe aborted on the device), CRASH(host) (no device abort, but a probe aborted on the host matrix and was
  not tried on the device), THROWS (no crash, some probe throws), PARTIAL (no crash, no throw, some probes never ran), SAFE (every
  probe resolves). `tables.py`, `compare.py` do the joining; `merge_raw.py` merges the result lines of the sweep logs.
- Device: iPhone 7 (iPhone9,1), iOS 15.8.8. The app was only upgrade-installed over the same bundle id.
- Rerun: copy `../env.example.sh` to `env.sh`, fill it in, start `../bin/up.sh`, then `release_probe.sh`, a patch of the generated
  `main_patched.dart` (`gen_device_probe.py <dir>`), and `sweep.sh`. `VERSION` was `1.0.0+63`.

## Totals

| probe verdict | count |
| --- | --- |
| RESOLVES | 583 |
| THROWS (NoSuchMethodError) | 721 |
| UNATTRIBUTED | 4 |
| ABORTS | 153 (145 in the call, 8 while the patch was activated) |
| NOT-RUN | 53 |

| key verdict | keys |
| --- | --- |
| SAFE | 136 (18 thin, 118 not thin) |
| THROWS | 224 |
| CRASH, observed on the device | 55 (11 typed members, 44 dynamic selectors) |
| CRASH(host), host evidence only | 4 (3 typed members, 1 dynamic selector) |
| PARTIAL | 7 (all dynamic selectors) |

## Crashing members (typed receiver)

| key | verdict | where |
| --- | --- | --- |
| `dart:core#Map#addAll` | CRASH | one activation abort on the device (const map, attributed as below); literal, unmodifiable and json aborted on the host and were not tried on the device |
| `dart:core#Set#remove` | CRASH(host) | literal set: segfault on the host, not tried on the device |
| `dart:core#String#get:isNotEmpty` | CRASH(host) | one-byte and two-byte strings: aborted on the host, not tried on the device |
| `dart:core#int#get:isEven` | CRASH(host) | smi and mint: aborted on the host, not tried on the device |
| `dart:core#String#endsWith` | CRASH | one-byte and two-byte strings |
| `dart:core#List#sort` | CRASH | filled-fixed, const and unmodifiable lists |
| `dart:core#Iterable#contains` | CRASH | filled-fixed, const and unmodifiable lists |
| `dart:core#Iterable#every` | CRASH | a plain list |
| `dart:core#Iterable#any`, `get:isEmpty`, `get:isNotEmpty`, `get:last` | CRASH | a `List.generate` list (typed form) |
| `dart:async#StreamSubscription#cancel`, `#tearoff:cancel` | CRASH | the process aborts while the patch is activated, before main (controller and broadcast subscriptions) |

Crashing dynamic selectors (a call by name on a `dynamic` receiver) are in `result/comparison.md`. Which runtime class and form
crashed: `result/members.tsv`, column `crashing_runtime_classes_and_forms`.

The crash depends on the runtime class, not the declared type: `Iterable.any` aborts on a `generate` list; `Iterable.contains`
only on const, unmodifiable and filled-fixed lists.

## Not a crash, but unusable here

224 keys (721 probes) throw a NoSuchMethodError naming the member: a call, typed or `dynamic`, of a member the release has no
dispatch entry for (for example `String.length`, `List.insert`, `Iterable.map`, `Stream.listen`, `DateTime.difference`, `num.abs`).
A patch calling one gets a Dart exception at that call, not a dead process. The list is in `result/comparison.md`.

## Comparison with #209

Against #209's head `961889d35` (the host-measured list; `result/comparison.md`):

- #209 accepts 75 keys. The device agrees on 74 (SAFE; 11 of them thin). It disagrees on one: `dynamic#tearoff:cancel`, which
  #209 accepts and which aborts the process during patch activation on a `StreamSubscription`.
- #209 refuses 55 keys that are SAFE on the device and not thin, and 7 more that are SAFE but thin. 7 dynamic keys it refuses have no
  crash among the probes that ran but some probes never ran. 224 refused keys throw instead of crashing.
- Per the scope above, this is "resolved in that release", so it is evidence for the allow-list, not a replacement for it.

## Caveats

- A tear-off probe creates the closure and never calls it (`gen_device_probe.py`: `final Object? t = ...; if (t is! Function)`). A
  `SAFE` tear-off verdict therefore says nothing about calling it, and the CLI accepts a tear-off key only when its call form is
  accepted too (`gen_dart_lists.py`, `RouteBRetention`). Of the 118 SAFE keys that are not thin, 24 tear-offs fail that rule, so
  the CLI's accepted list has 94. Follow-up: make the probe call the closure and re-run on the device.
- 53 probes never ran: 17 aborted on the host matrix and were not tried on the device (`excluded_ids.tsv`, `host-abort`), and the
  dynamic and tear-off forms of the selectors `& addAll clamp putIfAbsent moveNext`. A patch that calls a member by name makes
  the CLI keep every framework member of that name, and the CLI refuses the whole patch ("changed members cannot be carried"):
  `bisect_dynamic.py` found these five with dry-run patches (`result/dynamic_culprits.txt`).
- Activation aborts are attributed by a heuristic, not proved one by one. The patch installer applies targets in name order and logs
  one line after each; an abort during activation leaves the first target missing from that log as the culprit. For
  `StreamSubscription.cancel` the sweep was re-patched without the named target and run again, eight times, and each run named the
  next target (`result/activation_abort_attribution.txt` is the loop's output; the activation log lines themselves were not
  kept). `Map.addAll` on a const map was attributed the same way in an earlier run. A from-iterable subscription and the `Timer` probes
  activated and ran after them.
- The updater marks a patch bad after two boots that die before a successful-launch report, and keeps that list per release version
  across a new app id. The sweep therefore starts 6 s after `runApp` (`Timer` in the release's `main`; the CLI refuses to patch
  `main`), and the release version was raised to `1.0.0+63` to reset that list.
- The first 14 `future_then` results (`future_then__async_fn__*`, `__value__*`, `__completer__*`, `__delayed__s/ts`) come from an
  earlier install of the same probe app (same bundle id, Documents folder and probe bodies) made before the release was rebuilt. The
  copy in `result/raw_results.tsv` is the only one; the device's own results.tsv was not pulled, so they cannot be reproduced from
  the device.
- A RESOLVES that threw the member's own error (`Unsupported operation`, 19 probes) counts as resolved.
- Host-only receivers (Iterable from `where`/`map`/`keys`/`values`, Stream from a controller) the device release cannot build without
  calling a probed member are only in the host matrix.
