<!-- cspell:words nehelper -->
# iOS device e2e through cell 82fc78a8

Device: iPhone 7, iOS 15.8.8. Cell 82fc78a8 (CLI 357bc24f, Flutter f6bbc8a0 3.46.0-1.0.pre-863), self-hosted
`code_push_server`, artifacts through a recording origin (`artifact_origin.jsonl`) and a CONNECT recorder
(`outbound_connect.jsonl`). Script: `selfhost/ci/ios_device_e2e.sh`.

Result: every scenario passed on the device. Launch disappearances logged: 0 (`launches/` holds one trimmed
log per launch; a disappearance would be in `disappearances.txt`, which does not exist).

Setup. Two releases, each with exactly one bundle id: V (1.0.0+1, unsigned, `dev.selfhost.e2ev`, markers V*) and W
(signed with `--public-key-path`, `dev.selfhost.e2ew`, markers W*; the run ended on version 2.1.0+3, see the
history). Both use one Shorebird app_id. Each assertion is on device syslog lines and on server state
(`patches/check`, the patch list, buckets).

## Scenarios

"Updater lines" are from `launches/NN_*.txt`. All Dart changes are in members that exist in the release.

| # | What ran | Marker seen | Updater lines (launch logs) |
|---|---|---|---|
| 6a | Bundled (generated) shorebird.yaml of each release (`bundled_shorebird_V.yaml`, `_W.yaml`) | n/a | W carries `patch_public_key`, V does not |
| 7a-i | Swift-only AppDelegate change on a throwaway release 9.0.0+9 (`cli/observed_swift_change.txt`) | n/a | CLI exit 0, "Published Patch 1!" (upstream behaviour) |
| 7a-ii | Patch after adding a local CocoaPods plugin (`cli/refused_podfile_lock.txt`) | n/a | CLI exit 70, "Your ios/Podfile.lock is different from the one used to build the release"; server patch list unchanged |
| 7b | Patch adding and referencing a Dart member (`cli/refused_added_member.txt`) | n/a | CLI exit 70, "cannot introduce members"; nothing published |
| 1 | V1 base release (launch 01) | V1:g-55 | `patch_available: false`, "no active patch" |
| 2 | Patch 1 (real Dart change) (02, 03) | V1 then V2 | "Patch 1 successfully downloaded", next boot "ROUTEB: applied 2/2 targets, entering main", "Launch success for patch 1" |
| 3 | Patch 2, consecutive (04, 05) | V2 then V3:g-144 | "Patch 2 successfully downloaded", "Launch success for patch 2", applied 3/3 |
| 4 | Roll back patch 2 (06, 07) | V3 then V2 | `rolled_back_patch_numbers: Some([2])`, patch 1 offered again, "Launch success for patch 1" |
| 4b | Roll back patch 1 as well (08, 09) | V2 then V1 | `rolled_back_patch_numbers: Some([1, 2])`, "no active patch" |
| 5b | W 2.0.0+2 / 2.1.0+3 ignore V's patches, then take their own (10-15) | W1 then W2:g-89 | `patch_available: false` while only V had patches; after W's patch: "Patch 1 successfully downloaded", "Launch success for patch 1" |
| 5c | V (1.0.0+1) takes its patch 3, unaffected by W (16) | V4:g-377 | "Launch success for patch 3", `Some([1, 2])` still rolled back |
| 4c | Roll back W's only patch (17, 18) | W2 then W1 | `Some([1])`, "no active patch" |
| 6 | Signing: patch signed with the good key boots with verification on (19-21); a patch signed with another key is refused by the CLI | W3:g-144 | "Launch success for patch 2"; refusal text "Signature verification failed: the signature does not match the provided public key." (exit 70, `cli/signed_other_key.txt`); app keeps running W3 |
| 8a | Server restart on its data dir (22, 23) | W3 then W4:g-233 | "Patch 3 successfully downloaded", "Launch success for patch 3" |
| 8 | Server down (24, 25, `launches/server_down_W.txt`) | W5:g-377 | "Update failed: Network request failed; the server could not be reached.", status "Update had error", the patched boot and the process stay alive; the restarted server serves again |
| 9 | Staged rollout (26-28) | W5, then W6:g-610 | at 84% the phone (bucket 8423) is not offered patch 5 and keeps W5; at 85% it is offered; at 100% it boots patch 5 |
| 10 | Backup and restore of the server data (29-31) | W6 then W7:g-987 | a patch published after the restore reaches the phone: "Launch success for patch 6" |

## Divergences from Android

- 7a: a Swift-only change is published, not refused. This is upstream behaviour:
  `packages/shorebird_cli/lib/src/commands/patch/apple_patcher_mixin.dart`
  (`ApplePodfileLockPatcherMixin.assertUnpatchableDiffs`) passes `confirmNativeChanges: false` because Xcode builds are
  not byte-reproducible. The only iOS native-change refusal is a Podfile.lock hash that differs from the release's.
- Swift Package Manager finding: Flutter 3.46 projects use SPM by default, so there is no Podfile and no Podfile.lock
  hash on the release, and iOS native changes are never refused. The 7a-ii refusal only fires for CocoaPods apps. The
  script turns SPM off (`flutter: config: enable-swift-package-manager: false` in the pubspec) and adds a local path
  plugin (`e2e_plugin_a`) so the release records a hash; the refusal then uses a second plugin.
- The updater lines are iOS Route B lines: "ROUTEB: applied N/N targets, entering main" (2/2 for V's patch 1, 3/3 once the
  patches change `fib`, `marker` and `arg`), instead of Android's code-push log wording.
- Every launch is `idevicedebug run`; the first request after a fresh install fails until the human taps OK on the
  Local Network prompt (`local_network_decisions.txt`, nehelper "Local network decision"). The tap is needed once per
  install, per bundle id. The script stops with exit 3 after installing, and `--resume` continues.

## Invocation history

The run took several invocations. No scenario was re-run to turn a fail into a pass except as noted.

1. Phase 1 several times, to fix script bugs (AppDelegate edit, "Nothing in this patch differs", SPM and Podfile.lock,
   7b wording). Installed V and W, exit 3, the owner tapped.
2. First `--resume`: scenarios 1 and 2 passed but the script then failed on its own ROUTEB assertion (it expected 1/1;
   the right value is 2/2 targets). Fixed the script.
3. `E2E_FROM=3` and `E2E_FROM=4` resumes, to skip what had passed (launches 01-03, then 04-09). A failed run's cleanup
   stopped the server, recorders and syslog capture, so each resume restarts what died. The syslog capture also
   stalled (idevicesyslog stops after about 25 minutes) and was restarted.
4. A failed run's cleanup deleted the keys directory, losing W's private signing key. W was rebuilt as 2.1.0+3 with new
   keys (`E2E_PHASE=rebuild-w`), uninstalled and reinstalled, which needed a second Local Network tap (nehelper
   allowed at 11:47 for the first install, 12:37 for 2.1.0+3). Cleanup now keeps the keys on failure. 5b was
   completed on 2.1.0+3 (launches 12-15); launches 10 and 11 are from W 2.0.0+2.
5. `E2E_FROM=5` resume: 5b passed, then about 12:44 the phone disconnected and `idevicedebug run` failed for every app
   (the app stopped on SIGSTOP at launch); 5c timed out. This was a device or debug-service fault, not a product one.
   The coordinator restarted the phone over USB and remounted the DDI. Their two test launches of V (about
   12:56-12:57) happened while the server was stopped and were not captured by the syslog; V already had patch 3
   booted from 12:41 (the earlier attempt at 5c had downloaded and booted it), so V showed V4 with nothing to
   download.
6. `E2E_FROM=6` resume (this one finished): because of 5, 5c was run as a single check that V boots patch 3 (V4,
   "Launch success for patch 3", launch 16), not as the download-then-boot pair; patch 3's download is in the earlier
   invocation's syslog at 12:39:40 ("Patch 3 successfully downloaded"). Then 4c, 6, 8a, 8, 9 and 10 ran to the end,
   exit 0, 0 disappearances.

Scenario gating in the script is by `E2E_FROM`, as recorded in `passed.txt`.

## No secrets

The server API key is random per run and never printed. Local paths were rewritten to `$HOME` and `$SCRATCH`.
Signing keys stay in the work dir and are not part of this evidence.
