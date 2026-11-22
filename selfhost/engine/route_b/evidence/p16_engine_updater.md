<!-- cspell:words ureq -->
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
- `vendor/updater` is NOT byte-identical to the engine's copy. Every difference
  (`diff -rq`, 2026-11-16):
  - `library/src/http.rs`: a behaviour change in the download path's error
    classification (mirror#11): `is_transport_failure` and `ureq_send_with`,
    so a proxy refusing CONNECT, a body stall and similar errors become
    `NetworkError::Transport` in the ureq builds (Linux, Windows; not Android,
    iOS or macOS). `VENDOR.md:12` describes it. Plus new tests.
  - `library/src/diag_log.rs` (new, with `mod diag_log;` in `lib.rs`) and its
    calls in `updater.rs` and `cache/updater_state.rs`: bounded diagnostic logs.
  - `library_test_hooks/src/lib.rs` (and the `lib.rs` registration): the
    fork-local engine-callback registration for the Dart-to-Rust seam test.
  - `.github/workflows/*` (vendor carries upstream's at the base commit),
    `.github/actionlint.yaml` (engine only), `SELFHOST_PORT_ca91f4b3.md`,
    `VENDOR.md` (vendor only), `shorebird_code_push/coverage_badge.svg`
    (engine only).
  - `library/.cargo/config.toml`: line endings only.
  `cache/lifecycle.rs`, `cache/signing.rs` and the rest of `cache/` are
  identical, and `download_and_install_patch` is identical apart from the diag
  calls. So CI's Rust tests on `vendor/updater` exercise the same signature and
  lifecycle code the engine ships, but not the engine's HTTP transport
  classification. This is source identity, not build identity: nothing here
  proves the shipped binary was built from that checkout.

## 2. Does it verify the patch signature at download time (given a key)?

Yes when the app embeds a `patch_public_key`, in every `patch_verification` mode,
before any download state or network call. With no key, signing is off and the
check passes (`cache/signing.rs:25-35` returns `Ok(())` for a `None` key).
`download_and_install_patch` never reads `patch_verification`.
`third_party/updater/library/src/updater.rs`, `download_and_install_patch`:
`crate::cache::check_patch_signature(&patch.hash, patch.hash_signature, config.patch_public_key)`
at lines 1119-1123. On failure it calls `record_signature_refused` (tombstones
the pair) and returns `UpdateError::InvalidSignature` (lines 1124-1137). Only
after that does it call `record_download_started` (line 1162) and
`download_to_path`. The signature covers `patch.hash`; the post-inflate hash
check then ties the installed bytes to that hash. `vendor/updater` has the same
call site at the same lines.

The default `patch_verification` of this updater is `install_only`
(`yaml.rs`), which re-verifies nothing on boot; `strict` also re-verifies the
installed artifact each boot. When the app embeds no `patch_public_key`,
`check_patch_signature` has nothing to check against. The engine refuses to
start the updater when a key is configured but no verifier is registered
(`updater.rs:464, 488-491`, `InitError::NoSignatureVerifier`).

Consequence for the CLI: the `install_only` gate is
`packages/shorebird_cli/lib/src/patch_verification.dart` (`installOnlyBrokenEngineRevisions`,
used by `release_command.dart` `_assertPatchVerificationChecksSignatures`). It is
a closed list of engine revisions known to skip the check in `install_only`. Neither
`d0714887` nor `2c4b0718` is on it (grep: 0 matches), so the refusal does not fire for
this engine, which is consistent with the source above. This note does not
call the gate stale. Whether its list should also cover the fork's older engines
is a CLI question, not settled here.

## 3. iOS Route B patch whose build id does not match the release

The patch is refused, marked Bad, and not retried.

Trace (engine tree):

1. `shell/common/shorebird/shorebird.cc` `ConfigureShorebird` calls
   `Updater::PrepareNextBootPatch()`, which selects the patch and records it as
   the booting patch (the start is recorded there, not in
   `runtime/dart_snapshot.cc:160-165`, which skips it under `SHOREBIRD_ROUTE_B`).
2. `ApplyPatchToSettings` sniffs the file; a Route B container arms
   `InstallRouteBActivationHook` (line 706).
3. In the `root_isolate_create_callback` (before `main`), the hook reads
   `Dart_RouteBReleaseBuildId()` (line 398). A null id is refused. Then
   `running_id != container.release_build_id` (line 410) reports
   `REFUSED (wrong-release)` and calls `ReportRefusal()` (line 416), which
   is `Updater::Instance().ReportLaunchFailure()` (lambda at line 359-361), then
   returns without activating anything. The app boots on the release's AOT code.
4. `shell/common/shorebird/updater.cc:167-174` `ReportLaunchFailure` takes the
   once-per-process latch and calls `shorebird_report_launch_failure()`. That is
   `third_party/updater/library/src/updater.rs:1825-1856`:
   `record_boot_failure_for_patch` then `lifecycle.rs:832-843` `record_boot_failure`
   -> `mark_bad(n, BadReason::BootCrash)`, clears the boot breadcrumb and attempt
   tally, and `recompute_next_boot` (falls back to the last good patch or the
   base). It queues a `PatchInstallFailure` event ("engine_report: patch N failed
   to launch").
5. A second reporter, `shell/common/shell.cc:830-838` (`Engine::Run` returning
   Failure, Route B only), takes the same latch, so failure and success are
   mutually exclusive per process.
6. The success that Dart reports later (`lib/ui/hooks.dart` on `main` completion
   or first frame, `_reportLaunchSuccess`) is dropped because failure already
   took the same latch (`shell/common/shorebird/updater.cc:107-114`). Hence the patch is not credited.

So: marked Bad (`Bad{BootCrash}`, a misleading reason name for a refusal),
`ReportLaunchFailure` is called, and it is not retried on every boot. The other
refusals (malformed, unsupported version, no identity, partial apply) take the
same path. The one exception is an unreadable artifact, which abstains
(`AbstainFromLaunchReport`) and is bounded by the boot-attempt threshold (2).

Host evidence already in the updater: `updater.rs:2976` (engine tree; the vendor copy is at 2971)
`prod_c2_explicit_failure_retires_immediately` (explicit failure retires on the
first strike) and `lifecycle.rs:2119` (identical in both trees)
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

## 4. Android (default, non-Route-B build of this tree): where launch success fires, and a crash before it

Which engine the Android artifacts ship is UNVERIFIED for build args. What the
repo does settle: `compatibility.yaml` `engine_revision: d0714887...` (line 114)
is "our own build (ci-build Linux + arm64 Mac)" and the cells `aab9fd07` and
`2fc41d3f` are minted over it; the CLI's pinned Flutter `5c60356c`
(`bin/internal/flutter.version`) has `engine.version` `2fc41d3f` (the cell
address, from `mml555/shorebird-flutter`), which `STATUS.md:12` says is "over
engine `d0714887`". So the tree read here is the supported pin's producer
engine. What is not shown: the gn args the Android arm/arm64/x64 artifacts were
built with. `SHOREBIRD_ROUTE_B` comes from gn arg `shorebird_route_b`
(`common/config.gni:53, 118-123`, default false), no builder file under
`ci/builders/` sets it, and `STATUS.md:33` says the iOS release engine is built
with it on (it does not say the Android one is not). So "Android is not Route B"
below holds for the default build, and is UNVERIFIED for the published Android
artifacts. Check their build args to settle it. The claims below are about this
source tree, with `SHOREBIRD_ROUTE_B` off.

With it off:

- `ReportLaunchStart` is called from `runtime/dart_snapshot.cc:165`
  (`ResolveIsolateData`), copying next_boot to current_boot (sets the breadcrumb
  and increments the attempt tally, `lifecycle.rs:762-784`).
- Launch success is banked in the `Shell` constructor, `shell/common/shell.cc:547-555`
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

## Guard coverage

`selfhost/ci/engine_updater_evidence_guard.sh` checks 1-3 read only
`vendor/updater` and `compatibility.yaml`. Checks 4-6 need the engine checkout
and cannot run on hosted CI, which has none; they print a `SKIPPED` summary and
`--require-engine` turns that into exit 2. On 2026-11-22 all six passed against
engine `e737ede3` (Flutter 3.50) and updater `a58774ab`, after checks 5-6 learned
the 3.50 code shape: `ApplyPatchToSettings` is an overload pair, and check 6 now
reads `shell.cc` as a Route B build compiles it, requiring a null-VM failure
report in the Shell constructor and no `ReportLaunchSuccess` anywhere in that
view. Nothing in `.github/` invokes the
script: it is a local check, run on a machine with the engine tree. It does not
cover the latch in `updater.cc` or `hooks.dart`.
