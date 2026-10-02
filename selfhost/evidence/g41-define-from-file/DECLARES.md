# `--dart-define-from-file` — supported rather than declined

**Host result. Earns BUILT, never PROVEN** — no device, no release, no control
plane was involved, and none is claimed.

## Identity

| fact | value |
|---|---|
| repo commit at work | `b3b5b6a4` (worktree `/Users/mendell/shorebird-define-from-file`, detached) |
| pinned Flutter | `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (3.44.8) |
| engine stamp during the run | `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`, unchanged after (probe arm 7) |
| fixture | `selfhost/fixtures/flavored_app`, **copied**; the committed tree was read only |
| mirror | `FLUTTER_STORAGE_BASE_URL=http://localhost:8085`, read-only use of `R11` |
| rig CLI (`~/.shorebird`) | **NOT re-synced.** Nothing here was exercised through the rig |

## What was closed

`--dart-define-from-file` made a release **unfingerprintable and unpatchable**.
Two separate nulls did it, and both are now gone:

| site | before | after |
|---|---|---|
| `route_b_release_kernels.dart` `forwardedArgs` | null → no prepass, no import kernel → **the release could not be patched at all** | forwards the expanded defines |
| `route_b_build_config.dart` `fromBuildArgs` | null → `buildConfig: null` → the patch side declined by name | fingerprints the expanded set |

The recorded objection was that expanding the option means reimplementing
Flutter's `.json`/`.env` parsing, which is hand-reconstruction. That objection is
**about trust, not about parsing**, and it is answerable: Flutter writes its own
resolved answer to `ios/Flutter/Generated.xcconfig` as `DART_DEFINES` (base64
`K=V` — `build_info.dart:396` via `ios/xcode_build_settings.dart:265`). So the
port is CHECKED rather than believed:

* `probes/g41b_define_from_file.sh` compares the expansion against Flutter's own
  resolution on a real fixture, per arm;
* `ios_releaser._defineExpansionDisagreement` runs the same comparison on the
  user's real build, and **declines exactly as before when the two disagree** —
  no Route B artifacts and `buildConfig: null`. A wrong expansion costs
  patchability; it can never produce a wrong patch.

`flutter build ios --config-only` is what makes the probe cheap: the `configOnly`
early return is at `ios/mac.dart:375`, **after** `updateGeneratedXcodeProperties`
at `:347`, so the toolchain can be asked in seconds without building anything.

## Probe: `g41b_define_from_file.sh` — 18/18

Full run: `g41b_probe_run.txt`. The two arms that decide whether the other six
mean anything:

* **arm 0, instrument control** — a `--dart-define` whose value the harness chose
  must come back out of the xcconfig. **It fired on the first run**: without
  `FLUTTER_STORAGE_BASE_URL` the pinned Flutter asked `download.shorebird.dev`
  for `engine_stamp.json` at revision `40eaa0ef` and took a 404. That is a
  configuration mistake, and without arm 0 it would have surfaced as six arms
  reporting "no defines agree with no defines".
* **arm 5, sabotage** — the JSON file is rewritten after Flutter has read it, so
  the two answers genuinely differ. The comparator reports `API_URL`. Had it
  reported `agree`, every PASS above it would have been worthless.

Arms 1–4 are the substance: JSON non-string values (`7`, `true`, `{"b":1}` reach
the compiler as `7`, `true`, `{b: 1}`), `.env` quoting (a `#` inside quotes
survives; after an unquoted value it does not), `--dart-define` winning over a
file entry with the same key, and later files winning per key across two files.
Arm 6 holds the line that a missing file still declines. Arm 7 asserts the shared
Flutter cache's `engine.stamp` is where it was, because the mirror's fallback has
restamped a cache mid-build before (PARITY.md:1595-1612).

## Tests: 2486 passed / 2 skipped / 0 failed

`dart test` on `packages/shorebird_cli`; `dart analyze --fatal-warnings lib test`
clean; `dart format --set-exit-if-changed` clean.

**The new tests were confirmed RED against a reverted implementation**, not
assumed to be discriminating: putting `--dart-define-from-file` back into both
option lists fails 4 of them —

```
--dart-define-from-file a file that EXISTS is now fingerprinted, not declined
--dart-define-from-file both spellings of the option are expanded
--dart-define-from-file --dart-define wins over a file entry with the same key
--dart-define-from-file two configurations differing only inside the file disagree
```

**And the control stayed green in both states.** `a MISSING file still yields
null` passes before and after, which is the point of separating it: *the
previous test in this position asserted exactly that and nothing more.* It named
a file (`x.env`) that was never created, so it would have kept passing against an
implementation that had reverted — it read as "the option is declined" while
actually testing "a missing file is declined". Every new assertion about support
writes a real file to disk.

## Two findings this produced, neither of them fixed here

**1. `FLUTTER_APP_FLAVOR` is exempt from the comparison, on measurement.** The
xcconfig carries the CLI token (`foo`) while the shipped kernel carries the Xcode
scheme's casing (`Foo`) — Flutter rewrites the define at the xcodebuild stage
from the CONFIGURATION. The flavor has its own threading (`xcodeBuild.flavorScheme`)
and its own probe; exempting it here is a stated decision, tested in
`dart_define_from_file_test.dart`, not a silently skipped key.

**2. Flutter injects defines that Route B's kernels never receive.** The same
`DART_DEFINES` line carries `FLUTTER_VERSION`, `FLUTTER_CHANNEL`,
`FLUTTER_GIT_URL`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION` and
`FLUTTER_DART_VERSION` (`flutter_command.dart` `_addFlutterVersionToDartDefines`,
plus `_addFeatureFlagsToDartDefines` for `kEnabledFeatureFlags`). `forwardedArgs`
forwards only `--dart-define=` and `--enable-experiment=`, so **the prepass and
import kernels are compiled without them while the shipped kernel has them.**
That is the same *different-program* class as the flavor casing divergence that
`6ae04dc7`/`f06fa056` closed, and it is measured here rather than argued:

```
$ base64 -d <<< RkxVVFRFUl9WRVJTSU9OPTMuNDQuOA==
FLUTTER_VERSION=3.44.8
```

Scope, honestly: it bites where a program branches on one of those values
(`const String.fromEnvironment('FLUTTER_VERSION')`), which is rarer than
branching on a flavor. It is **not demonstrated to break any app**. What IS
demonstrated is that the two kernels disagree. Fixing it means deciding whether
those keys belong in the fingerprint as well as in the kernels — a release and a
patch on one pinned cell would always agree, so the cost is low and the decision
is still a decision. Left for its own lane.

## Limit, named rather than implied

The cross-check is **iOS only**. Flutter hands Android's resolved define set to
Gradle as a `-Pdart-defines` argument and writes it to no file, so the Android
fingerprint uses the expansion unverified. Release and patch run the same
expansion, so a difference between them is still detected; what is not detected
is a port error mapping two genuinely different files to the same defines on both
sides. Recorded in `releaser.dart`'s `recordEffectiveBuildConfig` doc.
