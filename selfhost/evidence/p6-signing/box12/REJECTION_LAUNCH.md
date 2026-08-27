# Box 12, rejection half — PASSED on the new cell

Release **1.3.0+1** (server id 133) on cell `4792f0eca461f376…`, updater
`af6e842ccf87`. iPhone 7 / iOS 15.8.8, wired, no debugger, by-hand launches.

## The rejection launch, pid 49200 @ 18:16:26

    Preparing next boot.
    Verifying patch signature...
    Patch signature is invalid                                <Fault>
    Patch 2 failed validation: Patch signature is invalid      <Fault>
    Next boot candidate rejected: Patch signature is invalid
    Prepared boot of patch 1.                    <-- the fallback, attributed
    active path: …/shorebird_updater/patches/1/dlc.vmcode
    active patch is a Route B container
    ROUTEB: applied 1/1 targets, entering main
    Patch 2 is known bad, skipping.

Preceded by pid 49196 @ 18:16:03, which booted patch 1, credited patch 1, then
downloaded and installed patch 2 — *"Patch 2 successfully downloaded. It will be
launched when the app next restarts."* Both processes were inside a single
operator tap sequence, which is why the rejection arrived sooner than the plan
assumed.

## Durable state after the rejection

    pointers   next_boot_patch=1  last_booted_patch=1  currently_booting_patch=null
               boot_attempt_count=0  last_boot_attempt_patch=null
    patch 1    Installed, signature present
               dlc.vmcode PRESENT, 1687 B,
               c97c93f10b3248082fd5f54fe59274f042cd03a6b0189db552c7a2db71ac5a7e
               (identical to the pre-acquisition anchor — unchanged)
    patch 2    Bad{ValidationFailed}, artifact DELETED, signature retained
    success_diag  pid=49200 patch=1 raw_boot_attempt=1 prior_ambiguous_attempts=0
    rbtrace    4 records, all for patch 1; patches/2/ holds ONLY state.json,
               so patch 2 never produced an activation record

## The call-path row, aggregate over every launch

    "Preparing next boot."      6      (6 distinct Flutter pids)
    "Reporting launch start."   0
    "SIGN-V3" anywhere          0

The old three-call sequence is absent from the running engine, measured across
six processes rather than inferred from a binary grep.

## The causal contrast this closes

| | Arm C, old code | now, pid 49200 |
|---|---|---|
| attribution | `Launch success for patch 2` | `Launch success for patch 1` |
| `last_booted_patch` | **2** (the rejected patch) | **1** |
| patch 1 artifact | **deleted** by `cleanup_older_than(2)` | present, digest unchanged |
| following launch | `SIGN-V1`, the base release | patch 1 still `Installed` |

Same fixture, same key pair shape, same device, same intentional defect. The only
difference is the runtime.

## Two things NOT established, recorded as such

**The rejection launch's visible render is NOT RECORDED.** No screenshot was
taken while pid 49200 was on screen, and nobody reported the screen. The durable
artifacts do establish that patch 1's code executed — `active path` resolved to
`patches/1/dlc.vmcode`, a fourth `rbtrace` record with the Route B activation,
`ROUTEB: applied 1/1 targets`, and `success_diag` crediting patch 1 — and that
patch 2 never activated. But "SIGN-V2 was on the screen" is not among the
evidence, and is not claimed.

**Patch 2's on-device artifact digest was never compared to the published
`5631abd0…`.** `mark_bad` deletes the artifact, and the rejection happened inside
the same tap, so it was gone before the pull. The substitute is **strong but not
equivalent**: patch 2's retained `signature` in `state.json` is byte-identical to
the `hash_signature` the server offered for patch 2, and pid 49196 logged the
download, inflate and install of hash `5631abd0…`. That establishes the published
bytes reached the verifier; it is not direct byte-equality of the artifact.

To capture it directly, a future run must pull state between the install and the
next launch — which requires the download and the rejection to fall in separate
taps.

## Still owed

The durability launch: a fresh process must select patch 1 again with patch 2
tombstoned. Until then box 12 is half closed.
