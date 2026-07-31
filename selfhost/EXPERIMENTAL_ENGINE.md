<!-- cspell:words prebuilts dartsdk vmcode embedder embedders upstreamable crashpad minidumps symbolicate bidiff -->

# Experimental engine & runtime work — what's reachable, and what carries to iOS

Companion to [`ENGINE_BUILD.md`](ENGINE_BUILD.md), which establishes the blocker:
Shorebird's Dart VM fork is private, so their engine does not compile as-is. This
document answers the two practical questions that follow.

1. Which improvements can we actually build without that fork?
2. If we build something for Android, how much of it transfers to iOS?

The short answers: **more than expected**, and **most of it** — because the one
thing that genuinely does not transfer is the one thing we already decided not to
build (their AOT linker).

## The five layers, and who owns each

Every item on the roadmap lands in one or more of these. Knowing which decides
both feasibility and carryover.

| # | Layer | Where | Ours? | Needs an engine build? |
|---|---|---|---|---|
| 1 | Control plane | [`packages/code_push_server`](../packages/code_push_server) | ✅ entirely | No |
| 2 | CLI | [`packages/shorebird_cli`](../packages/shorebird_cli) | ✅ fork | No |
| 3 | Dart framework | `vendor/flutter/packages/flutter/**` | ✅ fork | **No** — framework Dart compiles into the *app* snapshot, not `libflutter.so` |
| 4 | Rust updater | [`vendor/updater`](../vendor/updater) (public) | ✅ vendored | **Yes** — linked into `libflutter.so` by the GN build |
| 5 | Engine C++ | `vendor/flutter/engine/src/flutter/**` (public) | ✅ vendored | **Yes** |

Layer 3 is the one people miss. A change to framework Dart ships in a normal
release *and is itself patchable*, with no engine rebuild and no fork access.

## Why Android work carries to iOS

Shorebird put their logic in **shared** code, which is measurable. Of their
+3,053 engine lines, the platform-specific glue is a rounding error:

| Shared across all platforms | Lines |
|---|---|
| `shell/common/shorebird/*` — `shorebird.cc`, `updater.cc/h`, `snapshots_data_handle`, build glue | ~1,300 |
| `runtime/shorebird/*` — `patch_cache`, `patch_mapping` | ~375 |

| Per-embedder glue (written once per platform) | Lines |
|---|---|
| Android `FlutterJNI.java` | 49 |
| iOS `FlutterDartProject.mm` | 33 |
| macOS `FlutterEngine.mm` | 52 |
| Linux `fl_shorebird.cc` | 56 |
| Windows `flutter_windows_engine.cc` | 147 |

So the engine-side carryover for anything built in `shell/common/shorebird/` or
`runtime/shorebird/` is **near total** — you add a few dozen lines of embedder
glue per platform. Layers 1, 2 and 4 are single implementations serving all
platforms already.

### The one hard boundary

Android and iOS diverge on exactly one thing: **how patched Dart code executes.**

- **Android** — a patch carries real machine code. The updater diffs the four
  snapshot blobs (`vm_data`, `iso_data`, `vm_instructions`, `iso_instructions`)
  and the VM loads the result. No linker, no interpreter.
- **iOS** — JIT is forbidden, so the host-side **linker** (`pkg/aot_tools`, inside
  the private fork) works out which functions can reuse the original AOT
  instructions (`linkPercentage`, typically ≥98%) and emits `.vmcode`; the VM
  interprets the rest. `useLinker` appears only in the Apple patchers.

Anything touching *code execution* has **zero** carryover and is fork-gated on
iOS. Anything else — data, delivery, lifecycle, storage, reporting, tooling —
carries over almost entirely.

## The roadmap, re-scored

### Phase 4 — Crash reporting + symbolication ✅ Android; ⚠️ iOS resolves nothing

Layers 1 + 2, optionally 3. Not blocked, and the *pipeline* is platform-neutral —
but see the correction below: on iOS the frames a patched app produces cannot be
resolved at all, for reasons no server change can address.

- ✅ Symbols retained keyed by `(app, release, patch, arch)`, from the
  `--split-debug-info` output the CLI already produces.
- ✅ Stack traces accepted on the control plane and symbolicated server-side.
- ✅ Dart-level capture (`FlutterError.onError`,
  `PlatformDispatcher.instance.onError`) in
  [`code_push_runtime`](../packages/code_push_runtime) — pure app code, no engine
  work, and it is what finally feeds the pipeline.
- ✅ Proven on a physical Android arm64 device: an obfuscated patch's crash
  resolved to the right function *and* the patch's own line number, picking the
  arm64 entry out of a three-ABI symbol zip.

The symbolication design deserves stating, because the obvious reading of it is
wrong. A Dart crash report is a *Dart* stack trace, and Dart's
`--split-debug-info` output is what `flutter symbolize` consumes through
`package:native_stack_traces`. That package is pure Dart and reads both ELF
(Android) and Mach-O (Apple), so one server-side implementation covers every
platform's *symbol format* with no native toolchain in the image — though on iOS
there turn out to be no addresses to look up, see below. `llvm-symbolizer` and
`atos` would only enter the picture for native C++/Objective-C frames — which
means only a crashpad-style native collector would need them, and that is
optional layer-5 work.

**Carryover to iOS: NOT 100%. Corrected 2026-07-31 by measurement.**

The claim was that one pure-Dart implementation symbolicates every platform,
since `package:native_stack_traces` reads Mach-O as well as ELF. That is true
about *formats* and false about *iOS in practice*, and the difference matters
because it cannot be fixed on the server.

Measured on a physical iPhone 7 (iOS 15.8.8) with a patch applied: the crash
arrives, is stored with the right `platform`/`arch`/`patch_number`, and
`?symbolicate=true` returns **null**. The trace header says why:

```
os: ios arch: arm64  comp: no  sim: yes
#00 abs 00000000000f9f2b <invalid Dart instruction address>
```

`comp: no` means the executing code is not AOT machine code and `sim: yes` means
the VM is interpreting it — which is exactly how iOS patches work, because iOS
forbids JIT. DWARF maps *AOT instruction addresses* to source lines. An
interpreted frame has no such address, so every frame reads
`<invalid Dart instruction address>` and there is nothing for the symbolizer to
resolve. The symbols were retained and located correctly; the addresses simply
do not exist.

**The sharper consequence:** this system only collects crashes *while a patch is
running* (a deliberate scoping decision — see `code_push_runtime`). On iOS those
are precisely the crashes that cannot be symbolicated. So iOS crash
symbolication is not "unimplemented", it is **structurally unavailable** for the
crashes we collect, and no amount of server work changes that.

What still carries to iOS: ingestion, retention, the join key, and the reporter
itself — all verified working on device. What does not: resolving a patched iOS
frame to a line number.

Ways it could be reached, none cheap: symbolicate against the interpreter's own
bytecode metadata rather than DWARF (needs the linker's mapping, i.e. the
private fork); or capture unpatched-release crashes too, which was explicitly
rejected as scope and would still need release symbols retained.

Android is unaffected and remains fully verified end to end.

### Phase 1 — Assets in patches ✅ reachable on both platforms

Assets are **data, not code**, so this never needs the linker or the interpreter.
Two routes:

**Route A — CLI + server + a Dart package (layers 1 + 2 + 3). Unblocked today,
both platforms.** Spiked 2026-07-29; the design changed as a result.

The obvious version — piggyback the assets inside the updater's patch file — is
the wrong one. The updater downloads exactly one artifact and applies it as a
bidiff, so teaching it about a second payload is a Rust change, which is linked
into `libflutter.so`, which puts it behind an engine build. That would make the
highest-value feature Android-only for no good reason.

Better: attach the asset bundle to the patch **on the control plane** and fetch it
from Dart.

What the spike established:

- The patch store is at
  `<app_storage_path>/shorebird_updater/<app_id>/patches/<N>/`
  (`cache/lifecycle.rs` `PATCHES_DIR` + `patch_dir(n)`, and `shorebird.cc:156-159`
  joining `{app_storage_path, shorebird_updater_dir_name, app_id}`). On Android
  `app_storage_path` is `getFilesDir()` — observed on device as
  `/data/user/0/<pkg>/files/shorebird_updater/…` — which `path_provider`'s
  `getApplicationSupportDirectory()` reaches. So Dart *can* find it. We just do not
  need to write into it.
- **The server already supports this with no schema change.** The `artifacts` table
  is generic (`owner_kind`, `owner_id`, `arch`, `platform`, `hash`, `size`,
  `storage_key`, `can_sideload`), so an asset bundle is simply another artifact
  owned by the patch, distinguished by its `arch` value. Device delivery reuses the
  existing signed-URL scheme in `signing.dart` (`"<token>.<exp>"`, tamper-proof).

So the shape is:

1. **CLI** — on patch, diff `flutter_assets`, zip the changes, upload as an extra
   patch artifact.
2. **Server** — one app-scoped endpoint returning a signed URL for a patch's asset
   artifact. No protocol change to the updater, which stays stock and ignores it.
3. **Dart package (ours)** — read the running patch number via
   `shorebird_code_push`, fetch and cache the bundle, expose an `AssetBundle` that
   prefers it and falls back to `rootBundle`. Built:
   [`packages/code_push_runtime`](../packages/code_push_runtime).

Trade-offs to design for: it is a second network fetch, not atomic with the code
patch — so cached assets must be keyed by patch number and ignored unless they
match the *running* patch, and discarded on rollback. In exchange it needs no
engine build, no updater change, and no fork access, and it ships on Android and
iOS simultaneously.

**Route B — engine (layer 5). ✅ PROVEN on device, 2026-07-30.** A resolver over
the patch's own asset directory is registered ahead of the APK's, so a patched
asset wins with no app opt-in at all. Verified on a physical Android arm64 device
with an app that does **not** depend on `code_push_runtime` and reads through
`rootBundle` (which `DefaultAssetBundle` cannot intercept): the value changed from
`APK-baked` to `ENGINE-OVERLAY-patch-2`.

Two things the implementation had to get right, both discovered the hard way:

- **Android never calls `RunConfiguration::InferFromSettings`.** It builds its
  `RunConfiguration` directly and calls `AddAssetResolver`, so the obvious hook
  (next to the existing `DirectoryAssetBundle` pushes) is dead code on Android.
  LTO dead-stripped the unused function, which is how it surfaced: the log string
  never reached `libflutter.so`.
- **The Android patch directory has no app-id component.** It is
  `<files>/shorebird_updater/patches/<N>/`, because the older
  `ConfigureShorebird` omits the app id that the desktop API inserts. Deriving the
  asset path from the running patch file's own directory is what makes this work
  on both.

**Fonts are proven too**, which is the part that actually justifies Route B: a
pubspec-declared family rendered in Courier New from the APK and in Comic Sans
from the patch overlay, with only the `.ttf` bytes swapped and
`FontManifest.json` left alone. Fonts are loaded by the engine from that manifest
and never pass through an app-side `AssetBundle`, so Route A cannot touch them at
any price.

**Shaders too**: a declared fragment shader rendered blue from the APK and red
from the overlay. One trap worth knowing — a shader listed under `shaders:` is
compiled to `iplr` at build time, so the replacement must ALSO be declared there.
Swapping a raw `.frag` shipped as a plain asset over a compiled one produces an
unparseable shader rather than a visible change.

So all three engine-only cases are proven: `rootBundle`, declared fonts, declared
shaders. iOS remains fork-gated for the *build*, though the resolver itself is
common code and iOS **does** go through `RunConfiguration::InferFromSettings`,
which is already wired.

Recommendation: Route A to prove product value on both platforms immediately;
Route B later as the "done properly" version.

### Phase 2 — In-process patch apply (hot restart) ⚠️ Android only

Layers 4 + 5, so Android via our vanilla-Dart VM; iOS fork-gated twice over (engine
build *and* code execution).

- The updater change (`readyToApply` vs `restartRequired`) and the engine
  isolate-restart logic both live in shared code → high carryover *as design and
  code*.
- But on iOS the thing being applied is `.vmcode` requiring the interpreter, so the
  feature cannot be finished there without the fork.
- Exception worth noting: an **asset-only** patch has no code to execute, so
  in-process reload of assets could work on iOS even under Route A.

### Phase 3 — Debug/profile iteration ⚠️ Android only, low carryover value

Mostly build configuration plus CLI. Prefer "profile mode that still loads
patches" over full JIT-debug. Conceptually portable; iOS needs a Mac *and* the fork.

### Phase 5 — In-production profiling ◐ split

Upload path and aggregation are layers 1 + 2 (**100% carryover**, unblocked).
Capture is engine-side: release mode has no VM service, so sampling needs layer 5 →
Android first. Start with capture-and-upload of what's already available in profile
mode.

### Phase 6 — Deeper VM linking/dispatch ⛔ re-scope

As originally written this *is* their private fork's territory — reimplementing the
linker is months and we've decided against it.

The version worth keeping: vanilla Dart 3.12.2 already ships a KBC interpreter
(`runtime/vm/interpreter.cc`, 4,567 lines) and bytecode reader (3,120 lines) behind
`DART_DYNAMIC_MODULES`, and this engine already exposes `--dart-dynamic-modules`
(`engine/src/flutter/tools/gn:685`) with Flutter CI builders for it. That is a
public substrate for JIT-less patch execution that did not exist when Shorebird
forked. Research-grade, but it is the *only* credible route to iOS code push on our
own engine — and if it worked it would be genuinely upstreamable.

## Summary

Status as of 2026-07-29 — see [`HANDOFF.md`](HANDOFF.md) for where to put your
hands next:

| Phase | Landed | Remaining |
|---|---|---|
| 4 — crash reporting | **complete on Android**: ingestion, retention, read-time symbolication, an app-side reporter, and a real obfuscated on-device crash resolved to `main.dart:36:3` against the patch's own symbols. On **iOS** ingestion/retention/reporting are device-verified, but symbolication of a patched frame is **structurally impossible** — the code is interpreted, so the trace carries no AOT addresses to resolve | nothing further on iOS without the interpreter's own mapping |
| 1 — assets | end to end: `--assets` packages `flutter_assets` on Android and Apple, server serves it, `code_push_runtime` reads it as an `AssetBundle` | — image published as `code-push-server:1.3.0` |
| 2 — hot restart | — | design, then updater status split + engine isolate reload |

| Phase | Blocked? | Android→iOS carryover |
|---|---|---|
| 4 — crash + symbolication | ✅ no | ingest/retain/report 100%; **resolving a patched iOS frame: not possible** (interpreted, no AOT addresses) |
| 1 — assets, Route A (Dart) | ✅ no | 100% (ships on both at once) |
| 1 — assets, Route B (engine) | Android yes / iOS fork-gated | near total (common `AssetManager`) |
| 2 — in-process apply | Android only | high for design/updater; zero for iOS code execution |
| 3 — debug/profile cell | Android only | conceptual only |
| 5 — profiling | upload no / capture Android | 100% upload, 0% capture |
| 6 — VM dispatch | re-scope onto upstream dynamic modules | this *is* the iOS route, if it pans out |

**Order that maximizes delivered value while the fork question is open:** Phase 4,
then Phase 1 Route A — both ship on Android *and* iOS with no fork access. Then
Phase 1 Route B and Phase 2 on Android over our own vanilla-Dart VM (~50 lines,
see [`ENGINE_BUILD.md`](ENGINE_BUILD.md)). Ask Shorebird for fork access in
parallel: it converts every "Android only" row above into "both platforms" without
changing any of the work.
