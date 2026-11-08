# Arm A, second attempt — NOT a clean arm. Control-plane state, not a defect.

Everything except one thing worked, and the one thing that failed was the CLI
behaving correctly.

## What passed

    self-test A   exit 64, 'non-interactive context' lines: 1
    self-test B   exit 64, interactive_prompt_required: 1
    arm 2 --json  exit 0, interactive_prompt_required: 0
    arm 3 chooser exit 64, refused the chooser BY NAME
    AAB           ✓ Built app-release.aab (46.4MB) under seal, on Linux/x64

The whole build pipeline runs end to end in a fresh container against a sealed,
cold, owned mirror.

## What failed, and why it is not a finding

    Done Release version: 1.0.0+1
    It looks like you have an existing android release for version 1.0.0+1.
    Please bump your version number and try again.

Release `1.0.0+1` already existed — record 12, created by the FIRST Arm A attempt,
which registers the release before building and then died at the missing `fonts.zip`.
A release version is immutable on the control plane, so the second attempt could
not reuse it.

The CLI refused to clobber an existing release and said exactly why. **That is
correct behaviour**, and R12 would be worth less if it had silently overwritten.

## Why this attempt cannot be banked as Arm A

Arm 2 exited 0 by patching a release that a *previous, failed* attempt created.
The decisive arm must be one uninterrupted chain — release and patch produced by
the same run — so accepting this would be stitching a discovery phase into a
decisive result, which the lane forbids.

## The seal held completely

From the mirror's own access log over the arm's lifetime:

    200, X-Overlay: hit    25
    200 not from overlay    0
    /gcs/ passthroughs      0
    502 sealed refusals     1   <- URI "/", the arm's own TLS reachability probe
                                   against the mirror root, which has no overlay
                                   file. Not an artifact, not a gap.

Every artifact the build needed came from owned bytes.

## Remedy — no destructive action

`1.0.0+1` is spent. The options were to delete release 12 from the control plane,
or to use a fresh version. Deleting is a destructive change to shared state for
cosmetic alignment with a version number that is not load-bearing, so:

    Arm A   1.1.0+1
    Arm B   1.1.1+1

Both unused. Nothing is deleted, and the leftover `0.9.x` discovery releases and
`1.0.0+1` remain as an accurate record of what happened.
