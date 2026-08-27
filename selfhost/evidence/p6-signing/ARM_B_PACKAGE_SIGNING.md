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

## B2 · Android — NOT DONE, and why

The invariant is unproven on Android, and cannot be closed from here without a
new release cycle.

**What was measured.** The only Android release surface the fork actually
publishes for the existing app is an `aab` (there is no APK artifact, so none was
manufactured). Release 7 / `1.7.0+1` of app `5653c73c-…` on `cps-android`:

    container/artifact SHA-256 : f87d45e30ef204613b0165f28923dfe6…  (47,400,740 bytes)
    aab_verify                 : PASS  ("jar verified.")
    signature_algorithm        : SHA256withRSA, 2048-bit key
    signer_cert_owner          : C=US, O=Android, CN=Android Debug
    signer_cert_sha256         : 92:CE:74:67:A0:E4:2F:CA:7B:9C:C5:50:04:EF:92:C5:
                                 FE:4A:A5:24:5A:64:A7:CF:87:68:36:7F:6A:6D:83:FA

**Finding worth keeping independently of Arm B:** that published AAB is signed
with the **Android debug key**, not a release identity. It verifies, but nothing
in the release path required a release keystore.

**Why the before/after could not be taken.** The arm needs a patch published
*between* two measurements. App `5653c73c-…` belongs to lane D's `rbtest-android`
project (`evidence/g10.2-noninteractive/`), whose source is **not in this
repository**, so no patch can be built against release 7. Its existing patches 1–3
predate any BEFORE measurement, so they cannot substitute.

**What B2 needs, scoped.** A dedicated Android cycle: a disposable release
keystore and `signingConfig` (test material, not production identity), a fresh
app on `cps-android`, one signed release, then one patch published against it with
`armb_measure.sh` run either side. The tooling is already in place — the
comparator handles both `aab` and `apk`, and `jarsigner`/`keytool` are available
(`apksigner` is not on PATH, which only matters if an APK surface is added).

Not started rather than half-done: a BEFORE/AFTER pair with no patch between them
would be an empty comparison dressed as a result.

## Tooling

* `scripts/signing_state.sh` — measures one artifact; iOS via `codesign` /
  `security cms` / normalized entitlements, Android via `jarsigner` + `keytool`,
  with `apksigner` for APKs. Never modifies its input.
* `scripts/armb_measure.sh` — fetches a named artifact for a release from the
  control plane and runs the above. BEFORE and AFTER call the *same* script, so a
  difference in method cannot masquerade as a difference in the artifact.
