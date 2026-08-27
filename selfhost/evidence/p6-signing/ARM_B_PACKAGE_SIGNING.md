# Signing Arm B — platform package-signing invariants

One narrow question: **does creating and publishing a Shorebird patch leave the
already-signed application release artifact and its platform signing properties
unchanged?**

Deliberately not another release→patch→execution test. The release is the *object
under examination*, not the thing being exercised.

## B1 · iOS — CLOSED

App `1c99c679-…`, release **1.17.0+1** (server id **129**), development-signed.
Both measurements fetch the `xcarchive` artifact **from the control plane**, never
from a local build directory, because the question is what the server holds.

An ordinary patch was published between them (`patch 2`, `--track=beta`). Its body
is irrelevant to this arm; it only has to publish. The release was **not**
re-signed and **not** reinstalled afterwards.

| Property | Before patch | After patch | Result |
|---|---|---|---|
| container SHA-256 (fetched bytes) | `a71170aae04da816b39f4e96e7478e03…` | same | **SAME** |
| signed `.app` tree digest | `75ed6861b71a714a5c81b49eb5e8c275…` | same | **SAME** |
| `codesign --verify --deep --strict` | PASS | PASS | **PASS/PASS** |
| Identifier | `dev.selfhost.flavoredProbe.foo` | same | SAME |
| TeamIdentifier | `SK85S6YZP9` | same | SAME |
| Authority | `Apple Development: Pesach Brody (BRDNYM22XL)` | same | SAME |
| CDHash | `96db6e00fc97dbcb337eee127a288641` | same | SAME |
| profile SHA-256 | `78b4e9cab6fe26911d5e0aa4d976ce5a…` | same | SAME |
| profile UUID | `e3a92ae5-fe6c-4b28-a3b3-ad2212a80330` | same | SAME |
| profile application-identifier | `SK85S6YZP9.*` | same | SAME |
| normalized entitlements SHA-256 | `1048d467c69cf8b3bc4bae1995952ad2…` | same | SAME |
| `get-task-allow` | `true` | same | SAME |

A full `diff` of the two reports is empty apart from the intended `label:` line.

**Whole-artifact equality is the load-bearing result.** If the fetched bytes are
identical, every embedded signing structure is necessarily identical too; the
platform fields then establish that what stayed unchanged was a *validly signed
package* rather than a stable blob.

Entitlements are **normalized** (converted to canonical XML) before hashing, so
incidental formatting or key ordering cannot manufacture a difference that means
nothing about signing.

### What is claimed, and what is not

> For the tested iOS release-signing path, publishing a patch did not mutate the
> signed release artifact, its provisioning profile, or its entitlements.

**Not** claimed: anything about App Store distribution signing. This is technical
package signing on a development-signed release. Patch-artifact signatures and
RSA keys are Arm C and appear nowhere here.

## Comparator anti-vacuity

"Unchanged" is worthless from a comparator that forgot a field, so the comparator
was made to prove it notices. Both controls ran against **copies**; nothing
published was touched.

| control | result |
|---|---|
| flip one byte in a copied `App.framework/App` | `artifact_sha256` changed **and** `codesign_verify` went PASS → **FAIL** |
| flip one normalized entitlement field (`get-task-allow`) on a copy | normalized digest `1048d467…` → `b968db7c…` |

A third, found the hard way: the Android `signer_cert_sha256` field initially came
back **empty**, because `jarsigner` does not print fingerprints in that mode and
`keytool` indents them with a **tab** that the extraction pattern missed. An empty
field compares "equal" before and after while proving nothing about the signer.
Fixed to read the certificate out of the signature block, and it now reports
`92:CE:74:67:…`. Recorded because it is exactly the failure mode the control
requirement exists to catch.

## B2 · Android — BLOCKED on engine artifacts, not on signing

Everything B2 needs on the *signing* side is built and working. It is blocked one
layer down, on a fact about the engine cell model.

### Done, and reusable

**A purpose-built fixture** `selfhost/fixtures/android_signing_app` — a minimal
patchable app, new rather than an edit to a certified fixture, with the marker in
a function body behind a `DateTime` guard so a patch to it is visible to the
analyzer.

**A disposable release identity, and the control the debug finding earned.** A
2048-bit RSA keystore was generated for this arm only (never committed;
`key.properties` and `*.jks` are gitignored, the keystore lives outside the repo):

    KR (release) : C4:83:77:18:A7:3A:18:BB:60:B5:74:80:24:C4:A6:2E:
                   0F:FE:AB:1E:2E:E3:A8:55:A8:FF:12:92:28:D3:E5:F1
    KD (debug)   : AF:BB:93:80:94:49:04:12:BA:C1:B2:FA:F2:5D:27:94:
                   A5:A5:97:61:CC:A4:E1:E8:BE:5E:D0:F3:9A:90:57:E9
    KR != KD     : YES

**The cause of the earlier debug-signed AAB, confirmed at source.** Flutter's
generated `android/app/build.gradle.kts` ships:

    buildTypes { release { signingConfig = signingConfigs.getByName("debug") } }

So the release build type is *explicitly* signed with the debug key unless a
project overrides it. That is an app/Gradle-layer fact, not something Shorebird
imposes, and it is why the pre-existing published AAB carried
`CN=Android Debug`. The fixture now defines a real `signingConfigs.release` and
points `buildTypes.release` at it.

**App registered** on `cps-android`: `android-signing-b2`,
`2a476c0c-a4d1-0d8d-c791-74f2a78ad127`.

### Why the release cannot be cut here

`shorebird release android` fails while fetching engine artifacts:

    Failed to download http://localhost:8085/flutter_infra_release/flutter/
      ca7d2c0d43bf975db2c42cc0aa6351d527443abf/android-arm-profile/darwin-x64.zip
    Exception: 404

The active engine cell has **no Android artifacts**, and neither does any other
engine in the local CDN overlay — surveyed all of them, every entry is iOS-only.
The cell model as built is an iOS Route B vehicle.

The obvious workaround is worse than the blocker: activating a stock engine
(`69f9831c`) would supply Android artifacts, but the coherence gate landed earlier
in this lane requires every iOS `gen_snapshot` to advertise
`patchable_static_calls`, so it would refuse the build — correctly, by its own
rule. That gate checks the iOS compilers **regardless of the target platform**,
which is conservative for a Route B fork and is worth a deliberate decision rather
than a quiet relaxation.

### What B2 needs, and the decision it implies

Either **(a)** publish Android engine artifacts for the active cell, or **(b)**
scope the coherence gate's `gen_snapshot` check to the platform being built so an
Android release may run on a stock engine.

(b) is a one-line change but it weakens an invariant approved minutes ago, and the
weakening is not obviously safe: it would allow an Android release from a checkout
whose iOS half is incoherent. That is a call to make explicitly, not while
clearing a blocker.

**Nothing was faked.** No BEFORE/AFTER pair was produced, because with no release
there is nothing to measure and no patch to publish between measurements.
