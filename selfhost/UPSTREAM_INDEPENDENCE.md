# Independence from upstream Shorebird — the whole inventory

The goal is not "our engine runs on iOS and macOS". It is that **nothing in the
build or run path requires Shorebird's infrastructure, accounts, or private code.**
This file is the single tracker for that. Written 2026-08-03.

Two kinds of dependency, and they are not equally bad:

- **Mirrored** — we hold a copy of their bytes. If they disappear tomorrow, existing
  builds keep working. But we cannot produce the artifact for a *new* engine
  revision without them. Survivable, not independent.
- **Built** — we produce the bytes from source we control. Independent.

Getting from mirrored to built is most of the remaining work.

## Inventory

| # | Dependency | What it is | How it goes away | Status |
|---|---|---|---|---|
| 1 | `api.shorebird.dev` | Control plane: apps, releases, patches, checks | `packages/code_push_server` | **Built** ✅ |
| 2 | `shorebirdtech/dart-sdk` (**private**) | Their Dart VM fork | Vanilla Dart `d684a576` + our 57-line snapshot-size shim ([`engine/dart-fork/`](engine/dart-fork)) | **Built** ✅ |
| 3 | `gs://shorebird-dart-sdk-prebuilt` (**private**) | Prebuilt Dart SDK for macOS; 401s for us | `custom_vars: {download_dart_sdk: False}` + `tools/gn --no-prebuilt-dart-sdk`, compiling Dart from source | **Built** ✅ 2026-08-03 |
| 4 | `shorebird_cli` | The CLI | Forked in-repo, version-pinned, `+selfhost.N` | **Built** ✅ (we track their releases by choice, not need) |
| 5 | `bundletool.jar` | Android bundle tool | Comes from `github.com/google/bundletool` — Google, never Shorebird | **N/A** ✅ |
| 6 | `patch` binary | The binary differ that produces patch payloads | `vendor/updater/patch` (`bidiff 1.0.0`) — **source is already ours**, just needs building and serving | **Ready to build** ⬜ |
| 7 | `aot-tools.dill` | **Their AOT linker.** Emits `.vmcode` + link percentage | Write our own — see [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) and [`AOT_LINKER_FEASIBILITY.md`](AOT_LINKER_FEASIBILITY.md). Referenced only by `ios_patcher.dart` / `ios_framework_patcher.dart`, so **iOS code push only** — an assets-only iOS patch no longer touches it (2026-08-03) | **In progress** ◐ |
| 8 | `download.shorebird.dev` engine artifacts | The per-engine-revision artifact set the CLI fetches | Build every artifact ourselves and serve from our own store | **Mirrored** ◐ |
| 9 | Artifact manifest in their GCS | `artifact_proxy` fetches it with a literal URL | Mirror it, or drop `artifact_proxy` and serve our own manifest | **Mirrored** ◐ |
| 10 | `shorebirdtech/flutter` git | Engine + framework source (public) | Vendored snapshot at [`vendor/flutter`](../vendor/flutter); a real git clone is still needed to *build* (gclient runs `rev-parse`/`describe`), so host our own mirror | **Mirrored** ◐ |

Items 1–5 are done. 6 is trivial and just undone. **7, 8, 9, 10 are the work.**

## The two that actually matter

### 7 — the linker (`aot-tools.dill`)

This is the only item that is genuinely *hard*, and it is the one that gates iOS
code push. It is also the one where the private fork mattered — and per
[`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md), much less than we assumed: vanilla Dart
already ships the interpreter, the `InterpretCall` stub and
`Function::AttachBytecode`. What we owe is a **binder**, not an interpreter.

Note the asymmetry, because it changes priorities: **Android never invokes the
linker** (its patches carry real machine code), so items 1–6 plus 8 already give
full Android independence. The linker buys iOS.

### 8 — building the whole artifact set

This is not hard, it is *wide*. The artifact set spans OS × arch × runtime mode,
and the honest constraint is in [`ENGINE_BUILD.md`](ENGINE_BUILD.md): **you cannot
build every target from one machine.**

| Host | Can build | Have it? |
|---|---|---|
| Linux | Android + Linux engines | ✅ the build box |
| macOS | iOS + macOS engines | ✅ this Mac (as of 2026-08-03) |
| Windows | Windows engine | ❌ none |

So with the two hosts we have, we can *build* everything except the Windows engine.
Windows artifacts stay mirrored until there is a Windows builder — and that is a
perfectly reasonable place to stop, since nothing we ship targets Windows. It should
be a recorded, deliberate gap rather than an accident.

`selfhost/engine/build.sh` currently implements one cell (`--cell android-arm64`).
Full coverage means adding cells per target, which is mechanical once the macOS
build works.

## What "independent" will mean concretely

When 6–10 are done, the test is:

> Block `*.shorebird.dev` and `storage.googleapis.com/shorebird-*` at the firewall.
> A clean machine can still: install the CLI, create a release, publish a patch, and
> have a device apply it — on Android **and** iOS.

That is a runnable acceptance test, and it is the right definition of done. Until it
passes, "independent" is an aspiration. Worth running deliberately once the pieces
land, because it is the only way to catch a literal URL nobody noticed — exactly the
class of problem [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) documents, where three
separate spots overwrite `FLUTTER_STORAGE_BASE_URL` and two getters read no
environment variable at all.

## Order of work

1. **Finish the macOS/iOS engine build** (in flight) — unlocks item 8 for Apple targets.
2. **Run the iOS code-push kill gate** — decides item 7's shape before any linker code.
3. **Build and serve the `patch` binary** (item 6) — small, removes a download.
4. **Add build cells per target** (item 8) and serve from our own store, replacing the
   overlay-on-their-CDN with a store whose bytes we produced.
5. **Mirror or replace the manifest** (item 9), then host a git mirror (item 10).
6. **Run the firewall acceptance test.**

Steps 3–5 are unglamorous and low-risk; step 2 is the one that can still change the
plan.
