<!-- cspell:words privatestate killswitch twoengine assetprobe airgap precommitted noninteractive debugserver idevice -->

# P6 · iOS flavor arm — rig custody, and the precommit

**Nothing was built, installed or launched before this file existed.** The
invariant: *no P6 launch occurs until the previous experiment has relinquished
the rig in a recorded state.* Idle hardware is not a relinquishment.

## 1 · Custody, established from the device and the precommits — not from memory

| question | answer |
|---|---|
| previous owner / experiment | **this session's Route B P1/P2 lane**, fixture `privatestate_app` |
| complete? | **yes.** `fixtures/privatestate_app/evidence/VERDICT.md` and `P2_VERDICT.md` are banked; the final observed state was ROLLED BACK (screenshots `04_rollback_pristine.png`, `06_p2_rollback.png`) |
| peer sessions holding it | none. `ListAgents` shows no other shorebird session; the only busy peer is an unrelated project. **Recorded, not relied on** — the custody answer above is what releases the rig |
| device | iPhone 7 / iOS 15.8.8 / `8cb4bc982ddf6437b1952520edee80f898196c74`, wired. Confirmed with `idevice_id -l` and `ios-deploy -c`, because `devicectl` is blind to iOS 15 |
| installed fixtures | `dev.selfhost.privatestateProbe`, `dev.selfhost.killswitchProbe`, `dev.selfhost.twoengineProbe`, `dev.selfhost.airgapProbe`, `com.jewgo.assetprobe` |
| **lifecycle-policy measurement** | **the rig is NOT part of the sample, by precommitment rather than by luck.** `THRESHOLD_ANALYSIS_PRECOMMIT.md` excludes *"the rig's own `client_id`s"* from the population, fixed in advance. So a new fixture on this device cannot contaminate the frozen threshold analysis |
| **but one fixture's STATE is load-bearing** | `dev.selfhost.airgapProbe` carries `MEASUREMENT_MODE.md`'s specimen — release 108 / 1.8.0+1, patch 1, PATCHABLE. **It must not be touched.** The P6 arm uses a different bundle id, so it neither reads nor writes that app's state |
| P6 fixture's prior state | `flavored_probe` is **not installed**. No prior patch, no updater state, nothing to preserve or disturb |
| rig CLI provenance | `~/.shorebird` at `9125eb13`; pinned Flutter `c15ef637`, whose `engine.version` currently reads **`93a3756…`** |

**Hand-back: the rig is claimed by the P6 iOS flavor arm as of this file.**

## 2 · A prerequisite this gate found, and it is shared rather than local

The rig CLI `9125eb13` is **24 commits behind** the tree and predates every gate
built today. A release cut with it records **no snapshot profile, no profile
binding, no contract revision and no release target** — so a patch built with the
current CLI would refuse it, correctly, as `RELEASE_EVIDENCE_ABSENT` or as a
release with no contract revision.

So this arm cannot be run by pointing the old CLI at a flavored app. It needs:

1. the rig CLI moved forward to a tree containing P4.1/P4.2/P4.3/P4.4/P5;
2. `engine.version` repointed from `93a3756…` to the current cell `9b5f040c…`;
3. the cache cleared and then **warmed**, because the mint's own precondition
   records that the FIRST release after a clear silently takes the non-Route-B
   path — `isRouteBEngine` reads the ios-release Flutter binary and returns false
   when it does not yet exist.

**This is not specific to flavor.** Every remaining device row in
`WORKFLOW_CERTIFICATION.md` — flavor iOS, the defines REPLACEMENT link,
obfuscation, tracks, the manual updater API — needs a release cut by a
new-era CLI on the current cell. The P4/P5 hardening created an **epoch
boundary**, and crossing it is one shared cost paid once, not five.

## 3 · The arm, precommitted

Exactly one flavor, `foo`, on both sides. The wrong-flavor negative stays at the
host/product layer: P5 already owns that refusal and a deliberately mismatched
flavor is not sent to the phone.

| # | requirement | how it is observed |
|---|---|---|
| 1 | release built through the real flavored Xcode configuration/scheme | `xcodebuild` invoked with the `Foo` scheme / `Release-Foo` configuration |
| 2 | release metadata records the intended flavor | `route_b.json` `buildConfig` carries `FLUTTER_APP_FLAVOR=foo` |
| 3 | the patch's build configuration AGREES with the release's | `[route-b] build configuration matches the release (fingerprint …)` |
| 4 | the exact current cell is in the lineage | `route_b.json` `engineRevision` = `9b5f040c…`, read from the SHIPPED sidecar |
| 5 | P4 release evidence is present | `route_b_snapshot_profile.json` + `route_b_profile_binding.json` in the supplement, and the patch's probe verdict is `ONE_OR_MORE_QUALIFYING_CALLSITES` |
| 6 | baseline visibly `FLAVORPROBE-V3` | screenshot |
| 7 | the patch publishes through the real producer | patch id recorded, `ready` |
| 8 | **manual icon launch only** | no `ios-deploy` debug session, no debugserver. The repo already requires tap-launches (`manual_launch_control_precommit.md`) |
| 9 | the device renders `FLAVORPROBE-V4` | screenshot |
| 10 | an unrelated control is unchanged | a second on-screen value that the patch does not touch |

**STOP / INVALID conditions, fixed now.** If `isRouteBEngine` is false at release
time, the release is not a Route B release and the arm is VOID — not a failure of
flavors. If the shipped `route_b.json` names an engine other than `9b5f040c…`,
the arm is VOID. If `V4` appears without requirement 8 being true, the run is
VOID: a debugger-attached launch is a different execution path.

**Rollback is NOT required for PASS.** It is already independently device-proven,
including on this session's private-`State` specimens, and it is not the unique
flavor seam. If shared-rig hygiene wants the fixture returned pristine, the
rollback happens as part of hand-back and is **not** counted as P6 evidence.

## 4 · Hand-back, to be performed after the arm

    P6 flavor evidence captured
    → withdraw/rollback the fixture patch
    → verify the expected clean updater state
    → terminate the fixture
    → record the final device/app state here
    → relinquish the rig
