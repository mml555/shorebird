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

## B2 · Android — CLOSED

App `android-signing-b2` (`2a476c0c-…`) on `cps-android`, release **1.0.0+1**
(server id **12**), fixture `selfhost/fixtures/android_signing_app`. AAB only —
that is the release surface this workflow publishes, and no APK was manufactured
to create extra certification work. No Android device.

### Precondition: a real release identity, not the debug key

A disposable 2048-bit RSA keystore was generated for this arm (never committed;
`key.properties` and `*.jks` gitignored, keystore outside the repo):

    KR (release) : C4:83:77:18:A7:3A:18:BB:60:B5:74:80:24:C4:A6:2E:
                   0F:FE:AB:1E:2E:E3:A8:55:A8:FF:12:92:28:D3:E5:F1
    KD (debug)   : AF:BB:93:80:94:49:04:12:BA:C1:B2:FA:F2:5D:27:94:
                   A5:A5:97:61:CC:A4:E1:E8:BE:5E:D0:F3:9A:90:57:E9
    KR != KD     : YES

The built AAB's signer is **KR**, so the earlier debug-key observation is now a
working control rather than an anecdote.

**The cause of that observation, confirmed at source.** Flutter's generated
`android/app/build.gradle.kts` ships
`buildTypes { release { signingConfig = signingConfigs.getByName("debug") } }`,
so release builds are *explicitly* debug-signed unless a project overrides it.
That is an app/Gradle-layer fact, not something Shorebird imposes — which is why
this row proves **preservation**, not enforcement.

### Result

| Property | Before patch | After patch | Result |
|---|---|---|---|
| AAB SHA-256 (server-fetched) | `3eedee454b3ed4795554416d320d4211…` | same | **SAME** |
| `jarsigner -verify` | PASS (`jar verified.`) | PASS | **PASS/PASS** |
| signer cert SHA-256 | `C4:83:77:18:…` (= **KR**) | same | **SAME** |
| signer DN / owner | `CN=Shorebird B2 Release Test, OU=Selfhost Certification, O=Disposable, C=US` | same | SAME |
| signature algorithm | `SHA256withRSA, 2048-bit key` | same | SAME |

A full `diff` of the two reports is empty apart from the intended `label:` line.
The server-fetched AAB is also byte-identical to the locally built one, so the
control plane stored exactly what Gradle signed.

Patch 1 was published against that release between the two measurements
(`ANDROID-SIGN-V1` → `V2`); its body is irrelevant to this arm.

### Anti-vacuity

| control | result |
|---|---|
| required field unreadable | reports **`UNDETERMINED`** and exits 3 — missing is not unchanged. Mutation-checked by stripping a signature: three iOS fields go UNDETERMINED and the measurement fails |
| one byte appended to an entry in a **copied** AAB | digest changed **and** `jarsigner` went PASS → **FAIL** |

The altered entry was `BUNDLE-METADATA/…/dependencies.pb`; both copies were
deleted and the published release was never touched.

### What unblocked it

B2 was blocked because the active engine cell carries no Android artifacts and
the coherence gate demanded Route B iOS compilers before *any* platform could
build. That gate is now **platform-scoped**: universal stamp and host-SDK checks
for every platform, the `gen_snapshot` capability check for iOS only, and Android
builds state explicitly that *iOS Route B capability: NOT EVALUATED*. The causal
pair is pinned by test — the same checkout with the same non-Route-B iOS compiler
passes for `android` and refuses for `ios`.

The Android release was then cut from a **separate** root (the repo-tree
entrypoint, its own cache, base engine `69f9831c`), leaving the coherent iOS/device
checkout untouched. Artifacts resolved over the default HTTPS path: the local CDN
serves them (302 to upstream) but Gradle refuses plain-HTTP Maven repositories
without an explicit opt-in, and the TLS CDN variant was not running — so rather
than reconfigure CDN containers for a signing test, the supported default path was
used.

### The claim

> A release deliberately configured with a non-debug Android release signing
> identity was published as a validly signed AAB. Publishing a Shorebird patch
> did not mutate that server-fetched AAB or change its signing certificate.

Not claimed: that Shorebird prevents debug signing, anything about Play Store
acceptance or Play App Signing, upload-key rotation, APK signature schemes, or
Android device patch execution.

