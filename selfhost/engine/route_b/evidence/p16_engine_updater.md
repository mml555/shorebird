# P16: what the pinned engine's updater does (read from source)

Read-only, from the engine checkout at `~/shorebird-engine/flutter/engine/src`
(shorebird-flutter HEAD `d0714887dd95d2990e0185fe1893523f3d600cc5`, the
`engine_revision` in `selfhost/compatibility.yaml`). Nothing was built and no
device was touched. `selfhost/ci/engine_updater_evidence_guard.sh` re-checks the
load-bearing facts below from source text. "Engine tree" paths are relative to
`flutter/engine/src/flutter/`.

## 1. Which updater the engine builds

- `DEPS` (`~/shorebird-engine/flutter/DEPS:22-23, 518-519`) pins
  `mml555/shorebird-updater-mirror` at `87c198d30f875a3da317d70935e1025dc13064dd`
  into `engine/src/flutter/third_party/updater`. That checkout's HEAD is that SHA.
- Crate: `third_party/updater/library` (workspace with `library_test_hooks`,
  `patch`).
- `selfhost/compatibility.yaml` `updater_revision: 87c198d30f87` is the 12-char
  form of the same SHA. They agree.
- `vendor/updater` (`VENDOR.md`: "Source revision 87c198d30f87...") differs from
  the engine's copy only in the mirror#11 bounded diagnostic logs
  (`library/src/diag_log.rs`, and the `diag_log::append` calls in `updater.rs`
  and `cache/updater_state.rs`, plus `http.rs`, `lib.rs`, `.cargo/config.toml`,
  `library_test_hooks`). `cache/lifecycle.rs` and the rest of `cache/` are
  identical. `VENDOR.md` already says this ("Ahead of that revision by one
  change"). So CI's Rust tests on `vendor/updater` exercise the same verification
  and lifecycle code the engine ships. This is source identity, not a build
  identity: nothing here proves the shipped binary was built from that checkout.

## 2. Does it verify the patch signature at download time?

Yes, in every verification mode, before any download state or network call.
`third_party/updater/library/src/updater.rs`, `download_and_install_patch`:
`crate::cache::check_patch_signature(&patch.hash, patch.hash_signature, config.patch_public_key)`
at lines 1119-1123. On failure it calls `record_signature_refused` (tombstones
the pair) and returns `UpdateError::InvalidSignature` (lines 1124-1137). Only
after that does it call `record_download_started` (about line 1160) and
`download_to_path`. The signature covers `patch.hash`; the post-inflate hash
check then ties the installed bytes to that hash. `vendor/updater` has the same
call site at the same lines.

The default `patch_verification` of this updater is `install_only`
(`yaml.rs`), which re-verifies nothing on boot; `strict` also re-verifies the
installed artifact each boot. When the app embeds no `patch_public_key`,
`check_patch_signature` has nothing to check against. The engine refuses to
start the updater when a key is configured but no verifier is registered
(`updater.rs:464, 488-491`, `InitError::NoSignatureVerifier`).

Consequence for the CLI: its stated reason for refusing `install_only` on
self-hosted releases (signing G4) is stale for this engine. Whether to drop
that refusal is a CLI change, not made here.

## 3. iOS Route B patch whose build id does not match the release

The patch is refused, marked Bad, and not retried.

Trace (engine tree):

1. `shell/common/shorebird/shorebird.cc` `ConfigureShorebird` calls
   `Updater::PrepareNextBootPatch()`, which selects the patch and records it as
   the booting patch (the start is recorded there, not in
   `runtime/dart_snapshot.cc:160-165`, which skips it under `SHOREBIRD_ROUTE_B`).
2. `ApplyPatchToSettings` sniffs the file; a Route B container arms
   `InstallRouteBActivationHook` (about lines 640-690).
3. In the `root_isolate_create_callback` (before `main`), the hook reads
   `Dart_RouteBReleaseBuildId()` (line 398). A null id is refused. Then
   `running_id != container.release_build_id` (line 410) reports
   `REFUSED (wrong-release)` and calls `ReportRefusal()` (lines 414-420), which
   is `Updater::Instance().ReportLaunchFailure()` (lambda at line 359-361), then
   returns without activating anything. The app boots on the release's AOT code.
4. `shell/common/updater.cc:167-174` `ReportLaunchFailure` takes the
   once-per-process latch and calls `shorebird_report_launch_failure()`. That is
   `third_party/updater/library/src/updater.rs:1825-1856`:
   `record_boot_failure_for_patch` then `lifecycle.rs:832-843` `record_boot_failure`
   -> `mark_bad(n, BadReason::BootCrash)`, clears the boot breadcrumb and attempt
   tally, and `recompute_next_boot` (falls back to the last good patch or the
   base). It queues a `PatchInstallFailure` event ("engine_report: patch N failed
   to launch").
5. The success that Dart reports later (`lib/ui/hooks.dart` on `main` completion
   or first frame, `_reportLaunchSuccess`) is dropped because failure already
   took the same latch (`updater.cc:107-114`). Hence the patch is not credited.

So: marked Bad (`Bad{BootCrash}`, a misleading reason name for a refusal),
`ReportLaunchFailure` is called, and it is not retried on every boot. The other
refusals (malformed, unsupported version, no identity, partial apply) take the
same path. The one exception is an unreadable artifact, which abstains
(`AbstainFromLaunchReport`) and is bounded by the boot-attempt threshold (2).

Host evidence already in the updater: `updater.rs:2971`
`prod_c2_explicit_failure_retires_immediately` (explicit failure retires on the
first strike) and `lifecycle.rs:2119`
`record_boot_failure_marks_bad_and_recomputes_next_boot`.

Not covered by any test I found: the C++ hook's wrong-release branch itself.
`shell/common/shorebird/route_b_patch_unittests.cc:192-200` only asserts that the
parser hands over `release_build_id`; nothing runs the hook against a mismatched
id and checks `ReportLaunchFailure`. A test needs an engine build (gtest in
`shorebird_unittests.cc` with `MockUpdater`), so it is described in the PR, not
added.

Not settled by source: that the device receives the patch at all. The offer is
keyed on `release_version`, so a same-version re-cut with a different binary
reaches this check (audit Signing G5/Distribution G11). Also that a real device
run produces this log sequence; that needs the owner's iOS device.

## 4. Android pin: where launch success fires, and a crash before it

The Android engine is not a Route B engine. `SHOREBIRD_ROUTE_B` comes from the
gn arg `shorebird_route_b` (`common/config.gni:53, 118-123`, default false);
`selfhost/STATUS.md` says only the iOS release engine is built with it on. I did
not find an Android build recipe that sets it. Confirm in the build args of the
published Android artifacts if that matters.

With it off:

- `ReportLaunchStart` is called from `runtime/dart_snapshot.cc:165`
  (`ResolveIsolateData`), copying next_boot to current_boot (sets the breadcrumb
  and increments the attempt tally, `lifecycle.rs:762-784`).
- Launch success is banked in the `Shell` constructor, `shell/common/shell.cc:546-555`
  (`!vm_` reports failure, else `ReportLaunchSuccess`). `ReportsLaunchFromDart()`
  returns false (`lib/ui/window/platform_configuration.cc:600-606`), so Dart
  reports nothing.
- The Shell constructor runs before the root isolate exists and before `main`.

A crash before that point (while the VM or snapshot loads) leaves the breadcrumb
set. At the next init, `updater.rs:532` `detect_boot_crash_on_init`
(`lifecycle.rs:850-896`) counts it as a boot that did not finish: the first
death is retried (`AmbiguousBootRetry` event), and at
`BOOT_FAILURE_THRESHOLD = 2` (`lifecycle.rs:191`) it calls `record_boot_failure`,
so the patch is retired as `Bad{BootCrash}` with a `PatchInstallFailure` event.
The retirement is therefore after two failed boots, not one. A load failure the
engine can see (`vm_` null) is the immediate path.

A crash after the Shell constructor (isolate creation, `main`, any later Dart
code) is NOT counted: success was already recorded, and the patch is not retired
by the device. This is audit Signing/Distribution G8 for the Android pin. The
Route B engine closes the early-success part by moving success to `main`
completion or first frame, but not crashes after that.

## What would change in the engine tree (not done here)

- A `shorebird_unittests.cc` case driving `InstallRouteBActivationHook` with a
  mismatched `release.buildId` and asserting `MockUpdater` saw
  `ReportLaunchFailure` and no `ReportLaunchSuccess`.
- Optional: a distinct `BadReason` for a refused container, so the tombstone
  does not read `BootCrash`.
- If Android crash-after-success matters, success would have to move later on
  that engine; that is a product decision.
