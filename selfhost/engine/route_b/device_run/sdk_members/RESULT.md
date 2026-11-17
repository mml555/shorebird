# SDK instance members on a device: which ones crash a Route B patch

Measured on a real Flutter release on an iPhone, to replace the host-only measurement behind PR #209's
allow-list (`route_b_sdk_measurements.dart`). Data: `result/members.tsv` (one verdict per key, 420 keys),
`result/results.tsv` (one row per probe, 1514 probes), `result/comparison.md` (against #209).

## Method

- Release: a Flutter app (`flutter create`, bundle id `dev.selfhost.untab`, release version `1.0.0+63`) whose own code
  calls none of the probed members, built with `shorebird release ios` by this fork's CLI at engine cell `2fc41d3f`
  (Flutter `5c60356c`). Its `main.dart` is `gen_device_probe.py`'s `main_release.dart`.
- Probes: 1514, the host matrix's ids (`sdk_instance_members` on #209's branch) plus device-only receivers
  (`StreamSubscription`, `dart:ui` `Size`/`Offset`, more `List`/`Iterable` receivers). Each is a top-level `void p_<id>()`
  that does nothing in the release; the patch replaces its body with the call on one runtime class, in one form
  (`static` typed receiver, `dynamic` receiver, and a tear-off of each).
- Patch: one Route B patch carrying all probe bodies. The runner marks each probe with a file before calling it. An abort
  kills the process, and the next launch records that probe as `ABORTS` and goes on, so a sweep takes one launch per
  aborting probe (143 aborting probes here, about 150 launches in all).
- Verdicts per probe: RESOLVES (ran, or threw an error that is not a NoSuchMethodError naming the member), THROWS
  (NoSuchMethodError naming the member: no dispatch entry in the release), ABORTS (process died), NOT-RUN.
  Per key: SAFE (every probe resolves), CRASH (any probe aborts), THROWS (no crash, some probe throws),
  PARTIAL (no crash, no throw, some probes never ran). `tables.py` and `compare.py` do the joining; `merge_raw.py` merges
  the result lines of the sweep logs.
- Device: iPhone 7 (iPhone9,1), iOS 15.8.8. The app was only ever upgrade-installed over the same bundle id.

## Totals

| probe verdict | count |
| --- | --- |
| RESOLVES | 583 |
| THROWS (NoSuchMethodError) | 721 |
| UNATTRIBUTED (NoSuchMethodError naming another member) | 4 |
| ABORTS | 153 (145 in the call, 8 while the patch was activated) |
| NOT-RUN | 53 |

| key verdict | keys |
| --- | --- |
| SAFE | 138 |
| THROWS | 224 |
| CRASH | 51 (10 typed members, 41 dynamic selectors) |
| PARTIAL | 7 (all dynamic selectors) |

## Crashing members (typed receiver)

| key | where |
| --- | --- |
| `dart:core#Map#addAll` | const map aborts on the device; literal, unmodifiable and json aborted on the host and were not tried on the device |
| `dart:core#Set#remove` | literal set: segfault on the host, not tried on the device |
| `dart:core#String#get:isNotEmpty` | one-byte and two-byte strings: aborted on the host, not tried on the device |
| `dart:core#int#get:isEven` | smi and mint: aborted on the host, not tried on the device |
| `dart:core#String#endsWith` | aborts on one-byte and two-byte strings |
| `dart:core#List#sort` | aborts on filled-fixed, const and unmodifiable lists |
| `dart:core#Iterable#contains` | aborts on filled-fixed, const and unmodifiable lists |
| `dart:core#Iterable#every` | aborts on a list |
| `dart:async#StreamSubscription#cancel`, `#tearoff:cancel` | the process aborts while the patch is activated, before main (all four forms, broadcast and controller subscriptions; a from-iterable subscription does not abort: a NoSuchMethodError naming another member) |

Crashing dynamic selectors (a call by name on a `dynamic` receiver): `% * + - < > [] []= add addAll cancel catchError
contains containsKey forEach get:current get:entries get:first get:inMicroseconds get:isClosed get:isEmpty get:isEven
get:isNaN get:isNotEmpty get:iterator get:keys get:last get:length get:reversed get:stackTrace get:stream get:values
remove removeLast sort tearoff:cancel then timeout toDouble whenComplete ~/`. Which runtime class, form and member:
`result/members.tsv`, column `crashing_runtime_classes_and_forms`.

The crash depends on the runtime class, not the declared type: `Map.addAll` aborts on const, literal, unmodifiable and
JSON maps on the host (the const map on the device). `Iterable.contains` and `List.sort` abort on const, unmodifiable and filled-fixed lists, and `Iterable.every` on a plain list.

## Not a crash, but unusable

224 keys (721 probes) throw a NoSuchMethodError naming the member: a typed call, or a `dynamic` call, of a member the
release has no dispatch entry for (for example `String.length`, `List.insert`, `Iterable.map`, `Stream.listen`,
`DateTime.difference`, `num.abs`). A patch calling one gets a Dart exception at that call, not a dead process. The key
list is in `result/comparison.md`.

## Comparison with #209

See `result/comparison.md`. In short: #209 accepts 75 keys; the device agrees on all but one. #209 refuses
64 keys the device shows safe, 7 more it shows crash-free but unmeasured, and 224 that throw instead of crash.

## Caveats

- A probe that was not run: 18 aborted on the host matrix and were not tried on the device (`excluded_ids.tsv`,
  `host-abort`), and the dynamic forms of the selectors `& addAll clamp putIfAbsent moveNext` (36 probes). A patch that
  calls a member by name makes the CLI keep every framework member of that name, and the CLI refuses the whole patch
  ("changed members cannot be carried"): `bisect_dynamic.py` found these five with dry-run patches
  (`result/dynamic_culprits.txt`). They are `PARTIAL` or `CRASH` by their other probes only.
- Eight `StreamSubscription.cancel` probes (all forms, broadcast and controller) abort the process during activation.
  Activation applies targets in name order and logs after each, so the first target missing from the log names the abort;
  the sweep was re-patched without it and run again until none was left (`excluded_ids.tsv`, `device-activation-abort`).
  Each re-patch moved the abort to the next target; the other 12 targets after them (from-iterable, `Timer`) activated and ran.
- The updater marks a patch bad after two boots that die before a successful-launch report, and keeps that list per
  release version across a new app id. The sweep therefore starts 6 s after `runApp` (`Timer` in the release's `main`;
  the CLI refuses to patch `main`), and the release version was raised to `1.0.0+63` to reset that list.
- Results come from several logs (`merge_raw.py`): the first 14 `future_then` probes ran on an earlier install of the same
  probe app (same bundle id, same Documents folder, same probe bodies) before the release was rebuilt. The result lines of
  that earlier install are the only copy: the device's own results.tsv is not pulled.
- A SAFE verdict is for the runtime classes the probes build, not every class. A RESOLVES that threw the member's own error
  (`Unsupported operation`, 19 probes) counts as resolved.
- Host-only receivers (Iterable from `where`/`map`/`keys`/`values`, Stream from a controller) the device release cannot
  build without calling a probed member are only in the host matrix.
