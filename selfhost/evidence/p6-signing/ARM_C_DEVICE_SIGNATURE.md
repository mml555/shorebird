# Signing Arm C — boot-time patch signature verification on device

App `signprobe-p6` (`525b41fe-…`), bundle `dev.selfhost.signProbeApp`, release
**1.0.0+1** (server id 130), `patch_verification: strict`, own control-plane app
and updater state. iPhone 7 / iOS 15.8.8, wired. No debugger: installed with
`ios-deploy --bundle` and no `-d`/`-L`; every launch a by-hand tap; state read
with `ios-deploy --download`, which attaches none.

**Outcome: the cryptographic refusal is PROVEN. The last-known-good fallback is
NOT — it failed, for a reason unrelated to signing, and Arm C therefore does not
close.**

## Keys

    K1 (trusted)  sha256(public PEM) e85f2e877fc9cafb03cb239918dac457…
    K2 (wrong)    sha256(public PEM) 98727c33cf2eef85cbddadc5434df423…
    K1 != K2      measured before the release was cut

Disposable, generated for this arm, never committed; only hashes recorded.

## [9] The shipped release really carries K1

Read out of the **fetched** release artifact's bundled
`App.framework/flutter_assets/shorebird.yaml`:

    patch_verification : strict
    patch_public_key   : sha256 87637beb845e8bb60bde881a1b5f5812
      == DER(K1)       : YES
      == DER(K2)       : NO

    release container sha256 : 767fcbcd054ac1fa5cabd0fc669e6cccddaeb225…

Re-fetched after both patches were published: release SHA **unchanged** and the
bundled key **still K1**, so nothing in this arm moved the trust root.

## [10] A valid K1 patch was accepted and executed

Patch 1 (`SIGN-V1` → `SIGN-V2`), signed with K1.

The verifier's own words, from the launch that booted it:

    14:45:37  [shorebird] Verifying patch signature...
    14:45:37  [shorebird] Patch signature is valid
    14:45:37  Shorebird updater: active path: …/patches/1/dlc.vmcode
    14:45:37  Shorebird updater: active patch is a Route B container
    14:45:38  ROUTEB: activated signState in package:sign_probe_app/main.dart
    14:45:38  ROUTEB: applied 1/1 targets, entering main

And independently, the **on-device stored signature** checked against the
production Rust verifier (the Arm A hook, via ctypes):

    patch 1 state: Installed, size 1687, signature present (344 b64 chars)
    artifact patches/1/dlc.vmcode sha256 c0feccc1e0f7965d…
      — matches the server's recorded patch hash exactly
    vs K1 (bundled) : ACCEPT
    vs K2 (wrong)   : REJECT

Device rendered `release: SIGN-REL-1` / `sign state: SIGN-V2`.
Lifecycle settled with `next_boot_patch: 1`, `last_booted_patch: 1`,
`currently_booting_patch: null`, `boot_attempt_count: 0` — patch 1 was the
known-good fallback before patch 2 was published.

## [11] The K2 patch was rejected at boot and tombstoned

Patch 2 (`SIGN-V2` → `SIGN-V3`), signed with **K2**. Host proof it is a
*correctly signed patch under the wrong trust root*, not a corrupt one:

    H2 = 6d0d20683fba5b56c5cb4117baec7e28…   (server's recorded hash)
    S2 = Sign(K2, H2)
      production Rust verifier vs K2 (signer)        : ACCEPT
      production Rust verifier vs K1 (release trust) : REJECT
      sanity, S2 vs K2 but wrong message (H1)        : REJECT

It reached the verifier rather than failing earlier — `__patch_download__ 2` and
`__patch_install__ 2` are both recorded, and the client logged *"Patch 2
successfully downloaded. It will be launched when the app next restarts."*

Result on device:

    patches/2/state.json : { kind: Bad, reason: ValidationFailed, signature: present }
    later launch          : "Patch 2 is known bad, skipping."
    SIGN-V3               : NEVER rendered, on any launch

**That is the cryptographic refusal, and it holds.** A patch whose only defect
was a signature not valid under the baked-in public key was downloaded,
installed, and refused at boot with exactly `Bad{ValidationFailed}`.

### A CLI behaviour worth recording

Publishing patch 2 with K2 first **refused**: supplying a different public key
changes `patch_public_key` in the compiled `shorebird.yaml`, so the producer
reported it as an asset diff —

    Your app contains asset changes, which will not be included in the patch.
        Products/…/flutter_assets/shorebird.yaml

`--allow-asset-diffs` was required. Useful behaviour: the CLI notices that a
patch's would-be trust root differs from the release's, and the release's key is
what continues to govern.

## [12] The last-known-good patch did NOT continue — FAILS

After the rejection, one further by-hand launch:

    14:56:59  Error reporting launch start:
              record_boot_start(1) expected Installed, got None
    14:56:59  Patch 1 failed validation: Patch 1 is not Installed: None
    14:56:59  Shorebird updater: no active patch.
    14:56:59  Patch 2 is known bad, skipping.

Device rendered **`SIGN-V1`** — the **base release**, not patch 1.

State pulled twice tells the story:

    first pull  : patches/1/{state.json, dlc.vmcode, dlc.vmcode.routeb, …}
    after arm   : patches/2/state.json   ← the only surviving patch file

Patch 1's artifact and state were deleted, so `next_boot_patch: 1` pointed at
nothing and the updater fell back to the base release.

### Mechanism, as far as the evidence supports

`record_boot_success()` promotes `currently_booting_patch` to
`last_booted_patch` and then calls `cleanup_older_than(n)`
(`lifecycle.rs:633`). `success_diag.log` records:

    pid=47601 patch=1 …
    pid=47607 patch=1 …
    pid=47668 patch=1 …
    pid=47671 patch=2 …      <-- patch 2 credited with a successful boot

`pointers.json` afterwards holds `last_booted_patch: 2`. So patch 2 was credited
with a boot, which advanced the pointer to 2 and ran `cleanup_older_than(2)` —
deleting patch 1, the very artifact the fallback needed. The safety net was
removed before the failure it exists for.

### The part this evidence does NOT settle

Whether pid 47671 actually *executed* patch 2's code. Two readings:

* **bookkeeping mismatch** — patch 2 was recorded as booting/booted while the
  code that ran was patch 1. Supported by the render: that process was alive at
  14:47 and showed **`SIGN-V2`**, which is patch 1's code, not `SIGN-V3`.
* **patch 2 briefly executed** — would be a far more serious finding. **Argued
  against** by the same render, and `SIGN-V3` was never observed at any point.

The captured log cannot decide it directly: `ROUTEB: built-for` is the *release*
identity and is identical for both patches, and pid 47671 logged no `active
path:` line. Stated as unresolved rather than assumed either way.

**To settle it**, a re-run should log or capture the resolved artifact path per
launch (`active path:`) and compare it against `patches/N/dlc.vmcode` digests,
with `success_diag`/`pointers` sampled between every launch.

## Verdict

| # | criterion | result |
|---|---|---|
| 9 | shipped release carries K1 | **PASS** |
| 10 | valid K1 patch accepted + executed | **PASS** |
| 11 | valid-but-wrong K2 patch → `Bad{ValidationFailed}` | **PASS** |
| 12 | last-known-good K1 patch continues; K2 code never executes | **FAIL** (K2 code never rendered, but patch 1 did not continue) |

**Signing is not certified.** The signature boundary itself — the thing this arm
was designed to test — behaves correctly. What fails is patch lifecycle
retention: installing a newer patch destroys the previous one, so a later
validation failure has nothing to fall back to except the base release.

That is a defect in its own right, independent of signing: any patch that fails
boot validation for *any* reason — size mismatch, missing artifact, bad signature
— drops the user to the base release rather than the last patch that worked.

Not fixed here. It is lifecycle logic with a pointer/cleanup ordering question
inside it, and the fix should be chosen deliberately rather than while closing a
certification arm.
