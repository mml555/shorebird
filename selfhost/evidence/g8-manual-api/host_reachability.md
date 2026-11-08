<!-- cspell:words cdylib ffigen unvalidated precommitted noninteractive unrun -->

# G8 — the host arm is NOT RUNNABLE as specified, and the fixture would have proved nothing

**Identity.** Read 2026-08-13 17:26-17:32 EDT against the tree at the commit this
file lands in. No fixture was built, no device, no mint, no release. This is a
source-determined finding, which is what the classification rule dispatches — and
the reason no run was booked.

## The premise that failed

Lane C's exit criterion is *"`selfhost/fixtures/manual_api_app/` builds, its
lockfile resolves `shorebird_code_push` by `path`, and `checkForUpdate`/`update`/
`auto_update:false` are exercised **on host**."*

**The last clause is not reachable through the package's public API.** The
fixture would have built, run, and reported nothing.

### Why: the updater disables itself when the native library is absent

`vendor/updater/shorebird_code_push/lib/src/shorebird_updater_io.dart:27-41` —
the constructor calls `_updater.currentPatchNumber()` at `:32` inside a `try`,
catches **all** errors at `:37`, prints the "Shorebird engine unavailable" banner
at `:38` (`shorebird_updater.dart:56-69`), and sets `_isAvailable = false` at
`:39`. The symbol lookups are per-symbol `late final`
(`generated/updater_bindings.g.dart:2362-2366`), so the failure is a lazy lookup
at first call rather than a constructor throw.

What the three API calls then do on a plain macOS host:

| call | host behavior | file:line |
|---|---|---|
| `readCurrentPatch` / `readNextPatch` | return `null` | `shorebird_updater_io.dart:59` |
| `checkForUpdate(track:)` | returns `UpdateStatus.unavailable` | `:74` |
| `update(track:)` | **returns silently — no exception, no-op** | `:96` |

So a fixture calling `checkForUpdate` on host would print `unavailable` and exit
0. **That is the false green precommitted outcome #9 warns about**, one step
earlier than the table anticipated: not "a patch number that came from
`readCurrentPatch` rather than your `update()`", but a whole API surface that
answers without touching the mechanism.

### A genuine host exercise is possible — and it is a different piece of work

The upstream package already does it, which is the proof it can be done and the
measure of what it costs:

* `test/integration/helpers/build.dart:12-16` shells `cargo build -p
  library_test_hooks`, producing `libupdater_test_hooks.dylib` on macOS
  (`:26-28`, `:44`). The crate is present — `vendor/updater/Cargo.toml:2` lists
  `library_test_hooks` as a workspace member.
* `test/integration/helpers/test_engine.dart:31-35` opens that cdylib and
  assigns `Updater.bindings = UpdaterBindings(lib)` — legal because
  `updater.dart:19-20` declares `bindings` as a non-`final` static
  (`@visibleForTesting`, `:18`).
* `test_engine.dart:117-127` re-injects the bindings **inside every sub-isolate**
  (`:122`), because `ShorebirdUpdaterImpl` dispatches FFI through `Isolate.run`
  (`shorebird_updater_io.dart:24-26`, `:60`, `:78`, `:98`) and **Dart isolates do
  not share static fields**. The seam is the `run:` constructor parameter at
  `io:24`.
* `test/integration/all_test.dart:85` then asserts
  `await updater.checkForUpdate() == UpdateStatus.upToDate` against a
  `FakePatchServer` — on host, no device.

Two things block a **Flutter fixture app** from doing the same: the public
export (`lib/shorebird_code_push.dart`) exposes only `Patch`,
`ReadPatchException`, `ShorebirdUpdater`, `UpdateException`,
`UpdateFailureReason`, `UpdateStatus`, `UpdateTrack` — reaching
`ShorebirdUpdaterImpl` or `Updater` needs `package:shorebird_code_push/src/...`
imports; and it needs a Rust toolchain to build the cdylib.

**So the honest label for lane C's host arm is NOT RUNNABLE — the harness does
not exist — rather than unrun.** Those are different, and §16's own rule says to
say so instead of booking work against it.

## `auto_update: false` cannot be observed from Dart at all

Not merely unexercised — **structurally invisible**:

* Parsed and honored in the engine: `library/src/yaml.rs:25` (field), `:62-66`
  (parse); `config.rs:110`, `:150` (`unwrap_or(true)`); `updater.rs:272-273`
  (`should_auto_update()`); exported as `shorebird_should_auto_update` at
  `c_api/engine.rs:145-147`.
* Declared **only** in `library/include/updater_engine.h:101`. It is **absent
  from `updater_dart.h`**, and `grep -c auto_update updater_bindings.g.dart` is
  **0**.
* CLI side parses it into `shorebird_yaml.dart:26`, `:60` and never reads it
  beyond (de)serialization.

The Flutter **engine** consumes it at launch; the Dart package can neither read
nor set it. "Exercised on host" for this row can only ever mean "the key is
present in the fixture's `shorebird.yaml`", which asserts nothing.
`init_command.dart:383-387` documents it — and emits it **commented out**
(`:386` "Uncomment the following line").

## Two claims of the order that are simply wrong

**1. The `dependency_overrides` step buys provenance, not behavior.** Step 12
says to override `shorebird_code_push` to the vendored copy "or diff pub's copy
against the vendored one and record the result". Recorded:
`diff -rq ~/.pub-cache/hosted/pub.dev/shorebird_code_push-2.0.7
vendor/updater/shorebird_code_push` reports differences only in `.gitignore`,
`.metadata` and an empty `example/` java dir — **zero differences under `lib/`**,
identical `pubspec.yaml`, identical `updater_bindings.g.dart`. The override is
hygiene; it changes no bytes that execute.

**2. The order cites a RETRACTED mechanism, twice.** Steps 13 and 16 and the
exit criteria justify keeping the restart-required row out of scope via "`G15`'s
**once-per-process** activation guard". `PARITY.md` retracted exactly that
wording: *"this section said 'Route B arms its activation hook once per process',
and that was wrong… arming is attempted on every `ConfigureShorebird`"* — the
cause was the early return above it, gated on an updater init that fails on its
second call. Fixed by patch `0007`, tests executing per patch `0008`.

The row still belongs out of scope — it **is** source-determined and it **is**
`G15`'s — but the reason must be the corrected one. **PARITY's own §8 row
repeated the retracted phrase and is fixed in this commit.** The §8↔`G15` link is
at `PARITY.md:2350-2353`, not `:2337-2340`.

## Anchor drift, corrected where cited

| the order says | actual |
|---|---|
| §8 rows at `:2270`-`:2275`, section spans `:2265-2288` | rows at **`:2273`-`:2279`**, section spans **`:2269-2291`** |
| `airgap_app/pubspec.yaml:29-30` (the `code_push_runtime` path dep) | **`:27-28`** |
| shorebird.yaml-as-asset convention at `airgap_app/pubspec.yaml:34-38` | comment `:33-36`, entry `:37`, `assets:` at `:32`; enforced at `shorebird_validator.dart:106` |
| `G15` link at `:2337-2340` | **`:2350-2353`** |

Everything the order says about the *vendored package itself* checked out exactly:
`shorebird_updater.dart:128` `readNextPatch`, `:153` `checkForUpdate`, `:190`
`update`, `:210` `extension type const UpdateTrack(String value)`, `:212-218` the
three constants, `:221` `String get name => value`, and the FFI marshalling of
`track.name` at `updater.dart:32` and `:39`.

## What is still worth building, and what it would prove

The fixture is **not** worthless — its value is on **device**, not host, which is
where §8's rows were always going to be decided (`R2` for Android). Built as
specified minus the host claim, it would give the Android arm a real driver.

Two notes for whoever takes it:

* **`track` is not exercised end-to-end anywhere today.**
  `grep -c track test/integration/all_test.dart` is **0**, and
  `fake_patch_server.dart` has no track handling; the only coverage is mock-based
  (`test/src/updater_test.dart:60-77`,
  `test/src/shorebird_updater_io_test.dart:323-340`, `:618-636`) and asserts
  forwarding to a mocked binding, never the FFI marshalling. So step 14's "wire
  the track through, which is what unblocks `G6`" is genuinely new ground.
* The override path, verified by directory depth from
  `selfhost/fixtures/manual_api_app/pubspec.yaml`, is
  `../../../vendor/updater/shorebird_code_push` — the same depth as the existing
  `../../../packages/code_push_runtime` precedent. Note pub writes
  `dependency: "direct overridden"` **and** `source: path` for an overridden
  entry, so the order's check ("`shows source: path`") is the reliable half.

## Status effect

**No §8 row moves.** All six stay **NOT VALIDATED**, and the KNOWN GAP stays a
KNOWN GAP with a corrected cause. Nothing here earns BUILT: no fixture was
created, and the arm the order proposed would not have earned it either.
