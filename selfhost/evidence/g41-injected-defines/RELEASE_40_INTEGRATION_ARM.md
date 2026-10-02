<!-- cspell:words rmtree killswitch -->
# Release 40 — the G4.1c INTEGRATION REGRESSION arm

**This arm proves that the G4.1c CLI still traverses the real iOS release → patch
path. It proves NOTHING about injected defines**, and the ceiling was written
down before the run (`DECLARES.md`, and the `R6` claim row) rather than chosen
after seeing a green result.

`airgap_app` reads none of the six injected defines, so its prepass and import
kernels are byte-identical with and without them. A green release here cannot
observe the fix. The discriminating evidence remains
`probes/g41c_injected_defines.sh` arm 1, host-side.

## Identity

| fact | value |
|---|---|
| rig CLI | `ba4e1c02` → **`50ed19a7`**, re-synced by this lane. CLI-equivalent to `72620b12`: `git log 72620b12..HEAD -- packages/` is EMPTY |
| snapshot check | rebuilt snapshot contains `flutter_injected_defines` and the G4.1c warning string |
| engine cell | `40eaa0ef6cb6485833bf2e10ac97224ca82cbf25` — the PROVEN lineage |
| pinned Flutter | `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (3.44.8 / Dart 3.12.2) |
| fixture | `selfhost/fixtures/airgap_app` **UNMODIFIED**; only `pubspec.yaml`'s version moved 39 → 40 |
| control plane | `cps-ios`, app `5c405fd6-3c34-2cb7-86e0-1291b9af666c` |
| result | **release 95 = `40.0.0+1`, ios active** · **patch 1 published**, stable, arm64 797 B |

## The stamp guard, both sides

G15 held this rig for gate 2 and restamped `engine.version` between two cells.
Its restore was **verified independently before claiming**, not taken from the
row, and re-verified after:

| moment | `engine.version` | cached `ios-release` `__TEXT,__text` |
|---|---|---|
| before re-sync | `40eaa0ef…` | `bc0afffe` |
| after release 40 + patch 1 | `40eaa0ef…` | `bc0afffe` |

`bc0afffe` is cell `40eaa0ef`'s signature; `136e3d64` would have been G15's
`80e493e4`. **Compare the `__text` section, never the file hash** — an embedded
or cached `Flutter` is re-signed and thinned, so file hashes never match the
published xcframework. That method is G15's and is recorded here because it is
the non-obvious half.

## What the release actually recorded

From the release's own `route_b.json`, captured before the patch build cleared
`build/`:

```
engineRevision            40eaa0ef6cb6485833bf2e10ac97224ca82cbf25
flutterRevision           c15ef6379403a0a55531a058bdb2c8e55bc05c98
patchableCallSites        7156   (1778.4 /MiB)
artifacts                 release_app.dill, dynamic_interface.yaml,
                          route_b_retention.json, route_b_capabilities.json,
                          release_import.dill
buildConfig.effectiveDefines  {}
```

### THE CANONICAL STATEMENT OF WHAT THIS ARM ESTABLISHES

Quote this rather than paraphrasing it:

> **The release-time agreement check passed with the injected Flutter defines
> threaded into the prepass/import-kernel path, `release_import.dill` was
> retained, and the patch subsequently bound against that import kernel without
> refusal.**

**The build-config fingerprint is a separate and WEAKER fact, and must not be
folded into the sentence above.** It compared an empty user-define set against an
empty user-define set. It therefore did **not** validate the injected defines —
it could not, because they are deliberately outside the fingerprint (§4 of
`DECLARES.md`). An earlier draft of this file said the "release/patch
compatibility check accepted the threaded configuration", which reads as though
that check examined the threading. It cannot, and that phrasing is retracted
here rather than edited away, because a reader who acted on it would look for a
guarantee in the wrong mechanism.

### Three signals that ARE real, stated narrowly

1. **The new pre-prepass step ran and returned a usable map.** `_declareRetention`
   returns early with a named warning when Flutter's answer cannot be read, and
   that path produces **no** interface, **no** `route_b_retention.json` and **no**
   import kernel. All three are present, so `_resolveInjectedDefines` succeeded on
   a real build against a real project.
2. **The post-build re-read AGREED with the pre-build read.** A disagreement sets
   `buildConfig: null` and captures no Route B artifacts.
   `buildConfig` is populated and all five artifacts are present, so
   `_injectedDefineDisagreement()` exercised on a real build and found none. This
   is the "checked rather than trusted" property actually running, not asserted.
3. **`release_import.dill` was captured, so `agreesWith` PASSED.** The import
   kernel — now compiled WITH the injected defines — still agreed with the prepass.
   A disagreement deletes the import kernel and omits it from `artifacts`. So the
   threading did not break the guard that would have caught it breaking.

### And one that is NOT a defect

`buildConfig.effectiveDefines` is `{}`. That is **correct and designed**: the
fixture supplies no `--dart-define`, and the six injected defines are
deliberately **not** in the fingerprint. A release and a patch on one pinned cell
resolve them identically, so an entry could only compare a constant with itself.
See `DECLARES.md` §4. Anyone reading `{}` as "the defines did not reach the
build" has the wrong artifact — the defines reach `gen_kernel`, not the
fingerprint.

## Cell audit: exactly one finding, recorded not suppressed

`audit_route_b_compiler.sh --hash 40eaa0ef…` — 16 checks pass, **1 finding**:

```
FINDING: PLATFORM DILL SPLIT: address computed over 9f5a5f754a93dd8e…,
builds download 55e02ed8cfe9fa2d… — a dart:ui/dart:_internal change in the
engine's tree does NOT reach apps built on this cell
```

**This is the check working, and it was predicted before the run.** It is G15's
check 4b (`82e455c8`), which closed a hole where check 3 compared the bundle only
against its own `PROVENANCE.txt` — self-consistency rather than agreement with
what a build downloads. Every pre-repair cell reports it.

**Release 40 therefore carries a known-open provenance defect**, and that is
stated rather than routed around: the dill its cell address certifies is not the
dill its build downloaded. G15 has since measured that the platform dill is
**dm-invariant** in `R3` (dm, nodm and `ios_release` all produce `9f5a5f75` x8),
so the repair needs no new engine build — one variable in
`publish_ios_overlay.sh` plus a mint. Nothing is minted yet, so this cell is
byte-unchanged and the finding is expected to persist until that lands.

## Notes for whoever runs the next arm

* **The auth incantation is required.** The vendored CLI cannot refresh a
  self-hosted credential — it POSTs to `https://auth.shorebird.dev/token` and
  401s. `AUTH_SERVICE_URL` is honoured as far back as `ba4e1c02`
  (`shorebird_env.dart:263`, upstream is only the fallback):

  ```sh
  export FLUTTER_STORAGE_BASE_URL=http://localhost:8085
  export SHOREBIRD_STORAGE_BASE_URL=http://localhost:8085
  export SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev
  export SHOREBIRD_JWT_ISSUER=http://169.254.189.3:18080
  export AUTH_SERVICE_URL=http://10.0.0.7:18080
  ```

  The issuer and the auth URL name **different addresses of the same server**
  (`169.254.189.3` vs `10.0.0.7`) and the refresh still redeems. Found by G15;
  recorded in `evidence/g15/gate2_verdict.txt`.
* **The patch's App Store IPA export fails** with `No Accounts` / `no profiles`,
  because the release was cut `--export-method development`. It is not fatal: the
  patch verified against the release artifact and published anyway. Do not read
  it as a patch failure.
* **`shorebird patch` rebuilds `build/`**, which clears the release's
  `build/ios/shorebird/route_b.json`. Capture it BEFORE patching or it is gone.
* **If any check comes up blank, reinstall from the stored artifact before
  concluding anything about the binary.** G15 measured a device failure
  (`1.0.3+1`) that did **not** reproduce from the stored artifact; the surviving
  candidate was `ios-deploy --rmtree` followed by relaunching the same install
  without reinstalling.
* **No device was involved.** Nothing here says the patch applies or executes.

## Two living debts this arm created or exposed — both SHARED, not this lane's

**1. Cross-release semantic drift.** Releases **≤ 95** and every release cut after
them differ in whether Flutter's injected defines participate in Route B
analysis. That difference is invisible in the fingerprint, produces no warning,
and no artifact records which side of the line a release falls on — the CLI
revision that built it is not in `route_b.json`. Any arm that compares a new
release against an older one therefore has **two variables, and the CLI is the
silent one.** G15 has already recorded that it will re-cut gate 4's baseline
rather than reuse `killswitch_probe 1.0.5+1` for exactly this reason. Anyone
comparing across that boundary owes the same.

**2. Rig CLI provenance and ownership.** The exact `~/.shorebird` snapshot has now
been load-bearing in two different lanes within one session — G4.1c needed it
re-synced to exercise its own change, and G15's gate 2 was blocked by an auth
defect that only the re-sync (or `AUTH_SERVICE_URL`) clears. **"What CLI is
installed, who owns it, and when it may be re-synced" is shared experimental
state, not incidental tooling**, and should be claimed and released like the
engine stamp already is. The `~/.shorebird` row covers the stamp well; it now
also has to carry the CLI revision, which is why this lane recorded
`ba4e1c02 → 50ed19a7` in it rather than treating the re-sync as housekeeping.

## What is still owed for an upgrade from BUILT

A **discriminating** iOS fixture whose *reachable* program consumes one of the
six injected defines observably — reachable being load-bearing, since retention
is not reachability and a dead-code `String.fromEnvironment` read proves nothing.
Until then G4.1c stays **BUILT**, with this arm recorded as integration
regression only.
