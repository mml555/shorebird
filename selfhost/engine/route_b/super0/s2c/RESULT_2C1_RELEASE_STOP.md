# D-SUPER-2C.1 · candidate release cut — STOP before a release exists

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT

    CLI pin remote durability     PASS (re-verified independently)
    canonical B fixture app       CREATED
    auth to the control plane     PASS (lane-scoped key)
    toolchain coherence gate      PASS on the second attempt
    flutter build ipa             FAILED — Invalid SDK hash
    release                       DOES NOT EXIST
    provenance.engineRevision     NOT CLAIMED

Fail closed. No release, so nothing downstream is asserted.

## What was established first

`f864f6c667397ecba26750a029c03db7620834b3` IS remotely durable, on
`mml555/shorebird refs/heads/route-b-2c-candidate-cli` — the fork, not a separate
CLI repo, which is likely where the earlier search missed it. Verified NOT from
the working copy: the object was fetched into a fresh bare repo, is a commit, and
its `bin/internal/flutter.version` reads `371005c9…`.

Canonical app at `/Volumes/build/route-b/superapp`, `super_fixture`,
`app_id 41344620-5d2d-9707-47e0-88ab230f8cbf`. Base/Ticker/Leaf exactly as
ruled, `target()` carrying `vm:never-inline` + `vm:entry-point`, `DateTime.now()`
anti-folding guards retained. The UI prints the raw string plus a named verdict
so a device photograph is self-describing:

    TICKER:APP-STATE       RELEASE (unpatched)
    WRAP:TICKER:APP-STATE  PATCHED narrow-v1 super
    LEAF:APP-STATE         WRONG - virtual dispatch

Credentials: the stored ones were issued by `http://169.254.189.3:18080` while
this deployment advertises `http://10.0.0.7:18080`, and the CLI diagnosed that
exactly. A LANE-SCOPED key was minted via the documented `POST /admin/users`
(`route-b-2c@selfhost.local`, user id 4) rather than reusing an existing one.

## The fork's own coherence gate refused first — correctly

    COHERENCE_UNDETERMINABLE: SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR is not set, so
    the cached iOS engines could not be compared against the ones published for
    a5a8be58…. Stamps alone cannot establish this.

It compares the cached `Flutter` binary for ALL THREE iOS modes against each
published `artifacts.zip`. That check is only satisfiable because the cell now
owns all three — it would have refused this release outright before 7.5.

Satisfied using the bytes the CDN actually SERVED, not the overlay directory,
after confirming served == overlay for all four inputs:

    ios 5891a6bb…  ios-profile c0b922f2…  ios-release 0f83e38f…  dart-sdk b99426af…

Coherence then PASSED.

## STOP — `Can't load Kernel binary: Invalid SDK hash`

    Target aot_assembly_release failed: AOT snapshotter exited with code 254

### Measured root cause: the published HOST toolchain is a different Dart lineage

SDK hashes read from the kernel headers themselves:

    published under H  flutter_patched_sdk_product.dill   6b58bb3a72   STALE
    candidate engine   args.gn dart_version               9e8c898a4d…
    Route B cell (H)   flutter_platform_strong.dill       9e8c898a4d   correct
    Route B cell (H)   vm_platform.dill                   9e8c898a4d   correct

`6b58bb3a72` is the prefix of `6b58bb3a72e293e27ff920a61c007bf2e405071e` — the
CERTIFIED-lineage Dart revision recorded in the sibling manifests. So the cell
and the iOS engine agree at `9e8c898a4d`; only the published host toolchain
disagrees.

Inside the candidate tree itself:

    out/host_release_arm64_nodm   sdkHash 6b58bb3a72   (Aug 3 — STALE)
    out/host_release_arm64        sdkHash 9e8c898a4d   (Aug 18 — current)

`publish_ios_overlay.sh` sources the host toolchain from `HOST_REL`/`HOST_DBG`,
which default to a DIFFERENT ENGINE TREE
(`/Volumes/build/ios-engine/.../host_release_arm64_nodm`), and only `PSDK_REL`
derives from `OUT`. Overriding `OUT` alone — as step 4 did — therefore published
a stale-lineage host toolchain beside a candidate iOS engine.

The script's own comment already flags this pairing as ONE MEASURED CASE and
explicitly "NOT a relaxation of the 'all three come from our tree' rule". That
measured pairing does not hold for this candidate.

### Why step 7's const_finder check did not catch it

Step 7 proved the candidate `const_finder` beat the STOCK one, and that remains
true. But both sides of that comparison came from the SAME stale host lineage
(`6b58bb3a72`), which is exactly why it loaded cleanly. It was not vacuous — it
did discriminate candidate from stock — but it could not detect that the whole
host set is the wrong lineage FOR THIS ENGINE. Different question, different
control.

## What this needs — NOT started, needs a ruling

The host toolchain under H must come from a build whose SDK hash is
`9e8c898a4d`. The complication is that it must ALSO be a non-dynamic-modules
host build: `host_release_arm64_nodm` is the `_nodm` variant on purpose, and
`host_release_arm64` (which has the right hash) is the DM build used for the
Route B compiler cell. So the likely requirement is REBUILDING
`out/host_release_arm64_nodm` from the current candidate tree, not repointing at
the DM directory.

And it is a COHERENT SET, not one file. Republishing the host toolchain changes
`dart-sdk-darwin-arm64.zip` and `darwin-arm64/artifacts.zip`, and
`font-subset.zip` EMBEDS the `const_finder` taken from the latter — so
font-subset must be regenerated in the same pass or it will carry a const_finder
from the retired lineage. `dart-sdk-darwin-arm64.zip` is also protected by
`@must_be_local`, and all of these are already-published H artifacts.

Not attempted. Nothing republished, nothing overwritten.
