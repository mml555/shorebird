<!-- cspell:words prebuilts dartsdk vmcode embedder embedders upstreamable crashpad minidumps symbolicate -->

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

### Phase 4 — Crash reporting + symbolication ✅ do this first

Layers 1 + 2, optionally 3. **Not blocked at all**, and 100% shared between
platforms because none of it is platform code.

- Retain native + Dart symbols keyed by `(app, release, patch, arch)` — the CLI
  already produces them via `--split-debug-info`.
- Accept stack traces / minidumps on the control plane, symbolicate server-side,
  surface in the console.
- Dart-level capture (`FlutterError.onError`, `PlatformDispatcher.instance.onError`)
  is pure framework/app code — no engine work.

Only a native crashpad-style collector would need layer 5, and that is optional.
**Carryover to iOS: 100%.** Best value-per-effort on the list today.

### Phase 1 — Assets in patches ✅ reachable on both platforms

Assets are **data, not code**, so this never needs the linker or the interpreter.
Two routes:

**Route A — framework/Dart (layers 2 + 3). Unblocked today, both platforms.**
Ship an `AssetBundle` that prefers files from the active patch directory and falls
back to `rootBundle`. The CLI packages changed assets into the patch. The updater's
on-disk layout is public and vendored — `patches/`, `pointers.json`,
`patches_state.json` under the embedder-provided storage dir, downloads under
`<code_cache_dir>/downloads` ([`config.rs:138`](../vendor/updater/library/src/config.rs),
[`updater_state.rs:34`](../vendor/updater/library/src/cache/updater_state.rs)).

The one unknown to spike: how the app learns that directory. The updater is handed
`app_storage_dir` / `code_cache_dir` by the embedder; we need to confirm those map
to what `path_provider` returns on each platform. Note `shorebird_code_push` (the
Dart package apps depend on) is a *separate upstream repo*, not in this one — so
exposing a path officially means forking it or shipping our own shim.

**Route B — engine (layer 5).** Push a higher-priority `AssetResolver` into the
common `flutter::AssetManager`. Cleaner (no app opt-in, works for
`ImmutableBuffer.fromAsset` and image resolution) but needs an engine build, so:
Android now, iOS fork-gated. Because `AssetManager` is common code, **carryover is
near total** once an iOS build is possible.

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

| Phase | Blocked? | Android→iOS carryover |
|---|---|---|
| 4 — crash + symbolication | ✅ no | 100% (no platform code) |
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
