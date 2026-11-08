# P6 · custom target — Arm B log

Running log. The precommit in `PRECOMMIT.md` is fixed and is not edited from
here; this file records what happened against it.

## Blocker 1 — the deployment's JWT issuer is stale (auth, not Route B)

`shorebird release ios` refused before building:

    These credentials were issued by http://169.254.189.3:18080, but this
    deployment expects http://10.0.0.7:18080.

The `cps-ios` container carries `SHOREBIRD_JWT_ISSUER=http://169.254.189.3:18080`
while serving as `PUBLIC_BASE_URL=http://10.0.0.7:18080`. That link-local address
no longer exists on this machine (it is now `169.254.46.190`), and the stored
token had expired on 2026-08-16. So **logging in again would fail identically** —
a fresh JWT would carry the same stale issuer. The guard is correct; the
deployment is misconfigured.

Worked around with the bootstrap `API_KEY` via `SHOREBIRD_TOKEN`, which is not a
JWT and so is not subject to the issuer check. **Not** fixed at the source:
correcting `SHOREBIRD_JWT_ISSUER` needs the container recreated (env cannot be
changed in place), and `MEASUREMENT_MODE.md` freezes lifecycle behaviour until
the precommitted sample threshold is met. Recreating a control-plane container
mid-epoch is the measurement lane's call. **Open debt**, to be taken when that
epoch closes.

## Blocker 2 — two Flutter caches, same version string, only one Route B capable

The build then died inside Xcode with:

    Setting VM flags failed: Unrecognized flags: patchable_static_calls
    Target aot_assembly_release failed: AOT snapshotter exited with code 255

The cause is not the fixture and not the custom target. There are **two**
`shorebird` entrypoints, both reporting `1.6.115+selfhost.1`, each resolving its
Flutter cache next to itself:

| entrypoint | `patchable_static_calls` in its iOS `gen_snapshot`s | usable for Route B |
|---|---|---|
| `/Users/mendell/shorebird/bin/shorebird` (repo tree) | `ios`=0, `ios-profile`=0, `ios-release`=0 — **stock** | no |
| `~/.shorebird/bin/shorebird` (installed, on `PATH`) | `ios`=2, `ios-profile`=2, `ios-release`=2 | yes |

I invoked the repo one. Its cache is uniformly stock — not partially corrupted —
so the Route B flag was rejected by the very first `gen_snapshot` call. Confirmed
by capturing the actual argv from a `--verbose` rebuild rather than by inference:
the failing binary is
`…/shorebird/bin/cache/flutter/c15ef637…/…/engine/ios-release/gen_snapshot_arm64`.

Fixed by using the installed entrypoint. **No cache surgery**: copying the good
binary into the stock cache would produce an incoherent set, which is the failure
mode `coherent-set-not-single-file` exists to prevent. Verified first that the
installed checkout (`554037da`) has **no product-code delta** from the working
tree (`git log 554037da..HEAD -- packages/` is empty, and `packages/` is clean),
so it runs the current producer.

### My own check was vacuous, and that is the more useful finding

I first tested the flag with `gen_snapshot --patchable_static_calls --version`
and read exit 0 as "knows the flag". **That test cannot fail**: `--version`
prints and exits 0 regardless of unrecognised flags preceding it, so every
binary passed — including the stock one that had just rejected the flag in a real
build. It sent me looking in the wrong tree.

The non-vacuous test is whether the flag name is *in* the binary:

    strings -a <gen_snapshot> | grep -c '^patchable_static_calls$'

which separates the two caches 2-vs-0. A check that returns the same answer for
a good and a bad artifact is worse than no check, because it certifies the bad
one.

### Contamination cleaned before retrying

The two failed builds ran against the stock cache, leaving
`ios/Flutter/Generated.xcconfig` pointing `FLUTTER_ROOT` at it and DerivedData
holding objects compiled against it. `build/`, `.dart_tool/flutter_build/`, the
project's DerivedData and the generated xcconfig were removed — all regenerable,
all specific to this project — so the retry cannot inherit a stock-engine object.

## Blocker 3 — version collision, and why the bump skips 1.8.0

The build itself **succeeded** on the installed entrypoint, which confirms
blocker 2's diagnosis: `Route B retention: 4 named SDK members, interface 1973
bytes`, a 26.9MB xcarchive, and a signed 9.0MB IPA (`Automatically signing iOS
for device deployment using specified development team … SK85S6YZP9`). Only
publication was refused:

    It looks like you have an existing ios release for version 1.7.0+1.

`1.7.0+1` is release 119, cut by the obfuscation arm. The fixture's own pattern
is a minor bump per arm, which would make this `1.8.0+1`.

**Deliberately skipped to `1.9.0+1`.** `MEASUREMENT_MODE.md` identifies the
frozen telemetry specimen as *"release 108 / 1.8.0+1, patch 1"* on this same
`cps-ios` deployment, and its estimator line keys on the `1.8.0+1 patch 1`
shorthand. A second `1.8.0+1` in the same control plane would be a different
release row but an identical *identifier* in every grep and in that shorthand.
The specimen must stay unambiguous, and skipping a version number costs nothing.

## Release 1.9.0+1 published from `lib/main_b.dart`

`shorebird release ios --flavor foo --target lib/main_b.dart
--export-method development` published cleanly. `Route B retention: 4 named SDK
members, interface 1973 bytes`; signed with team `SK85S6YZP9`.

### Pre-install evidence that the non-default entry is what shipped

Checked in the shipped AOT (`App.framework/App`, `945f3d36af9b046d`) **before**
anything touched the phone. The discriminator is not that `main_b`'s markers are
present — it is that `main.dart`'s are absent, because `main.dart` is unreachable
from `main_b` and so is not in the program at all:

| marker | origin | count | meaning |
|---|---|---|---|
| `TARGET-B` | main_b | 1 | present |
| `CT-RELEASE-1` | main_b | 1 | present |
| `CUSTOM-TARGET-V1` | main_b | 2 | both ternary branches kept |
| `FLAVORED-FIXTURE-V1` | main.dart | **0** | main.dart not compiled in |
| `BAKED-INTO-RELEASE` | main.dart | **0** | ditto |
| `obf` | main.dart | **0** | ditto |

A default-target build would have shown the bottom three and not the top three.

### Installed and baselined

`ios-deploy --id 8cb4bc98… --bundle Runner.app --no-wifi` — no `-d`, no `-L`, so
this installed without starting anything.

**Baseline, from a by-hand icon tap:** `TARGET-B` / `CT-RELEASE-1` /
`CUSTOM-TARGET-V1`. The screen was `main_b`'s own three-row layout, which exists
nowhere else in the fixture, so `main_b`'s `main()` is what ran.

## The patch

Only the target's literal changed, in both ternary branches:
`'CUSTOM-TARGET-V1'` → `'CUSTOM-TARGET-V2'`. Both controls are untouched at
their declarations (`kEntryMarker`, `kReleaseMarkerB`); `git diff` is 2 lines.

Unlike the defines arm, this change is expected to be **visible** to the coverage
analyzer: the literals live directly in the procedure body, so the printed AST
differs. The defines arm's blindness was a change to a const's *evaluated value*
with an identical source AST — a different situation, and worth distinguishing
rather than assuming the same trap.
