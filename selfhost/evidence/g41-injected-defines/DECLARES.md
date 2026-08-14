# Route B analyzes the program Flutter ships, not an approximation of it

**Host result. Earns BUILT, never PROVEN** — no device, no release, no control
plane was involved, and none is claimed.

## Identity

| fact | value |
|---|---|
| repo commit at work | `eeaed601` (shared tree, branch `feat/engine-improvements`) |
| pinned Flutter | `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (3.44.8 / Dart 3.12.2) |
| Route B cell | `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` |
| fixture | a **fresh `flutter create` app** in a temp dir — no committed fixture was read or written |
| mirror | `FLUTTER_STORAGE_BASE_URL=http://localhost:8085`, read-only use of `R11` |
| rig CLI (`~/.shorebird`) | **NOT re-synced.** Nothing here was exercised through the rig |

## 1. The measurement: which defines, and is each semantic

Flutter appends defines *after* parsing the command line
(`flutter_command.dart:1519-1520`), from two functions that read **only**
`globals.flutterVersion` and `featureFlags` — never a build argument. Measured on
a clean `flutter create` app with **no flavor and no `--dart-define` at all**:

| define | value on this cell | semantic? |
|---|---|---|
| `FLUTTER_VERSION` | `3.44.8` | **yes** — arm 1 below branches on it |
| `FLUTTER_CHANNEL` | `[user-branch]` | **yes** — `String.fromEnvironment` reads it |
| `FLUTTER_GIT_URL` | `unknown source` | **yes** |
| `FLUTTER_FRAMEWORK_REVISION` | `c15ef63794` | **yes** |
| `FLUTTER_ENGINE_REVISION` | `11e5695710` | **yes** |
| `FLUTTER_DART_VERSION` | `3.12.2` | **yes** |
| `FLUTTER_ENABLED_FEATURE_FLAGS` | *absent* | **yes when present** — omitted entirely when empty |

**None is safe to omit.** Each is an ordinary compile-time environment entry that
`const String.fromEnvironment` reads; "build metadata" describes their *origin*,
not their *effect*. What is true is that they are **constant for a pinned cell**,
which is a fingerprint argument, not a semantics one — see §4.

**The scope in `PARITY.md:2051` was too narrow and is corrected here.** That row
called this a thing that "bites where a program branches on one of those values,
which is rarer than branching on a flavor", framed alongside the flavored
fixture. The divergence is present on **every iOS release**, flavored or not,
define-free or not: six defines, on an app that supplied none.

## 2. The Route B side, and the diff

`RouteBReleaseKernelBuilder.forwardedArgs` forwarded `--dart-define=` and
`--enable-experiment=` only. For the app above that is the **empty list**, so the
diff against the release is all six.

Three kernels were affected, which is why the fix threads all three:

| kernel | what it decides | was compiled with |
|---|---|---|
| prepass (`--aot`) | RETENTION — what a future patch may name | none of the six |
| early import (`--no-aot`) | the PRIVATE-ENUMERATION source | none of the six |
| supplement import | what a patch BINDS against | none of the six |

## 3. The probe: `g41c_injected_defines.sh` — 5/5

Full run: `g41c_probe_run.txt`.

**The first version of this probe produced a FALSE PASS, and its own instrument
control caught it.** It diffed the generated dynamic interface and reported the
two arms as different — but Route B's interface is *whole-library* for app
libraries, so it names no individual function, and the only line that differed
was the `# Source dill:` path comment. Symbol names are no better: they survive
in the kernel's string table whether or not the body is reachable, so
`strings | grep` finds all four markers in every arm. Both wrong instruments are
recorded in the script's header so the next reader does not re-derive them.

The observable that answers the question is **`route_b_analyze.aot`** — Route B's
own coverage analyzer, the component whose job is classifying one kernel against
another:

```
arm 0  INSTRUMENT CONTROL   routeb  vs routeb    -> NONE                          (it CAN report no change)
arm 3  DETERMINISM CONTROL  shipped vs shipped2  -> NONE                          (not nondeterminism)
arm 2  POSITIVE CONTROL     routeb  vs user      -> package:probeapp/main.dart#main
arm 1  THE FINDING          routeb  vs shipped   -> package:probeapp/main.dart#main
```

Arm 2 is what makes arm 1 mean something: an **ordinary user define**, which
Route B has always forwarded, produces the **identical** verdict. So the finding
is not an exotic failure mode — it is the same divergence Route B already
forwards defines to prevent, on a family of keys it was not forwarding.

## 4. The seam, and why it is not a reconstruction

**Chosen: Flutter's own resolved `DART_DEFINES`, read from
`ios/Flutter/Generated.xcconfig`, obtained before the prepass by a
`flutter build ios --config-only` pass** — the same source, decoder and cheapness
argument the `--dart-define-from-file` expansion is already checked against
(`configOnly` early-returns at `ios/mac.dart:375`, *after*
`updateGeneratedXcodeProperties` at `:347`).

**Reconstructing the values was rejected on measurement, not on taste.** Each of
the six has a trap that yields a plausible wrong answer:

* **`FLUTTER_ENGINE_REVISION` is not this release's engine.** It comes from
  `bin/cache/engine_stamp.json` `git_revision` (`version.dart:681`), which on
  this cell reads **`11e5695710`** while Shorebird's own `engine.version` reads
  **`40eaa0ef`**. Anything deriving it from
  `shorebirdEnv.shorebirdEngineRevision` would be silently, confidently wrong.
* **`FLUTTER_FRAMEWORK_REVISION` is truncated to 10 characters**
  (`version.dart:959`), not the full SHA.
* **`FLUTTER_GIT_URL` interpolates a nullable getter.** A checkout with no
  tracking remote ships the literal string `"null"` (`:1576`), while
  `flutter --version --machine` reports `unknown source` for the same state
  (`:281`). **The two sources disagree by construction** — which is why
  `--version --machine`, the other candidate seam, was rejected: it is a
  reconstruction with a known divergence.
* **`FLUTTER_ENABLED_FEATURE_FLAGS` depends on `flutter config` state** on the
  building machine, and vanishes entirely when empty. `--version --machine` does
  not report it at all.

**And the read is CHECKED rather than trusted**, which is the property that makes
the pre-build timing safe. The map is read before the prepass; the real build
rewrites the same file; `_injectedDefineDisagreement()` re-reads it afterwards
and compares. A disagreement declines patchability — no Route B artifacts,
`buildConfig: null` — exactly where this option class already lands. A wrong read
costs patchability and can never produce a wrong patch.

**Unreadable is not empty.** If Flutter's answer cannot be read, `_declareRetention`
returns with a named warning and the release declares **no** retention. Compiling
the prepass with an empty injected set is precisely the bug being closed; doing
it silently would be worse than the bug.

**`FLUTTER_APP_FLAVOR` is excluded, deliberately.** Flutter rewrites it at the
xcodebuild stage from the Xcode CONFIGURATION, so the xcconfig holds the CLI
token (`foo`) while the shipped kernel holds the scheme's casing (`Foo`) —
measured on `flavored_app`. Reading it here would reintroduce the casing
divergence `f06fa056` closed. It keeps its own threading and is appended last.

### Fingerprint and provenance: unchanged, and why

The six are **not** added to `RouteBBuildConfig`. A release and a patch on one
pinned cell resolve them identically by construction — same Flutter revision,
same engine stamp, same machine config — so a fingerprint entry could never
differ, would compare a constant against itself, and would make every release
recorded before this change incomparable for no gain. `analysisVersion` stays
**8**; no producer or analyzer file was touched.

## 5. Tests: 2504 passed / 1 skipped / 0 failed

`dart analyze --fatal-warnings lib test` → **exit 0**, zero errors, zero
warnings. `dart format --set-exit-if-changed .` → 358 files, 0 changed.

**Two negative controls, both confirmed RED in their final form:**

| control | reverted | result |
|---|---|---|
| threading into the kernels | drop `injectedDefines` from `forwardedArgs`' emitted list | **4 red** in `route_b_release_kernels_test.dart` |
| threading at the releaser | drop `injectedDefines: _injectedDefines` from all 3 call sites | **1 red** — `threads the defines FLUTTER injected into EVERY kernel` |
| the decline guard | force the `_injectedDefines == null` branch off | **1 red** — `declines retention when Flutter's answer cannot be read` |

**And the controls stayed GREEN in both states**, which is what keeps the
assertions from being vacuous:

* `emits nothing extra when no injected map is supplied` — without it, the
  positive test would pass equally against an implementation that emitted a
  hard-coded `FLUTTER_*` list, i.e. against the reconstruction this seam refuses.
* `leaves an ordinary user define untouched by the injected set` — the brief's
  required control: a user's `--dart-define` is carried identically with and
  without the injected map.
* `carries the injected defines into the IMPORT kernel` asserts the negative half
  in the same test (the same call **without** the map must not carry it), so the
  assertion cannot pass by accident.

## Limits, named rather than implied

* **iOS only.** The seam reads `ios/Flutter/Generated.xcconfig`. Flutter hands
  Android's resolved defines to Gradle as `-Pdart-defines` and writes them to no
  file. Route B's kernels are built by `ios_releaser` only, so nothing is
  currently wrong on Android — but a future Android Route B would need its own
  source for this.
* **No release was cut.** This earns **BUILT**, not PROVEN. What is owed is a
  Route B iOS release built with this CLI and a matching patch against it,
  confirming `route_b.json` records the same injected set the build used.
* **The `--config-only` pass writes `Generated.xcconfig` before the real build.**
  The real build rewrites it. If a release aborts between the two, the file is
  left without the user's own defines until the next `flutter build` — a
  recoverable side effect on a generated, gitignored file, stated rather than
  discovered later.
* **`FLUTTER_ENABLED_FEATURE_FLAGS` was absent on this machine**, so its
  threading is exercised by unit test only, never by the probe.
