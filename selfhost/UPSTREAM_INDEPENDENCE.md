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
| 10 | `shorebirdtech/flutter` git | Engine + framework source (public, open source) | Vendored snapshot at [`vendor/flutter`](../vendor/flutter); the CLI bootstrap clone is overridable via `SHOREBIRD_FLUTTER_GIT_URL` (CLI + both wrappers) with a bare mirror at `cdn/mirrors/` — bootstrap-from-mirror verified. **Durable copy pushed to `github.com/mml555/shorebird-flutter-mirror` 2026-08-06 (1779 refs), and RESTORE-tested**: a `--filter=tree:0` clone from it checks out the pinned `c15ef637` with the right `engine.version`. The *engine build* checkout (gclient) still wants a reachable remote | **Built ✅ for CLI bootstrap (durable); Mirrored ◐ for engine builds** |

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

### Scope decision, 2026-08-06: own the guarantee, not the artifact count

**Item 8 is NOT "rebuild every artifact Shorebird publishes."** That creates work
without increasing the guarantee. The ownership rule instead:

> Own every artifact whose correctness depends on our Dart/Flutter tree, or whose
> URL is under one of our custom engine hashes. Mirror stock only when the
> artifact is demonstrably tree-independent, or belongs to a platform we
> deliberately do not build.

Scope is the two cells we actually verify — **linux-android** and
**macos-ios (arm64)**. Windows and the Intel-Mac host cell stay mirrored-stock
and explicitly outside the acceptance bar. Making the inventory read 10/10 by
standing up a second build farm is not the goal; not being able to tell built
from mirrored is the actual risk.

The policy is written down in
[`cdn/artifact_policy.conf`](cdn/artifact_policy.conf) and enforced by
[`cdn/audit_overlay.sh`](cdn/audit_overlay.sh), which cross-checks the policy
against the overlay on disk **and** against the Caddyfile's `@must_be_local`
matcher. The three drift independently, and the third is the dangerous one: an
artifact we believe we own but which is not route-protected serves **stock bytes
silently** from the pinned hash.

Four provenance states, because two cannot express what is happening:
`owned-built`, `owned-mirrored` (we serve it, upstream compiled it, and it is
tree-*independent*), `compat-mirrored` (stock, for a cell we do not build —
**never** supports a self-built claim), and `denied` (route-protected and
deliberately absent, because a 404 beats a silent toolchain mix).

#### AUDIT CLEAN on both cells, 2026-08-07

| | linux-android (`760e3fab`) | macos-ios (`70974f81`) |
|---|---|---|
| owned-built | 18 | 13 |
| owned-mirrored | 7 | 0 |
| compat-mirrored | 1 | 1 |
| denied | 6 | 4 |
| **missing-required** | **0** ✅ | **0** ✅ |
| **unprotected** | **0** ✅ | **0** ✅ |
| verdict | **AUDIT CLEAN** | **AUDIT CLEAN** |

No `deferred` items remain: the Linux `const_finder` was built and published on
2026-08-07 (below).

##### Linux `const_finder` — built, proven, owned

The Android cell's `linux-x64/font-subset.zip` now carries **our**
`const_finder.dart.snapshot`. Unlike the macOS cell, it could not be extracted
from anything — the fork's `linux-x64/artifacts.zip` contains neither
`const_finder` nor `font-subset` — so it had to be built.

The three proofs, run on the build box against the published fork SDK
(`4bd36869`):

| | result |
|---|---|
| fork SDK + **our** const_finder | **loads** (reaches const_finder's own arg parser) |
| fork SDK + **stock** const_finder | **rejected** — `Can't load Kernel binary: Invalid SDK hash` |
| `font-subset` binary | ELF x86-64, **0** Dart symbols, harfbuzz present — genuinely Dart-independent, so upstream's is used unchanged |

**The trap worth remembering:** `ninja`'s own `const_finder` target produces a
kernel our SDK **rejects**, even though the rule passes `-Dsdk_hash=4bd3686914`
— our fork's revision. `-Dsdk_hash` is a program *define*, not the stamp; the
kernel's SDK hash comes from the **compiling VM**, and that target compiles with
the *prebuilt* dart (`d684a576`, the vanilla base). Running upstream's exact
command with our dart as the binary yields a same-sized, byte-different kernel
that loads. Building it "the official way" is precisely what fails here.

Protection is scoped to `760e3fab` alone, for the same reason the darwin-arm64
note gives: only a hash publishing **our** Linux host toolchain may serve our
const_finder. Any other hash builds with a stock Dart SDK and needs the stock
one, so falling through is correct there.

Also corrected: HANDOFF claimed the box's Flutter cache carried our
`dart-sdk (4bd36869)`. It now reads `d684a576`, the vanilla base. The fork SDK
had to be fetched from the overlay for the proofs.

Both cells' `sky_engine.zip` and `flutter_gpu.zip` were built from **their own**
verified trees — never copied between hashes — and both are content-identical
to stock, which is the correct result because neither shipping tree modifies
`sdk/lib`. Gates checked before each publish:

| cell | tree identity | `sdk/lib` clean? |
|---|---|---|
| linux-android | `artifacts.zip` byte-identical to the published engine (`ecdcb458…`) | yes |
| macos-ios | sha1 of `out/ios_release/…/Flutter` **is** `70974f81…` — the hash is the content | yes, and no killgate marker |

The iOS gate mattered: `engine/killgate/0001` modifies
`sdk/lib/_internal/vm/lib/internal_patch.dart`, so a tree carrying it would
have produced a *different* `sky_engine` for Track E's configuration. It was
absent, which is what made this tree safe to publish from.

##### Routing verified live, not asserted

`@must_be_local` is hash-generic, which is right for artifacts every hash
publishes and wrong for these two — they are owned **per cell**, from each
cell's own tree. A second matcher, `@must_be_local_pkgs`, spells out the two
supported hashes, so the superseded, Track E and diagnostic hashes keep falling
through to stock (correct for a cell we do not support) instead of 404ing.
`audit_overlay.sh` reads **both** matchers.

Four behaviors were then tested against the running mirror:

| behavior | result |
|---|---|
| supported cell serves our bytes | `200`, `X-Overlay: hit`, sha256 = ours, ≠ stock |
| unsupported hash (`fc184af6`) | `302` — falls through, as intended |
| overlay miss on an owned path | **`404`** — loud, never stock |
| both audits after the change | **AUDIT CLEAN** |

##### A trap that hid all of this at first

**Editing the Caddyfile and reloading does nothing.** It is a *single-file*
bind mount, so the container holds the original inode; an editor that writes a
new file and renames it leaves the container reading the old one forever. The
symptom is a syntax error at a line number that does not match your file — the
container is validating a version you cannot see. `docker exec … sha256sum
/etc/caddy/Caddyfile` against the host file is the check. Recreate the
container (`up -d --force-recreate cdn-cache`); do not trust a reload.

Per-artifact records are in each hash's
`overlay/…/<hash>/sky_packages_provenance.txt`, and `provenance.yaml` (emitted
from the policy) sits beside the Flow B artifacts for both cells.

Three things learned by running it for real, none of which were guessable:

1. **The two packages come from different places.** `sky_engine` is build
   output (`out/<config>/gen/dart-pkg/sky_engine`, 288 files); `flutter_gpu`
   has **no build output at all** — the published zip is the source directory
   `flutter/lib/gpu` (34 files) packaged verbatim. File lists were diffed
   against stock and match exactly.
2. **Both zips carry a root `LICENSE.zip_old_location.md`**, a licensing
   pointer naming the upstream flutter/engine revision. We copy stock's
   verbatim; it states where the LICENSE is hosted, and rewriting it would
   misstate that. (It also independently corroborates that `83675ed2…` is the
   upstream Flutter base — see the item 9 correction above.)
3. **Protection is GLOBAL, and that changes the order of work.**
   `@must_be_local` matches `[0-9a-f]{40}`, so protecting `sky_engine.zip`
   protects it for **all seven mapped hashes at once**. Six of them do not have
   the bytes — including the live iOS engine `70974f81` — so protecting after
   only the Android publish would 404 the artifact for iOS and break every iOS
   build. The per-cell plan does not survive contact with a hash-generic
   matcher. `audit_overlay.sh` detects this and prints **NOT SAFE TO PROTECT
   YET** with the offending hashes named.

   **Resolved** by scoping the protection instead of widening the publishing:
   `@must_be_local_pkgs` names the two supported hashes explicitly, so the
   other five keep falling through to stock. Borrowing one cell's copy to
   satisfy another was never an option — they are engine-revision namespaced,
   and copying is the exact thing this policy exists to prevent.

Both misses are the same pair, and both were **invisible before the audit
existed**: `sky_engine.zip` and `flutter_gpu.zip`. They are
`getPackageDirs()` in flutter_tools' `FlutterSdk` cache class
(`flutter_cache.dart:264`), fetched as
`flutter_infra_release/flutter/<hash>/<name>.zip`, namespaced by engine
revision, and carrying Dart-facing engine API source — and today a request for
either under a custom hash falls through to stock.

`sky_engine.zip` being byte-identical to stock today is **not** a property to
depend on; it is the same shape as the frontend/backend metadata disagreement in
[`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md), where "the two happen to agree" held
right up until it did not. The fix is: generate from our pinned Flutter tree,
diff against stock, *record* that they match, and publish ours anyway. That
removes fallback from the correctness path.

`flutter_gpu.zip` was not on anyone's list — the audit found it by reading
`getPackageDirs()` rather than by enumerating what we had already published.

One `deferred` item on the Android cell: `linux-x64/font-subset.zip`, the fork
`linux-x64` `const_finder`. Compensated today by `--no-tree-shake-icons`;
building it re-enables Android icon tree-shaking and flips it to required.

**Fix order matters and the audit prints it:** publish the bytes first, *then*
add the path to `@must_be_local`. Protecting an absent artifact 404s every build
against that hash.

Also corrected while writing the policy: the Caddyfile's own comment claimed
`android-arm64-release/{darwin,windows}-x64.zip` were "deliberately NOT owned",
but its regex has no `$` anchor after `android-arm64-release/`, so it matches
every file under that prefix and both 404. The **behavior** is right — a stock
host `gen_snapshot` served against our engine is exactly the fork mix
`dart_sdk_compatibility.dart` refuses to build through — so the policy records
them as `denied` and the comment was fixed.

### 9 — the artifact manifest

The gap here is **content, not routing**: `artifacts_manifest.yaml` is already
route-protected under custom hashes, but what sits under them is generated by
*Shorebird's own* scripts and describes their artifact set rather than ours.

**Correction, 2026-08-07.** An earlier version of this section called
`flutter_engine_revision: 83675ed2…` a stale substitution, "neither our hash nor
the pin". That was wrong, and the schema says so: the field is documented in
`artifact_proxy/lib/src/models/artifacts_manifest.dart:50` as *"the flutter
engine revision that this engine mapping is based on"* — the **upstream Flutter
engine**, which is neither supposed to be our hash nor the Shorebird pin.
Fetching the pinned revision's own manifest from upstream shows the identical
value, and `70974f81`'s copy is byte-identical to it (sha256 `f1e398c8…`).

What is actually wrong is more interesting, and it is a real inconsistency:

| hash | generator | `flutter_engine_revision` |
|---|---|---|
| `70974f81` | `shard_runner:finalize` template | `83675ed2…` — the upstream Flutter engine (correct per the schema) |
| `760e3fab` | `artifact_proxy/tool/generate_manifest.sh` | `760e3fab…` — **its own custom hash** |

So the two supported cells carry manifests written by two different scripts
that disagree about what the field means. Naming our own hash there tells the
proxy to resolve every non-overridden artifact from Flutter's CDN under a
revision Flutter has never heard of.

It does not break today for one reason, and the reason is load-bearing and
recorded nowhere in the manifests themselves: **Caddy rewrites an experimental
hash to the pinned one before `artifact_proxy` ever sees it**, so neither file
is actually consumed in our topology. `overlay_publish.sh` calls this
"informational for now", which is accurate and is exactly why the drift went
unnoticed.

Neither manifest describes our artifact set either — both list overrides for
Windows, x86 and arm ABIs we do not build.

`audit_overlay.sh --emit-manifest` writes `provenance.yaml` beside the
artifacts, generated from the policy so the two cannot drift. Per artifact it
records provenance, requirement, whether it is present, whether it is
route-protected, and `verified_for_custom_engine` — which is the field that
stops "present in our mirror" from being read as "produced by our toolchain".

#### Android manifest regenerated and PROVEN, 2026-08-07

[`engine/generate_manifest.sh`](engine/generate_manifest.sh) rewrote
`760e3fab`'s manifest from explicit inputs (flutter `c15ef637`, dart-sdk
`4bd36869` read out of the published `dart-sdk-linux-x64.zip` rather than
trusted from a doc, host `linux-x64`, target `android`), taking the override
list from the pinned revision's own manifest and setting
`flutter_engine_revision` to the upstream Flutter base.

Verified by lookup, not by inspection. `sky_engine.zip` is deliberately **not**
in `artifact_overrides`, so it is the probe: the proxy must resolve it from
Flutter's CDN under `flutter_engine_revision`. Asking `artifact_proxy`
**directly**, bypassing Caddy's hash rewrite, so our manifest is genuinely the
one being read:

```
GET  /flutter_infra_release/flutter/760e3fab…/sky_engine.zip
302  https://storage.googleapis.com/flutter_infra_release/flutter/83675ed2…/sky_engine.zip   200
```

And the counterfactual, which is what the old manifest would have produced:

| resolved target | result |
|---|---|
| `flutter/760e3fab…/sky_engine.zip` (old — our own hash) | **404** |
| `flutter/83675ed2…/sky_engine.zip` (corrected — upstream base) | **200** |

So the latent breakage was real and is now closed for this cell. The invariant
to hold: **every custom-engine manifest names the upstream Flutter base
revision its artifact mapping derives from; custom-engine identity belongs in
the overlay and provenance layer, never in `flutter_engine_revision`.**
`generate_manifest.sh` refuses a base manifest that violates it.

`70974f81`'s manifest is byte-identical to the pinned one and already carries
the correct base, so it needs regenerating only for the provenance header.

### Definition of done for 8 + 9

For both `70974f81` and `760e3fab`:

1. Every artifact consumed by the verified build path exists locally under the
   custom hash.
2. Every Dart/VM-coupled artifact is produced from the matching local tree.
3. `sky_engine.zip` (and `flutter_gpu.zip`) are locally published.
4. No custom-hash request can silently fall through to stock — i.e. zero
   `UNPROTECTED` findings.
5. Manifest provenance distinguishes built, intentionally mirrored, and
   unsupported compatibility cells.
6. A clean-cache sealed build still passes on both platforms.
7. `audit_overlay.sh` reports `missing-required: 0` on both cells.

Items 5 and 7 are done — the tooling exists and runs. 1–4 need the publishes;
6 is a re-run of the harness that already passed.

## What "independent" will mean concretely

## Status, 2026-08-07 — read this before the 2026-08-06 section below

Two different claims were being blurred together. Split explicitly:

| claim | status |
|---|---|
| iOS artifact independence | **PASS** |
| iOS release reaches first frame on device | **PASS** |
| iOS device → control-plane reach | **BLOCKED** |
| iOS assets-patch application on device | **NOT VERIFIED** |
| Android full device lifecycle | **PASS** |

**Infrastructure and artifact independence is effectively closed.** On iOS the
sealed system bootstraps from empty isolated caches, builds the release,
publishes it, publishes the assets-only patch, touches no closed upstream
Shorebird artifact, and runs the fixture to **first frame on the physical
device**. Android additionally carries the full device proof — default-path
release with icon tree-shaking, first frame, a real **Dart code** patch,
patched behavior, and rollback (2026-08-07).

### The one outstanding gap

> **iOS device patch-fetch/application verification is blocked by device
> Local Network permission state.**

The iPhone sends **nothing** to `cps-ios` — not the Dart beacon and not the
native Shorebird updater. Three independent senders failing identically, on
both link-local and LAN transports, with the app rendering correctly and no
error surfacing. That rules out the fixture, the harness and the transport;
what is left is iOS denying the process local-network access, silently and
without a prompt, which iOS does permanently once a denial is recorded. It is
per-app, which is consistent with `com.jewgo.assetprobe` having worked in
earlier runs while this new bundle id does not.

**The next step is one device setting, tried once:**
Settings → Privacy & Security → Local Network → *Airgap Probe* → enabled.

If that resolves it, finish the cycle and close the gate. If the entry is
absent, already enabled, or changes nothing, **stop infrastructure work here.**
The iOS device networking/signing rig can be hardened alongside the first
Route B physical-device integration, which needs reliable iPhone
communication anyway.

**Do not call the two-platform device gate passed** until the iPhone actually
contacts `cps-ios` and applies the assets patch. Android must not be allowed
to carry the iOS device claim — they are different claims.

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

## Final sealed regression — stack VALIDATED, legs BLOCKED on a missing app

### The three-file CDN stack works (validated 2026-08-07)

`docker-compose.cdn.yaml` + `.tlslocal.yaml` + `.sealed.yaml` had never been run
together. It composes correctly — the two overlays touch **different** mount
targets (`tls_listen.caddy` and `upstream_gcs.caddy`), so neither clobbers the
other:

| check | result |
|---|---|
| HTTPS listener, CA validation enforced | `200` **from the build box** (see note) |
| overlay artifact over HTTPS and HTTP | `200` / `200` |
| deliberately cold upstream path | `502` `sealed: refusing upstream fetch for …` |
| `audit_overlay.sh`, both cells | **AUDIT CLEAN** |

Note on the first row: the **Mac's** curl does *not* trust the local CA
(`self signed certificate in certificate chain`); only the box has it, via
`tls/trust.sh`. That is fine and not worth fixing — the Mac runs the iOS leg,
which has no Gradle and uses `http://localhost:8085`. HTTPS is only load-bearing
on the Android leg, where Gradle refuses insecure repos.

**A trap that bit during this validation:** bringing the CDN up with only
`docker-compose.cdn.yaml` **silently drops the TLS listener**, because HTTPS
lives in the `tlslocal` OVERLAY. Port 8443 stays published, so it looks alive
and answers `Connection reset by peer`. Always pass every `-f` the current mode
needs; `docker inspect … .Mounts` is the check.

### What blocks the legs

The harness requires `--app <flutter app dir>`, and **the iOS acceptance app no
longer exists on disk.** It lived in a prior session's scratchpad, which has
been cleaned, and its path was never recorded — the docs only ever say
`--app <dir>`. The Android app (`rbtest`) is intact on the build box.

So the run cannot be a regression against the same artifact until an iOS test
app is reconstituted. What that needs, in order:

1. A Flutter app on the Mac with `shorebird.yaml` pointing at `cps-ios`
   (`http://localhost:18080`) and a `probe.json` asset, matching the shape the
   assets-only patch check expects.
2. A **warm** (unsealed) full iOS run to populate the mirror cache and seed
   `AIRGAP_PUB_CACHE` — "warm" is defined by executing the workflow, never by a
   URL list.
3. Then the sealed run, both legs.

Also unrecorded and worth fixing when this is set up: the value of
`AIRGAP_PUB_CACHE` used by the passing 2026-08-06 run. `~/.pub-cache` (3.8 GB)
exists and is the likely seed, but that is an inference, not a record.

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
