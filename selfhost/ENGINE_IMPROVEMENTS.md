<!-- cspell:words dartsdk prebuilts aot vmcode upstreamable -->

# Engine improvements — what this branch is

Work toward modifying the engine and runtime ourselves, kept **off `main`** and
deliberately inert by default.

Picking this up mid-stream? [`HANDOFF.md`](HANDOFF.md) has the per-track next
steps, the invariants that cost real debugging time, and the live environment
state.

## Read this first: nothing here changes what you ship

| | |
|---|---|
| Supported pin in [`compatibility.yaml`](compatibility.yaml) | **byte-identical to `main`** — CLI, flutter, engine, updater revisions all unchanged |
| `independence.engine_from_source` | still `false` — releases and patches use **Shorebird's prebuilt engine** |
| The CDN mirror | checked in as a **pure passthrough** cache; `experimental_hashes.map` has no active entries |
| Our engine | reachable only if you publish it locally *and* point a build at its hash — two deliberate acts |

The only behavioral change to the default path is a **bug fix**: the CDN mirror
previously resolved Google Cloud Storage through a literal upstream hostname
(including AAAA records), so any host without IPv6 egress got intermittent
`502`s. That would bite mirror users regardless of engine work.

Everything else is additive: docs, tooling, a server endpoint, and 20 files
restored to the vendored source snapshot.

## What is proven

An engine built entirely from source ran the full code-push cycle on a physical
device (CPH2551, Android 16, arm64):

```
release 1.0.2+3 -> install -> boot -> patch download -> patch apply
  -> patched code runs -> rollback -> revert
```

`libflutter.so` in the APK was sha256 `0da873a2…`, identical to our build. The
patch reconstructed to `output_written=3146640b`, exactly `libapp.so`'s size. Our
marker printed from code absent from the installed APK. Full evidence:
[`ENGINE_BUILD.md`](ENGINE_BUILD.md) and `experimental:` in
[`compatibility.yaml`](compatibility.yaml).

## The finding that reframed the project

Shorebird's engine and framework forks are public, and captured in
[`vendor/flutter`](../vendor/flutter). Their **Dart VM fork is private** — 404
anonymously and authenticated, and their own docs say "private currently". The
captured engine does not compile without it, because its hooks call two Dart APIs
vanilla does not define.

For **Android** that dependency turned out to be ~57 lines: their fork exists to
interpret patched code, which is the *iOS* mechanism, and Android patches carry
real machine code. So [`engine/dart-fork/`](engine/dart-fork) is vanilla Dart
3.12.2 plus two snapshot-size accessors and one public getter — reproducible from
the checked-in patch, and shaped to be upstreamable to `dart-lang/sdk`.

`pkg/aot_tools` — the AOT linker, used only by the Apple patchers — is the one
artifact we cannot reproduce. It is the concrete blocker for iOS on a self-built
engine, and nothing to do with Android.

## Hard-won constraints

Every one of these cost a debugging cycle, and none looks like its cause:

- **Snapshot and kernel formats are welded to the tree that produced them.**
  `VM_SNAPSHOT_FILES` includes two of the three files we patch, so a mixed
  artifact set can never boot. The whole host toolchain must be ours:
  `out/host_release` (`dart_sdk`, `flutter_patched_sdk_product`) and
  `out/host_debug` (`frontend_server`).
- **Releases must run on Linux**, since our `gen_snapshot` is linux-x64.
- **`--no-tree-shake-icons` is required.** `const_finder` is a kernel snapshot
  stamped with its builder's SDK hash. Shorebird hit this too — `font_subset` is
  commented out of their own `linux_build.sh` (flutter#164531).
- **Maven POMs cannot be proxy-rewritten** — Gradle validates the version inside
  the file, so every module must be materialized locally.
- **Recompile tool snapshots when the vended Dart changes.** Clearing an artifact
  cache swaps the Dart under an already-compiled snapshot and fails as
  "Wrong full snapshot version" *on the host*.
- **`PUBLIC_BASE_URL` is embedded absolutely** in upload/download URLs, so one URL
  must satisfy both the build host and the device.

## What is unblocked, and where

Almost nothing on the roadmap actually needs the engine —
see [`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) for the layer analysis and
the Android→iOS carryover argument.

| Work | Needs an engine build? |
|---|---|
| Crash reporting + symbolication | no — control plane + CLI |
| Assets in patches | no — CLI + server + a Dart package |
| In-process patch apply (hot restart) | yes — and now possible |
| iOS anything | yes, plus `aot_tools` and a Mac |

Asset support has both its server and CLI halves here: `POST /patches/assets`
serves a signed URL for a patch's asset bundle, and `shorebird patch --assets`
packages Android's `flutter_assets` out of the built AAB and uploads it tagged
`arch: assets`. Neither needed a schema change nor a new upload path, because
`arch` is free-form end to end. What remains is the app-side Dart that reads it,
and `assetsDirectory()` for the Apple patchers.

Debug symbols ride the same mechanism as `arch: symbols`, uploaded whenever a
patch build emits them (`--split-debug-info`). Together with a crash report's
`(app, release_version, patch_number, arch)` that is the join symbolication
needs, and the server now resolves it: `?symbolicate=true` on the crashes
endpoint returns `stack_symbolicated` beside the raw stack.

That symbolizer is pure Dart — `package:native_stack_traces`, the same one
`flutter symbolize` uses — which reads both the ELF and Mach-O forms of Dart's
debug info. So Android and Apple are symbolicated by one implementation inside
the Linux container, with no `atos` and no Mac worker.

## Reproducing the engine

```bash
selfhost/engine/dart-fork/create_dart_fork.sh          # vanilla Dart + our 57 lines
# .gclient at the checkout root, solution name "."; gclient sync --no-history
selfhost/engine/build.sh --cell android-arm64 --root <checkout>
#   plus out/host_release and out/host_debug — see the constraints above
selfhost/engine/overlay_publish.sh --hash <sha> --root <checkout>
```

Caveats worth knowing before you rely on it: the resulting APK is **arm64-only in
practice** (the arm/x64 slices pair our `libapp.so` with the stock engine), and
`overlay_publish.sh`'s host-toolchain path has not yet been exercised end-to-end —
those artifacts were published by hand for the verified run.
