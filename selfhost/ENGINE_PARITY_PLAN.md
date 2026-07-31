<!-- cspell:words vmcode aot xcframework gclient bidiff dartsdk prebuilts resign resigned iplr upstreamable dylib devicectl bootable dynmod devirtualization vtables jewgo -->

# Plan — engine parity on iOS and Android, without upstream

Written 2026-07-30, replacing the "ask Shorebird for access" framing in
[`FORK_REBUILD.md`](FORK_REBUILD.md). That framing rested on two premises this
plan disproves with measurements, and on a dependency we do not want even if it
were offered.

## What "done" means

Three capabilities, in dependency order:

1. **An engine change we write ships to iOS and Android.** Today Route B (patch
   assets at the engine level) is proven on Android and has never been compiled
   for iOS.
2. **Code push keeps working on our own engine, on both platforms.** This is the
   hard one, and it is the only place the private Dart VM fork actually bites.
3. **We can add the *next* engine feature without asking anyone.** Which means a
   build that is repeatable, publishable, and testable on device — not a
   once-off that took a week to assemble.

Capability 3 is the real deliverable. 1 and 2 are the proof that we have it.

## Why not just ask for fork access

It would unblock capability 2 for free, and it is still the wrong trade:

- **iOS code push already works** in this fork on Shorebird's *prebuilt* engine —
  the Apple patchers, `aot_tools`, their `gen_snapshot` and `analyze_snapshot`
  are public artifacts the CLI downloads and our mirror caches, device-verified
  on a physical iPhone (see [`IOS_ONDEVICE.md`](IOS_ONDEVICE.md)). Nothing we
  ship today is blocked.
- The *only* thing gated is running **our own modified engine** on iOS.
- Accepting a private, revocable dependency to get there re-creates, one layer
  down, exactly the dependency this fork exists to remove. Access is not
  independence.

## The one constraint that shapes everything

**iOS cannot execute downloaded machine code.** Code signing and W^X mean a
patch cannot carry executable pages, which is why Shorebird's iOS path links
against the original snapshot's instructions and *interprets* the remainder,
while Android simply ships real machine code.

Everything hard below follows from that single sentence. Everything that is
*not* code execution — assets, delivery, storage, lifecycle, reporting —
carries to iOS almost for free.

## Findings this plan is built on (measured 2026-07-30)

Load-bearing, and all verifiable by re-running the commands in
[`HANDOFF.md`](HANDOFF.md):

| Finding | Evidence | Consequence |
|---|---|---|
| The engine half of iOS patching is **entirely public** | `runtime/shorebird/patch_cache.cc` calls only `Dart_LoadELF`/`Dart_UnloadELF` (vanilla) plus `Dart_SnapshotDataSize`/`Dart_SnapshotInstrSize` — the two accessors [`engine/dart-fork/`](engine/dart-fork) already reproduces | No VM fork needed to *load* a patch on iOS |
| The KBC interpreter is **upstream's, not Shorebird's** | Vanilla Flutter and Shorebird both vend Dart 3.12.2; both `gen_snapshot`s carry `DRT_ResumeInterpreter`, `InvokeDartCodeFromBytecode`, `[Bytecode Stub] …`. Only Shorebird's carries `shorebird` strings | The 4,600-line interpreter is not ours to write |
| The interpreter **ships in stock release iOS** | Vanilla `ios-release/Flutter.xcframework/ios-arm64` (8.8 MB, device slice) contains those symbols and `Internal_loadDynamicModule` | JIT-less execution is not debug-only |
| …but dynamic-module loading is **gated off** | Same binary contains `"Loading of dynamic modules is not supported."`; the gate is `--dart-dynamic-modules` (`tools/gn:685`), default false | The gate is ours to flip, since we build the engine |
| What they forked is the **linker**, and its contract is named | `gen_snapshot` symbol diff exposes `--base_ct_link_data`, `--patch_{ct,op}_link_data`, `--base_{dt,ft,op}_link_data`, plus `ClassTable::AllocateIndex`, an extra `InstructionsTable` param on `Deserializer`, an extra param on `ObjectPoolBuilder::FindObject`. Maps 1:1 onto `aot-tools.dill`'s `linker/debug/{class_table,dispatch_table,field_table,object_pool}.dart` | The mechanism is legible: pin the patch snapshot's identifier layout to the base's, reuse identical code, interpret the rest |
| **The Route B resolver is already iOS-ready** | `FlutterDartProject.mm:374` calls `RunConfiguration::InferFromSettings`, where the resolver is `PushFront`ed ahead of the bundled resolvers (`run_configuration.cc:35`) | Phase 1 + 2 need *no new resolver code* |

Everything above came from shipped binaries' symbol tables and `--help` output —
ordinary interoperability inspection. Note the deliberate line: `aot-tools.dill`
is on disk and its library structure is readable, but reimplementing from
decompiled private kernel is how you build a derivative work. This plan does not
depend on reading it, and should not start to.

## Phase 0 — Build host and iOS test rig (blocking)

Nothing below can start without this, and **neither current machine qualifies.**

| Requirement | Status |
|---|---|
| macOS + Xcode to build an iOS engine at all | Xcode 26.6 present on the Mac ✅ |
| ~200 GB free for a gclient checkout plus `out/{ios_release_arm64,host_release,host_debug}` | **This Mac has 24.4 GB free** ❌ |
| The Linux box (`/data`, 410 GB free) | Cannot build for Apple platforms ❌ |
| A **wired** iPhone (per project rule: never wireless) | Two iPhones known, both `unavailable` ❌ |
| A development provisioning profile listing that device's UDID | **0 profiles installed** ❌ |

Recommendation: **an external NVMe SSD (2 TB)** as the build volume. It is the
cheapest option, keeps everything local and private, and survives the Mac's disk
staying full. A cloud Mac (AWS EC2 `mac2`, MacStadium) is the fallback but costs
per hour and adds artifact-shuttling. GitHub-hosted macOS runners are **not**
viable — their free disk is far below an engine checkout.

Signing itself needs no new work: `tool/ios_ship.sh` and `tool/ios_resign.sh`
already cover the three modes, and a dev cert exists (`Apple Development: …`).
Only the profile is missing.

**Gate:** `gclient sync` completes on the build volume and `ninja` produces
`out/ios_release_arm64` from our Dart fork. If our 57-line fork does not build
for an Apple target, that is a Phase 0 failure and is discovered cheaply.

## Phase 1 — Our engine on an iPhone, release only

Extend the rig from one Android cell to Apple:

- `build.sh` grows an `ios-arm64` cell. Today it hard-fails anything but
  `android-arm64` and is Linux-only by assertion — deliberately, but it now has
  to learn a second host.
- **macOS host toolchain**, which is new: our `gen_snapshot` today is linux-x64
  only, which is why releases must run on Linux. iOS releases must run on the
  Mac, so `out/host_release` has to be built there too. The welded-format
  invariant applies unchanged — the whole host toolchain must come from our tree.
- `overlay_publish.sh` learns the Apple artifact set (`Flutter.xcframework`,
  `ios-release/artifacts.zip`, the host `gen_snapshot`). It already has known
  gaps on the Android side (it omits `linux-x64/artifacts.zip` and
  `maven-metadata.xml`); fix those in the same pass rather than adding a second
  set of gaps.
- Release the probe app against our engine hash, resign, install with
  `devicectl`, launch.

**Gate:** a marker present only in our engine source prints on the iPhone —
the same standard the Android engine had to meet.

**State plainly:** at the end of Phase 1 an app on our iOS engine has **no code
push**. That is the honest cost of leaving their prebuilt engine, and it is why
Phase 5 exists. Do not ship this configuration to anyone.

## Phase 2 — Asset-only patches: Route B on iOS with no linker

The insight that makes iOS worth doing before the linker: **an asset-only patch
contains no code, so nothing needs to be linked or interpreted.** It is pure
data delivery, and every layer it touches is ours and public.

Work:

- **Rust updater** (`vendor/updater`, layer 4) learns a patch that carries no
  code payload: download, validate, stage, and report it as bootable, with
  `NextBootPatchPath` pointing at a directory holding assets and no `.vmcode`.
  The exact shape must be confirmed against `cache/lifecycle.rs` and
  `updater.rs` before any C++ is written — a wrong guess here costs a rebuild.
- **Engine C++**: when the active patch has no code, keep the base snapshot but
  still set `settings.shorebird_patch_assets_path`. On iOS today
  `ConfigureShorebird` inserts the patch path at the front of
  `application_library_paths` and `TryLoadFromPatch` keys off `.vmcode` in the
  name — an absent code payload must fall through to the base cleanly rather
  than `FML_LOG(FATAL)`.
- **CLI**: publish an assets-only patch (`--assets` with no code delta). The
  server needs **nothing** — `arch` is free-form and already carries `assets`.
- **Rollback must cover it.** A bad font or a broken shader can hang or crash an
  app just as thoroughly as bad code, so boot-crash detection and revert have to
  treat an asset-only patch exactly like any other.

**Gate:** on an iPhone running our engine, a pubspec-declared font and a
declared shader change from the patch overlay — the two cases Route A
structurally cannot reach — with rollback proven.

This is the first engine improvement delivered on both platforms, and it is
something Shorebird's hosted product does not do. Note the shader trap from
Android: anything under `shaders:` is compiled to `iplr` at build time, so the
replacement must also be declared under `shaders:`.

## Phase 3 — Measure the linker gap exactly ◐ contract confirmed, size still open

Two results from 2026-07-30, one positive and one negative.

**The contract is confirmed, twice, independently.** A version-matched diff
(Shorebird's `darwin-x64-release/gen_snapshot_x64` against vanilla Flutter
**3.44.8**'s `gen_snapshot`, engine `0cd61071…` — same Flutter, same Dart 3.12.2)
reproduces exactly the six options the earlier 3.38.5 comparison found:
`--base_{ct,dt,ft,op}_link_data` and `--patch_{ct,op}_link_data`. So "pin the
patch snapshot's class, dispatch, field and object-pool layout to the base's" is
solid, not an artifact of comparing mismatched versions.

**Symbol counting cannot size the fork.** The same diff reports 2,976
Shorebird-only and 11,406 vanilla-only symbols — and vanilla ships 55,985 symbols
against Shorebird's 43,198. That gap is build configuration (two independently
configured release builds), not fork content, and it swamps the signal. Only 71
of the 2,976 even mention the fork's vocabulary, and some of those (`UnlinkedCall`
vtables) are vanilla Dart concepts caught by a loose grep.

**So sizing still requires building vanilla ourselves with matching config** —
Phase 3 as originally written, below. That is now unblocked: the build box is
reachable again (SSH is on a non-standard port as user `jewgo`; see
[`HANDOFF.md`](HANDOFF.md)), `/data` has 380 GB free, and `src/dart-sdk` is
already checked out.

One incidental finding worth keeping: **Shorebird's `linux-x64/gen_snapshot` is
stripped and contains no `shorebird` strings at all.** The fork's snapshot-linking
machinery ships only in the macOS/iOS toolchain, which is consistent with
`useLinker` appearing only in the Apple patchers — Android needs none of it.

### Phase 3 as originally written

Cheap, and it converts "unknown size" into a number the way the Android answer
became "57 lines".

Build `gen_snapshot` from our own `dart-fork` tree at `d684a576` (Dart 3.12.2 —
the same revision Shorebird vends) and symbol-diff it against theirs. Today's
counts (367 total / 88 in `dart::`) are contaminated by comparing Flutter 3.44.8
against 3.38.5; a version-matched diff removes that noise.

**Deliverable:** an enumerated list of the fork's additions — which *is* the
specification for Phase 5, written by them and read by us without touching their
source.

## Phase 4 — The crux experiments ✅ ANSWERED 2026-07-30: no

**A dynamic module cannot replace code the AOT snapshot already contains.**
Harness, evidence and the three traps: [`engine/dynmod/`](engine/dynmod).
`loadDynamicModule` runs a module's entry point and returns its result; the only
override a module can express is a subclass, which cannot change what an
already-constructed instance returns; and `dyn-module:can-be-overridden` is a
devirtualization barrier that keeps a dispatch point open rather than redirecting
one. It is an extension mechanism, not a patch mechanism.

**So Phase 5 is the pinned-layout route**, and the upstreamable variant is off
the table. The original experiment list is kept below for the record.

### The original crux experiments (kill gates, days not weeks)

Run these before committing to Phase 5, in this order, because each can end the
question cheaply:

1. **Does `--dart-dynamic-modules` build in our tree?** Flip it on, build, run
   any dynamic module. If it fails here, the upstream route is dead for a day's
   cost.
2. **Does the interpreter survive a release AOT build of *our* engine?** Stock
   Flutter's does (measured). Ours must too.
3. **Can a dynamic module replace a function the AOT snapshot already
   contains?** Patching is overriding, not appending. **This is where the idea
   most plausibly dies**, and it decides the whole route. Answer it before
   building anything on top.

**Decision:** if (3) succeeds, Phase 5 rides upstream's mechanism and is
plausibly upstreamable. If it fails, Phase 5 is the pinned-layout work — bigger,
permanently coupled to Dart's snapshot format, and ours to maintain forever.

*(3) failed. Experiments 1 and 2 were not needed: the question was settled at the
language-semantics level rather than the build-configuration level, which is why
it cost hours instead of the budgeted days.*

## Phase 5 — Code patches on our own iOS engine

Either route, the shape is the same three pieces:

- **VM side** (our Dart fork): pinned class/dispatch/field/object-pool layout so
  a patch snapshot is ABI-compatible with the base — or, on the upstream route,
  whatever hooks let a dynamic module override resolved code. Plus the two small
  fork symbols the engine already calls and vanilla lacks:
  `Shorebird_ReadLinkHeader` (a header offset — trivial, and we define the
  format) and `Shorebird_SetBaseSnapshots`.
- **Host side** (new Dart package, ours): diff base and patch snapshots, decide
  what is reusable, emit the `.vmcode`. This is what `aot_tools` does. Write it
  from the Phase 3 spec and first principles.
- **CLI**: an Apple patcher path that calls ours instead of `aot_tools`, behind
  the existing `useLinker` seam.

**Gate:** a patch changes behavior on an iPhone running our engine, reports a
sane link percentage, and rolls back cleanly.

Estimate, and it is an estimate: **weeks** for the host side once the VM
cooperates, **months** for the pinned-layout VM work if Phase 4 sends us there.
Real compiler work, but bounded and specified — not research.

## Phase 6 — The part that makes capability 3 true

Without this, every future engine feature costs what the first one cost.

- **Build determinism is the biggest tax we pay.** Rebuilding identical source
  today produces a different `libflutter.so`, so a change cannot be validated by
  diffing against a known-good artifact and *every* change needs its own device
  test. This is the single highest-leverage item in this plan for iteration
  speed, and it is independent of iOS.

  **First probe done, 2026-07-30, and it narrows the hunt a lot.** Two clean
  from-scratch builds of `gen_snapshot` (`out/host_release`, `rm -rf` between
  them) are **byte-identical** — sha256 `71c2c45b…` both times
  (`/data/shorebird-engine/gs_determinism.sh`, ~5 min per build on the box). So
  the toolchain, GN and ninja are *not* the problem, and neither is C++
  compilation in general. Whatever moves in `libflutter.so` is specific to that
  link.

  **Second probe done, and it eliminates the other obvious suspect.** The Rust
  updater — compiled into `libflutter.so` by `build_rust_updater.py` driving
  cargo — builds **byte-identically** for the real `aarch64-linux-android`
  target across two clean builds, sha256 `e93b7bdb…` (~36 s each,
  `/data/shorebird-engine/rust_determinism.sh`). Cargo's parallel-codegen
  non-determinism was never in play: the crate already sets `codegen-units = 1`
  and `lto = true` in `[profile.release]`.

  **And LTO by itself does not explain it either.** `--lto` defaults to `True`
  in `flutter/tools/gn`, and `use_thin_lto = false`, so both builds above were
  full-LTO — including the `gen_snapshot` that came out reproducible.

  So the two cheap explanations are dead, and what remains is specific to the
  `libflutter.so` link at its full scale. Next probe, staged so the expensive
  part is paid once rather than twice:

  1. Build the `android-arm64` cell once and keep `libflutter.so`.
  2. Delete **only the final link output** and re-run ninja, relinking from the
     same object files. A differing `.so` means the *link* is non-deterministic.
  3. Only if the relink is stable, delete the objects and rebuild, which tests
     compilation and costs a second full build.

  That ordering matters: the observed signature (identical size, unchanged
  `.data.rel.ro`, differing `.text` *and* `.rodata`) is consistent with either,
  and step 2 is nearly free once step 1 has run.
- **CI that builds every cell** — `android-arm64`, `ios-arm64`, and both host
  toolchains — so an engine change is not a week of manual assembly.
- **Contract tests on device**, one per engine behavior we depend on: asset
  overlay wins, patch directory layout, fonts, shaders, rollback. Run per build.
  These are what let someone change engine C++ without re-deriving the traps in
  [`HANDOFF.md`](HANDOFF.md).
- **Keep the shared-code discipline.** Shorebird's own +3,053 engine lines are
  ~1,675 shared and a few dozen per embedder. Anything we add in
  `shell/common/shorebird/` or `runtime/shorebird/` carries to every platform by
  construction; anything we add in an embedder does not.

## What we are deliberately not doing

- **Not** reimplementing an interpreter. Upstream ships one.
- **Not** reading `aot-tools.dill` to reproduce it. See the note above.
- **Not** touching `main` or the supported pin. Every phase stays behind
  `experimental_hashes.map` and `independence.engine_from_source: false` until
  something is device-proven, exactly as the Android work did.
- **Not** shipping Phase 1's configuration (our iOS engine, no code push) to
  anyone.

## Honest failure modes

| Risk | Where it bites | Mitigation |
|---|---|---|
| Our 57-line Dart fork does not build for Apple targets | Phase 0 | Found on day one, not month three |
| A dynamic module cannot override existing AOT code | Phase 4.3 | Kill gate before any real investment; fall back to pinned layout |
| Pinned-layout work exceeds appetite | Phase 5 | Phases 1–2 already delivered iOS engine assets; stop there and keep their prebuilt engine for code patches |
| Apple rejects interpreted downloaded code | Phase 5 ship | Shorebird ships exactly this in App Store apps today — an operational risk, not a technical one |
| Non-determinism never yields | Phase 6 | Contract tests on device substitute for diffing, at higher cost per change |

## Suggested order of attack

Phase 6's determinism work and Phase 3's measurement are **independent of the
iOS hardware question** and can start immediately on the Linux box. Phase 0 is a
purchase decision. Do those three in parallel; they are cheap, and they inform
everything that follows.
