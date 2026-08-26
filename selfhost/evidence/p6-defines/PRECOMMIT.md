<!-- cspell:words flavoredprobe ALPHA precommitted nostart -->

# P6 · Dart defines — the REPLACEMENT link, precommitted

Written before the release exists.

## The one question

> Does the replacement compiler receive the same effective Dart defines the
> release contract says it should?

`g41c`/`g41d` already proved **link 1, ANALYSIS**, byte-identically. Link 2,
**REPLACEMENT**, has never been shown on a device. That is all this arm is for.

## What makes the observation load-bearing

The patch body reads the define **inside the replacement**, not through a value
imported from release code:

    const value = String.fromEnvironment('P6_DEFINE', defaultValue: 'MISSING');

A release-side `ALPHA73` proves nothing about the missing link — the release
compiled with the define by construction. Only the replacement's OWN compile is
in question.

`defaultValue: 'MISSING'` is the point of the design: a dropped define is
visibly different from a correct one, with no interpretation required.

## The table, fixed now

| observed | meaning |
|---|---|
| `V2/ALPHA73` | **PASS** — replacement executed AND the define reached its compile |
| `V2/MISSING` | FAIL — replacement executed, the define was DROPPED |
| `V2/<other>` | FAIL — a different define set reached the replacement |
| `V1/ALPHA73` | FAIL — the patch did not execute at all |

Controls, both of which must be unchanged:

    release marker   FLAVORED-FIXTURE-V1
    baked asset      BAKED-INTO-RELEASE
    flavor state     V1/Foo   (untouched by this patch — a second control)

## What this arm does NOT re-prove

The device epoch, the signing path, the transport, and the Local Network grant
were established by the flavor arm. They are prerequisites here, not claims.

Fixture reuse is deliberate: `flavoredprobe-p6` already holds the granted Local
Network permission for `dev.selfhost.flavoredProbe.foo`, so reusing it keeps the
arm about defines instead of about setup.

## The negative stays at the P5 host layer

`release defines A` + `patch defines B` → `BUILD_CONFIG_MISMATCH`, already owned
by P5 and already tested. **No mismatched define is sent to the phone.**

## Method

Same rules as the flavor arm: by-hand taps only, `--nostart` install, and any
`--justlaunch`/debugger-attached launch invalidates an observation.
