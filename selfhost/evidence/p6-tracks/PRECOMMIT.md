# P6 · tracks — precommit

Written **before** the release is cut. One app, one release, one patch, two
independent updater clients, same platform/arch/release version, rollout **100%
everywhere**. No progressive rollout anywhere in this arm.

Tracks: `alpha` and `beta`.

## What the mechanisms actually are — verified in code first

| question | answer | where |
|---|---|---|
| how does a client request a channel? | the native updater reads `channel:` from the **bundled `shorebird.yaml`**, defaulting to `stable` | `vendor/updater/library/src/yaml.rs:60`, `config.rs:145` |
| what does a check request key on? | `app_id`, `channel`, `release_version`, `platform`, `arch`, `client_id`, `current_patch_number`, `supported_patch_kinds` — **no bundle id, no base-app hash** | `vendor/updater/library/src/network.rs:250-300` |
| where does `client_id` come from? | a random UUID generated per install | ibid. |
| are custom track names allowed? | yes | `set_track_command.dart`, `CommonArguments.trackNameMaxLength` |
| does adding a track remove the old one? | **no — promotion is channel-scoped and additive** | `repository.dart` supersedes only `WHERE channel_id`; `set_track_command.dart:38-44` |
| default rollout on promote? | **100** | `api.dart:_promotePatch` |
| is `deployments` authoritative? | yes; the singular `channel` field is a convenience derived from it | `api.dart:1601-1637` |

## A defect found while establishing the above, and it bounds the claim

**The updater reads a `shorebird.yaml` key that the CLI's parser rejects.**
`ShorebirdYaml` is generated with `disallowUnrecognizedKeys: true` and its
`allowedKeys` are exactly `app_id`, `flavors`, `base_url`, `auto_update`,
`patch_verification` (`shorebird_yaml.g.dart:16-23`). `channel` is not among
them, so a user who writes `channel: beta` — the documented way the updater
selects a track — gets an `UnrecognizedKeysException` from the CLI.

Consequence for this arm, stated now rather than discovered in the verdict:
**there is no supported config path for putting a client on a non-stable
track.** This arm can therefore certify the *server-side routing* causally, but
it **cannot** certify "a user configures a track the supported way", because
that path does not currently work. That half is a product gap, recorded as such.

## How two independent clients are built from ONE release

A Route B patch is bound to one release artifact, so two separate builds cannot
both be patchable by one patch. Two installs of one bundle id is impossible on
iOS. So both clients are cut from **one** build:

1. cut one release with `--target lib/main_tracks.dart`;
2. copy `Runner.app` twice;
3. in each copy, append `channel: alpha` / `channel: beta` to
   `Frameworks/App.framework/flutter_assets/shorebird.yaml`;
4. set distinct `CFBundleIdentifier` (`…foo.tka` / `…foo.tkb`) and
   `CFBundleDisplayName` (`Tracks A` / `Tracks B`) so the two icons are
   distinguishable by hand;
5. re-sign each with the team's wildcard profile.

`App.framework/App` — the Dart AOT — is **byte-identical** in both, which is why
one patch applies to both. The check request carries no bundle id and no base
hash, so to the server the two differ only in `client_id` and `channel`.

**Recorded, not glossed:** the two clients are **not** byte-identical bundles.
They differ in bundle id, display name, and the bundled `shorebird.yaml`. Held
fixed: `app_id`, `release_version`, platform, arch, the patch artifact, the AOT
snapshot, supported patch kinds, and Phase-0 patch state. The Phase-2 causal
promotion is what carries the proof regardless, since it changes **only** the
deployment.

## The vacuity trap in the negative arm, and the guard against it

`api.dart:2008` returns an empty response when the requested channel **does not
exist**. So if `beta` were absent at Phase 1, client B would receive nothing
*because the channel is unknown*, not because the patch is not deployed to it —
a negative that cannot fail, certifying nothing.

**Guard: both `alpha` and `beta` are created and asserted to exist before Phase
0**, so every withholding in this arm is a deployment decision.

## Phase 0 — control (before the patch exists)

    client A / alpha → TRACK-V1
    client B / beta  → TRACK-V1

Both must be observed performing **real** patch checks (server log shows a
`POST /api/v1/patches/check` from each), and neither receives a patch.

## Phase 1 — isolation

`shorebird patch --track=alpha` (rollout 100). Then:

    client A / alpha → check sees patch 1 → downloads → applies → TRACK-V2
    client B / beta  → check sees no eligible patch → downloads nothing → TRACK-V1

For B, bank more than the screen — this is what separates "beta correctly
withheld" from a silent transport failure of the kind already hit on this rig:

* the server received a check carrying `channel=beta`;
* the response contained no eligible patch;
* no patch file appeared in B's updater state;
* no download/install event for B;
* the screen stayed `TRACK-V1`.

Server-side, asserted from `deployments` and not from `channel`:

    alpha → active, rollout 100
    beta  → absent/inactive

## Phase 2 — the causal negative control

`shorebird patches set-track --track beta` on the **same** patch 1, rollout 100,
**without rebuilding or reinstalling either client**. Then:

    client B / beta  → receives patch 1 → TRACK-V2

Server-side:

    alpha → active, rollout 100
    beta  → active, rollout 100

This is the load-bearing step. If B updates only after the deployment changes,
the Phase-1 negative cannot be explained by transport, signing, a stale release,
a bad patch artifact, a broken updater, a wrong app id, or B being incapable of
updating — every one of those would have kept B on V1 here too. The only changed
variable is track eligibility.

## What does NOT count

* `shorebird patch --track=alpha` exiting 0.
* B staying on V1 at Phase 1 **without** Phase 2 showing B can move. That is the
  whole point: an unexplained absence is not a withholding.
* The convenience `channel` field in place of `deployments`.
* Any debugger-attached launch. Install-only via `ios-deploy -b` with no `-d`;
  every observation from a by-hand tap.
* Any rollout other than 100.

## Failure handling

If Phase 1 shows A on V1, the row is `SUPPORTED BUT UNCERTIFIED` with the
observation attached. If Phase 2 leaves B on V1, the Phase-1 negative is
**discarded as uninterpretable** rather than reported as a successful
withholding, and the arm is recorded as inconclusive.
