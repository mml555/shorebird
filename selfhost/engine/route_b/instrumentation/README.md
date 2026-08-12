# Route B post-attach instrumentation — durable copy

The diagnostic that answers "what happened to the target `Function` after
`AttachBytecode` returned". Written 2026-08-12, **compiles**, not yet run on
device.

## Why this directory exists instead of a `0006-*.patch`

Constraint 6 of the handoff says to export this as `0006` before treating the
engine build as reproducible. Attempting that surfaced a problem that predates
this change:

**`0002-seam6-premain-activation.patch` and `0003-4b-lifecycle-delivery.patch`
do not apply to this checkout's `shorebird.cc` base.** Both fail
(`patch does not apply` at `:138` and `:142`), so the patch series cannot be
replayed onto the tree it is supposed to describe. Independently,
`0003` contains **zero** occurrences of `RouteBReport` — so the diagnostic
machinery behind every piece of Route B device evidence was already outside the
patch series.

Producing a `0006` on top of a series that does not apply would manufacture the
appearance of reproducibility without the substance. So the work is preserved
two ways, and the re-baselining is left as an explicit decision:

| file | what it is |
|---|---|
| `dart_route_b_trace.h` | the new header, complete and self-contained |
| `lib_object.cc.snapshot` | full current `runtime/lib/object.cc` |
| `shorebird.cc.snapshot` | full current `flutter/shell/common/shorebird/shorebird.cc` |
| `dart-lib-object.fulldiff.patch` | that file's whole diff vs the Dart tree's HEAD |
| `flutter-shorebird.fulldiff.patch` | that file's whole diff vs the engine tree's HEAD |

The two `fulldiff` patches are against **upstream HEAD**, so each carries all
Route B work in its file — the killgate activation native, the seam-6 hook, the
4b lifecycle reporting AND this trace. They are complete and self-contained; they
are NOT incremental and will conflict with `0002`/`0003`/`killgate 0001` if
applied after them.

**The decision the next session owes this:** either re-baseline the whole series
against the current checkout, or declare the `fulldiff` pair authoritative for
these two files and shrink the older patches accordingly. Either is defensible.
Leaving both in place, each half-true, is not.

## What the instrumentation does

`runtime/lib/object.cc`
- the existing four-argument `Dart_RouteBActivatePatch` becomes a wrapper that
  delegates with a null trace, so its signature and behaviour are untouched;
- `Dart_RouteBActivatePatchTraced` adds the `Dart_RouteBTrace*` out-parameter;
- the body samples state immediately before `RouteBSaveOriginalCode` and
  immediately after `target.AttachBytecode(bc)`, both inside the existing
  `SafepointWriteRwLocker` scope so nothing can run in between.

Nothing was added to `runtime/vm/object.{cc,h}` or `runtime/include/dart_api.h`.
Those files ARE already modified in this tree by earlier Route B patches, and the
published snapshot hash reflects that — the rule is **no further churn**, because
another change there moves `SNAPSHOT_HASH` away from the shipped
`App.framework` and it would stop loading. Verified: `git status` on the Dart
tree shows no new edits to either file from this work.

`flutter/shell/common/shorebird/shorebird.cc`
- `RouteBTraceWrite` appends to `<artifact>.routeb.trace` — a SIBLING of the
  existing `.routeb`, never the same file, because `.routeb` carries byte-for-byte
  committed evidence and absence semantics other probes read;
- `FormatRouteBTrace` is pure, so it is host-unit-testable with a hand-filled
  struct;
- the record is written for **every** target, success included. The success path
  `continue`s before any per-target report, which is exactly how `applied 1/1`
  became the entire story for four device runs.

## Verified so far

- `gen_snapshot` links against the VM change (host, 298/298).
- `obj/flutter/shell/common/shorebird/shorebird.shorebird.o` compiles (1815/1815).
- Neither snapshot-hash file gained an edit.

Not yet done: iOS engine build, cell mint, release 25, device run.

## Rig notes that cost time

- `depot_tools/ninja` is a Python shim that dies on Python 3.13
  (`ModuleNotFoundError: pipes`). Use `python3.12` to run
  `depot_tools/ninja.py`.
- Several build actions shell out to `vpython3`, so `depot_tools` must be on
  `PATH` as well. Without it the failure is `vpython3: command not found` from an
  unrelated-looking Skia or flatbuffers action.

  ```
  export PATH="/opt/homebrew/opt/python@3.12/libexec/bin:$SRC/flutter/third_party/depot_tools:$PATH"
  python3.12 $SRC/flutter/third_party/depot_tools/ninja.py -C out/host_release_arm64 -j 8 <target>
  ```
