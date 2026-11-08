<!-- cspell:words dartsdk vmcode prebuilts upstreamable intptr nullptr embedders googlesource -->

# Our Dart VM fork — vanilla plus the minimum, on purpose

## Policy

**We build on vanilla Dart. We do not reproduce Shorebird's fork.**

Their fork is private ([`../../ENGINE_BUILD.md`](../../ENGINE_BUILD.md)), so parity
would mean reverse-engineering work we cannot read, to end up with a tree we then
have to rebase onto every Dart release forever. Instead this fork starts from the
exact Dart revision vanilla Flutter 3.44.8 pins and adds **only** what is
required to make the (public) Shorebird engine source compile.

Current delta: **3 files, 57 lines.**

| File | What |
|---|---|
| `runtime/include/dart_api.h` | Declares `Dart_SnapshotDataSize`, `Dart_SnapshotInstrSize` |
| `runtime/vm/dart_api_impl.cc` | Implements both over `Snapshot::length()` and the image header |
| `runtime/vm/image_snapshot.h` | Adds a public `Image::snapshot_size()` (`kHeaderSize` is private, so `object_size() + kHeaderSize` will not compile outside the class) |

Nothing else. No linker, no interpreter wiring, no VM behavior changes.

## Why this is enough for the work we're doing

Almost none of the roadmap actually needs Dart VM changes — see
[`../../EXPERIMENTAL_ENGINE.md`](../../EXPERIMENTAL_ENGINE.md):

| Feature | Layer it really lives in | VM work needed |
|---|---|---|
| Assets in patches | CLI + framework Dart (+ optional engine C++) | none |
| In-process patch apply (hot restart) | engine C++ + Rust updater | none |
| Crash reporting + symbolication | control plane + CLI | none |

The VM fork is a **compile shim**, not a project. It exists so the engine links at
all; the features are built in layers above it.

The one exception is iOS code push, which needs the AOT linker and interpreted
execution of patched code. That is the part we decided not to rebuild. If it ever
becomes a priority, the route is upstream Dart's own `DART_DYNAMIC_MODULES`
interpreter (`runtime/vm/interpreter.cc`, in vanilla since 2024, with a
`--dart-dynamic-modules` GN flag already wired in this engine) — not a
reimplementation of their 2022-era design.

## Keeping it small is the maintenance strategy

Rebasing 57 lines onto a new Dart revision is minutes of work. That is the whole
point: the cost of a Flutter/Dart bump stays near zero, and it does not grow.

If a change is about to be added here, first ask whether it belongs in a layer
above — the CLI, the framework, the engine's `shell/common/shorebird/`, the Rust
updater, or the control plane. Almost always it does.

Both accessors are also shaped to be **upstreamable**: they expose sizes the VM
already records in its own headers, with no behavior change. Offering them to
`dart-lang/sdk` would remove even this fork.

## Usage

```bash
# create (or refresh) the fork
selfhost/engine/dart-fork/create_dart_fork.sh --dest /data/shorebird-engine/src/dart-sdk

# it prints the sha; wire that into the engine checkout's .gclient
#   "custom_deps": {
#     "engine/src/flutter/third_party/dart": "file:///data/shorebird-engine/src/dart-sdk@<sha>",
#   },
# then: cd <engine checkout> && gclient sync --no-history
```

`file://` deliberately — the fork needs no hosting, no GitHub repo, and no
credentials, which also keeps it off a shared build host's account.

## On a Flutter/Dart bump

1. Read the new `dart_revision` from `flutter/flutter`'s `DEPS` at the matching
   release tag (Shorebird's `DEPS` will name their private fork instead; ignore it).
2. Update `VANILLA_DART_REV` in `create_dart_fork.sh`.
3. Re-run the script. If the patch no longer applies, re-derive it — the anchors
   are `Dart_IsKernel` in `dart_api.h` and `Image::object_size()` in
   `image_snapshot.h`.
4. Rebuild and re-verify on device before promoting anything.
