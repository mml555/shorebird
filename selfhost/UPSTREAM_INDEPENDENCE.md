<!-- cspell:words bidiff dartaotruntime killgate tearoff -->

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
| 2 | `shorebirdtech/dart-sdk` (**private**) | Their Dart VM fork | Vanilla Dart `d684a576` + our 57-line snapshot-size shim ([`engine/dart-fork/`](engine/dart-fork)) | **Built ✅ for Android; NOT sufficient for iOS** ⚠ — see below |
| 3 | `gs://shorebird-dart-sdk-prebuilt` (**private**) | Prebuilt Dart SDK for macOS; 401s for us | `custom_vars: {download_dart_sdk: False}` + `tools/gn --no-prebuilt-dart-sdk`, compiling Dart from source | **Built** ✅ 2026-08-03 |
| 4 | `shorebird_cli` | The CLI | Forked in-repo, version-pinned, `+selfhost.N` | **Built** ✅ (we track their releases by choice, not need) |
| 5 | `bundletool.jar` | Android bundle tool | Comes from `github.com/google/bundletool` — Google, never Shorebird. For FULL self-containment: `SHOREBIRD_BUNDLETOOL_URL` override (checksum still verified) + the jar mirrored at `overlay/mirror/bundletool/` (2026-08-05) | **Built** ✅ |
| 6 | `patch` binary | The binary differ that produces patch payloads | `vendor/updater/patch` (`bidiff 1.0.0`) — source was always ours. [`engine/publish_patch_tool.sh`](engine/publish_patch_tool.sh) builds and packages it. **Output verified byte-identical to theirs** (2026-08-03) | **Done** ✅ 2026-08-05: darwin-arm64 + darwin-x64 + linux-x64 in the overlay for the pinned rev and every mapped hash; publish scripts carry it automatically; windows stays mirrored (recorded gap) |
| 7 | `aot-tools.dill` | **Their AOT linker.** Emits `.vmcode` + link percentage | Route decision in progress via two kill-gate spikes (2026-08-05): **Spike B (Track E binding) PASSED** — see [`engine/killgate/README.md`](engine/killgate/README.md); Spike A (pool identity) day-0 + deltas strongly positive — see [`engine/spike/README.md`](engine/spike/README.md). Cache-side already independent: a blocked fetch warns instead of dying | **In progress** ◐ |
| 8 | `download.shorebird.dev` engine artifacts | The per-engine-revision artifact set the CLI fetches | Build every artifact ourselves and serve from our own store | **Mirrored** ◐ |
| 9 | Artifact manifest in their GCS | `artifact_proxy` fetches it with a literal URL | Mirror it, or drop `artifact_proxy` and serve our own manifest | **Mirrored** ◐ |
| 10 | `shorebirdtech/flutter` git | Engine + framework source (public) | Vendored snapshot at [`vendor/flutter`](../vendor/flutter); the CLI bootstrap clone is now overridable via `SHOREBIRD_FLUTTER_GIT_URL` (CLI + both wrappers, 2026-08-05) with a bare mirror recipe at `cdn/mirrors/` (`uploadpack.allowfilter=true` for the tree:0 clone) — bootstrap-from-mirror verified. The *engine build* checkout (gclient) still wants a reachable remote | **Built ✅ for CLI bootstrap; Mirrored ◐ for engine builds** |

Items 1–5 are done. 6 is trivial and just undone. **7, 8, 9, 10 are the work.**

## Correction, 2026-08-04: item 2 is not settled for iOS

"Vanilla Dart + a 57-line shim" is **verified sufficient for Android and verified
insufficient for iOS.** Do not treat item 2 as closed.

Our `gen_snapshot` cannot read **any** Flutter-target AOT kernel, no matter who
wrote it. A four-way bisect, swapping a single cached file each time:

| kernel writer stack | gen_snapshot (reader) | result |
|---|---|---|
| ours | stock | builds ✅ |
| ours | **ours** | `Unexpected tag 4 (Field)` ❌ |
| stock | **ours** | `Unexpected tag 4 (Field)` ❌ |
| stock | stock | builds ✅ |

The third row is what matters: it fails on kernel *Shorebird's own toolchain*
wrote, so nothing on the writing side is to blame. Our tree is not internally
inconsistent either — `dart compile aot-snapshot hello.dart` with our own SDK
succeeds (our CFE `--aot --tfa` + our `gen_snapshot`, 970 KB output), and our
reader handles a plain kernel fine. The failure appears only once `dart:ui` is in
the platform dill.

And here is the part that closes the question of "just use the right revision":

```
stock dart-sdk-darwin-arm64.zip -> dart-sdk/revision
  db98bdaa9d8f8e2250ff83d24abcaf775807244c   (version 3.12.2)
```

That commit is **not a vanilla Dart commit**. `git fetch` of it from
`github.com/dart-lang/sdk` returns `upload-pack: not our ref`, and
`dart.googlesource.com/sdk` 500s. It is a commit in their **private** fork, so we
cannot build their exact toolchain.

**But that does not mean there is nothing to rebase onto — an earlier draft of this
section said so and was wrong.** Testing their private SHA was the wrong test.
Vanilla publishes release tags, and the matching one exists:

```
refs/tags/3.12.0  3b675ba8536e5be310e520b57371c03aea9b8eaa
refs/tags/3.12.1  72eb53d58f732c32df6ab0a7e3939847a72466b0
refs/tags/3.12.2  704629bcd35e8bc1dd6b4808b618cccbbbd8fb6a   <-- the target
```

### Correction to the correction, 2026-08-04 (later): we were already on the tag

The paragraph that used to sit here said our tree was "a single-commit synthesized
repo on an undocumented base" and planned a rebase onto `704629bc`. **Both halves
were wrong, and the rebase would have been a no-op.**

`refs/tags/3.12.2` is an **annotated** tag. `704629bc` is the tag *object*; the
commit it points at is `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` — exactly the
base `create_dart_fork.sh` already uses. `git ls-remote` prints only the tag
object for this tag (no `^{}` peel line, unlike `3.12.0`), which is what made two
different SHAs look like two different commits:

```
$ git cat-file -t 704629bcd35e8bc1dd6b4808b618cccbbbd8fb6a
tag
$ git cat-file -p 704629bcd35e8bc1dd6b4808b618cccbbbd8fb6a | head -3
object d684a576a6aa954ae107a03b2b4e1d61c3bebe93
type commit
tag 3.12.2
```

`tools/VERSION` at that commit reads `CHANNEL stable / MAJOR 3 / MINOR 12 /
PATCH 2 / PRERELEASE 0` — a stable release, not a mid-development snapshot. (The
"`sdk/version` reads 3.12.0" claim was reading something else; there is no
`sdk/version` file.) Shorebird's own `DEPS` names the same commit as
`dart_revision`, alongside their private `dart_sdk_revision`. **Our Dart is
vanilla stable 3.12.2 plus the 57-line shim, and always was.**

The standing rule still holds — base the fork on a published release tag — we were
simply already following it.

**What actually broke iOS** was not the base. It was one line in
`runtime/vm/compiler/aot/dispatch_table_generator.cc`, unchanged in Dart `main` to
this day: a tear-off selector being applied to a field's *implicit accessor*,
which overwrites the accessor's `Field` pointer with a closure. Fix and full
evidence chain: [`engine/0004-dart-tearoff-selector-guard.patch`](engine/0004-dart-tearoff-selector-guard.patch)
and [`HANDOFF.md`](HANDOFF.md). With it applied, our `gen_snapshot` compiles a
`dart:ui`-bearing Flutter app in 4 seconds and `shorebird release ios` completes
on our own engine.

So the second row of the bisect table above now reads *ours/ours → builds ✅*, and
item 2's iOS **build** gap was a one-line bug in vanilla Dart, not a load-bearing
piece of their private fork.

**Item 2 is now closed for iOS as well (2026-08-05).** A Flutter app runs to
first frame on our engine and takes an assets-only patch end to end —
device-verified, `assets patch: 1` with the patched value rendered. It took four
compensations for the same root problem: the dill's TFA metadata (`call_count`,
`torn_off`, `has_tearoff_uses`) is a **lower bound**, while vanilla's AOT
compiler treats it as exact, and AOT product snapshots have no
`Class::functions()` to fall back on when a dispatch-table row is missing. See
[`engine/0004`](engine/0004-dart-tearoff-selector-guard.patch),
[`0005`](engine/0005-dart-precompiler-link-info-and-tearoffs.patch),
[`0006`](engine/0006-dart-no-dispatch-call-for-hash-slots.patch) and the
"RESOLVED" section of [`HANDOFF.md`](HANDOFF.md).

The *cause* of the under-reporting is still unknown and lives in
`pkg/vm/lib/transformations/type_flow/`. Fixing it there would let most of these
four patches be deleted, so item 2 is closed in the sense of "works and is
ours", not "minimal".

Two new upstream dependencies surfaced along the way: the **DD two-pass build**
(`gen_snapshot --print_dd_function_identity_to` plus four `analyze_snapshot
--dd_*` modes, all private; disable with `--dd-max-bytes=0`), and the fact that
stubbing a flag only works when nothing reads what it writes.

## The two that actually matter

### 7 — the linker (`aot-tools.dill`)

This is the only item that is genuinely *hard*, and it is the one that gates iOS
code push. It is also the one where the private fork mattered — and per
[`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md), much less than we assumed: vanilla Dart
already ships the interpreter, the `InterpretCall` stub and
`Function::AttachBytecode`. What we owe is a **binder**, not an interpreter.

Note the asymmetry, because it changes priorities: **Android never invokes the
linker** (its patches carry real machine code), so items 1–6 plus 8 already give
full Android independence. The linker buys iOS *code* patches — and only those:
an **assets-only iOS patch never invokes it** — and that is now **device-verified**
(2026-08-04, iPhone9,1 / iOS 15.8.8). The patch carries `arch=assets` alone, no
code artifact and no symbols, against the older patch on the same app which has
`aarch64` + `symbols` because it went through the linker. On device the app
rendered `code patch: none` beside `assets patch: 1` with the patched asset
served: the native updater was correctly offered nothing, and the asset arrived
through `code_push_runtime`'s own discovery call. So the linker gates iOS *code*
patches only, in practice and not just on paper.
~~The CLI still *downloads* `aot-tools.dill` during cache warm-up and dies if
that fetch fails~~ — closed 2026-08-05: `CachedArtifact.update()` now treats a
**connection failure** on an optional artifact like the 404 it already
tolerated — `logger.warn` naming the URL, no stamp file (so a later online run
retries), command continues. Independent at use **and** at cache. The mirror
side matches: `@must_be_local` owns `aot-tools.dill` for experimental hashes,
so a fork-hash request 404s loudly instead of silently serving the pinned
linker the fork engine cannot use.

Two facts established 2026-08-04 that bound this item precisely:

- **`pkg/aot_tools` does not exist in vanilla Dart** (checked at `6b58bb3a`,
  3.12.0). It is purely their private-fork addition, so item 7 can only ever be
  *rewritten*, never built from source. Any plan that assumes "build it from the
  Dart tree" is wrong.
- **The linker is not the only private-fork dependency iOS had.** `config.gni`
  sets `SHOREBIRD_USE_INTERPRETER=1` for `is_ios` alone, which compiles
  `runtime/shorebird/patch_cache.cc`, which calls two symbols vanilla lacks:
  `Shorebird_ReadLinkHeader()`, and `Dart_LoadELF()` with an 8th
  `dart::bin::kReadOnly` argument (vanilla takes 7 —
  `runtime/bin/elf_loader.h:40`). *That one line* is why Android built against
  vanilla Dart and iOS could not. Gating it behind a `shorebird_use_interpreter`
  GN arg (default `is_ios`, i.e. upstream behavior) is what unblocked our own iOS
  engine; see [`engine/0002-ios-engine-on-vanilla-dart.patch`](engine/0002-ios-engine-on-vanilla-dart.patch).
  What is lost with it off is exactly iOS code patches, which we cannot produce
  anyway without item 7.

### 8 — building the whole artifact set

This is not hard, it is *wide*. The artifact set spans OS × arch × runtime mode,
and the honest constraint is in [`ENGINE_BUILD.md`](ENGINE_BUILD.md): **you cannot
build every target from one machine.**

| Host | Can build | Have it? |
|---|---|---|
| Linux | Android + Linux engines | ✅ the build box |
| macOS | iOS + macOS engines | ✅ this Mac — **iOS engine actually built 2026-08-04** |
| Windows | Windows engine | ❌ none |

The iOS engine is no longer hypothetical: `out/ios_release` produced
`Flutter.framework` + `Flutter.xcframework/ios-arm64` (arm64, `minos 13.0`), with
the updater compiled in and no reference to the private fork. Two things it cost
that are not obvious:

- **`xcodebuild -downloadComponent MetalToolchain` (688 MB) is required.** Impeller
  compiles Metal shaders directly on iOS, so the Metal-toolchain failure that
  `ENGINE_BUILD.md` records for the macOS *host* build applies here too. Checking
  for ANGLE and concluding "safe" is the wrong test — the trigger is any Metal
  compilation, and the build dies at ~6,350/6,824 without it.
- **It is published to the overlay** ([`engine/publish_ios_overlay.sh`](engine/publish_ios_overlay.sh),
  hash `5a6b0b09…` = sha1 of the device-slice binary). Four artifacts serve from
  our mirror with `must_be_local=1`, so a miss is a loud 404 rather than stock
  bytes: `ios-release/artifacts.zip`, `dart-sdk-darwin-arm64.zip`,
  `flutter_patched_sdk_product.zip`, `darwin-arm64/artifacts.zip`. The last three
  are the macOS host toolchain and are **not optional** — `frontend_server_aot` is
  an AOT snapshot run by our `dartaotruntime`, and its kernel is read by our
  `gen_snapshot`, so the whole chain must share one tree *and* one GN config.
- **No app has run on it yet.** A release built against it currently fails in the
  iOS AOT step because the shared Dart checkout still carries Track E's killgate
  edits, which leak into the platform dill. See the GN-config invariant in
  [`HANDOFF.md`](HANDOFF.md). Until that is resolved, iOS releases run on
  Shorebird's prebuilt engine.
- Two private-fork dependencies had to be closed before an iOS release could even
  be attempted: the `SHOREBIRD_USE_INTERPRETER` gate above, and **six
  `print_*_table_link_*_to` gen_snapshot flags** that their flutter_tools passes
  unconditionally on Apple targets (`base/build.dart`, gated only on
  `usesLinker = (ios || darwin)`). Vanilla gen_snapshot rejects them and exits 255,
  so *no* iOS release of any kind was buildable on vanilla Dart. Now registered in
  our fork, writing self-describing stubs a real linker must reject.

So with the two hosts we have, we can *build* everything except the Windows engine.
Windows artifacts stay mirrored until there is a Windows builder — and that is a
perfectly reasonable place to stop, since nothing we ship targets Windows. It should
be a recorded, deliberate gap rather than an accident.

`selfhost/engine/build.sh` currently implements one cell (`--cell android-arm64`).
Full coverage means adding cells per target, which is mechanical once the macOS
build works.

## What "independent" will mean concretely

## PASSED 2026-08-06 — both platforms, mirror sealed, from empty caches

| Leg | Engine | Release | Patch | Stages | Isolation |
|---|---|---|---|---|---|
| iOS (macOS) | `70974f81` | `34.0.0+1` | 1 | bootstrap / ios / post-checks **PASS** | **OK** |
| Android (Linux) | `760e3fab` | `1.5.0+1` | 1 | bootstrap / android / post-checks **PASS** | **OK** |

Both from an empty `bin/cache` with the mirror in sealed mode — every
upstream fetch refused — and both completed release **and** patch.
Zero blocking refusals. Everything refused was the harness's own probe
(`/gcs/AIRGAP-SEAL-PROBE`, `/`) or `android-x86` (an ABI nothing here ships;
a full iOS release and patch completed while it was denied). Notably **no
`aot-tools.dill` refusal on either leg** — the assets-only iOS path really
does not ask for it.

**What this establishes:** no dependency on closed upstream systems. All
Shorebird artifact traffic routes through the mirror; the mirror refused
upstream throughout; both platforms still shipped.

**What it deliberately does NOT claim:** "no network". GitHub and pub.dev
stayed reachable and are reported as such. Depending on open-source
infrastructure is fine — we mirror it for durability, not because reaching
it is a failure.

Caveats recorded honestly:
- macOS host-level packet blocking was abandoned: Tailscale reloads pf and
  flushes any anchor, so a host seal cannot be held there. The mirror seal
  carries the proof and is enforced inside the container regardless.
- Android icon tree-shaking stays disabled pending a fork `linux-x64`
  `const_finder` (see `engine/publish_font_subset.sh` for the macOS
  equivalent that was fixed).

## The test itself

The test — now **implemented** at [`scripts/airgap_run.sh`](scripts/airgap_run.sh)
(packet-level seal: pf anchor on macOS / netns on Linux, /etc/hosts tripwire,
preflight probes, ISOLATED cache homes) driving
[`scripts/airgap_acceptance.sh`](scripts/airgap_acceptance.sh)
(empty `bin/cache` bootstrap → android release+patch → iOS release with DEFAULT
flags + assets-only patch → `cdn/verify_warm.sh` post-check), scoped wider than
originally specified (2026-08-05 decision — FULLY self-contained):

> With the mirror SEALED (`cdn/docker-compose.cdn.sealed.yaml` — it refuses
> every upstream fetch with a greppable `sealed:` 502), from an empty
> `bin/cache` and ISOLATED caches (`PUB_CACHE`, `GRADLE_USER_HOME`,
> `XDG_CACHE_HOME`, `TMPDIR`; `HOME` is kept, it holds preinstalled tooling —
> the macOS keychain and the Android SDK), a clean machine can still install
> the CLI, create a release, publish a patch, and have a device apply it —
> Android **and** iOS. Open-source hosts may stay reachable; the point is that
> nothing CLOSED is required.

Deliberate, recorded mirrored-stock policy (NOT rebuilt; served from the warm
sealed cache): `android-arm64-release/{darwin,windows}-x64.zip` host
gen_snapshots, `sky_engine.zip` (Dart source of dart:ui, identical to stock),
Windows engine artifacts, `patch-windows-x64.zip`. "Warm" is defined by one
full real build per flow through the unsealed mirror — never by a URL list
(the documented lesson: URL-list warming missed Maven).

Bootstrap smoke of stage 1 passed 2026-08-05: a fresh clone with an empty
`bin/cache` bootstrapped with the Flutter clone origin =
`file://…/cdn/mirrors/flutter.git` and mirror-only artifacts. The full sealed
two-platform run is still pending (needs sudo for the seal, the Linux netns,
and the device→control-plane link restored).

Until the sealed run passes, "independent" is an aspiration. It is the only
way to catch a literal URL nobody noticed — exactly the class of problem
[`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) documents, where three separate
spots overwrite `FLUTTER_STORAGE_BASE_URL` and two getters read no environment
variable at all.

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
