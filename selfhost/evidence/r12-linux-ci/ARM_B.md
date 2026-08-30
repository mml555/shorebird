# Decisive Arm B — PASS

Independently fresh container, its own ephemeral key, unused version, no caches
crossing from Arm A. **And no Gradle override**: Arm B ran under the heap the
fixture itself declares.

    repo        e2c8834edd346f9ae03a9f893c4263d31f1d166c
    producer    fc184af6509a93eaf6fc068c6820639b324175a8
    flutter     a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61 (owned mirror)
    engine      69f9831c360d9152862ec3897c67fb09ae843f3b
    mirror      https://host.docker.internal:8087 — SEALED, brand-new empty cache,
                CA validation enforced
    control pl. http://localhost:18081 — the historical endpoint, via loopback forward
    version     1.1.3+1 (unused)
    gradle      NO override; android/gradle.properties governs, -Xmx8G included
    builder     Docker VM 11.91 GiB / 9 CPUs, emulated linux/amd64
    container   exit=0  oomkilled=false  22:56:27 -> 23:11:40 (15m13s)

## The frozen ci_noninteractive.sh, unmodified

    self-test A   exit 64   'non-interactive context' lines: 1   (expected >=1)
    self-test B   exit 64   interactive_prompt_required: 1       (expected >=1)
    arm 1 release exit 0    ✅ Published Release 1.1.3+1!  (AAB 46.4MB)
    arm 1 patch   exit 0    ✅ Published Patch 1!  (promoted to stable)
    arm 2 --json  exit 0    interactive_prompt_required: 0       (expected 0)
    arm 3 chooser exit 64   named it: "Which release would you like to patch?"
    verdict       PASS
    arm B exit    0

## The seal held

    200, X-Overlay: hit    25
    200 not from overlay    0
    /gcs/ passthroughs      0
    502 sealed refusals     1   <- URI "/", the arm's own TLS reachability probe

Identical to Arm A. Every artifact from owned bytes.

## One thing I did NOT directly verify

The release log at its normal verbosity does not print Gradle's daemon context
line, so I cannot quote the actual `-Xmx` value Arm B's daemon ran with. What is
established instead: the harness no longer sets `GRADLE_OPTS` (removed and
verified absent), the arm writes no `gradle.properties`, and it **fails closed**
if one is present in `GRADLE_USER_HOME`. The arm recorded

    gradle properties        : NONE — the fixture's android/gradle.properties
                               governs, including its -Xmx8G

Peak observed container memory was 5.955 GiB, consistent with an 8 GiB-ceiling
heap that never filled. That is strong circumstantial support, not a direct
reading of the flag.

## Arm A / Arm B asymmetry, stated plainly

Arm A ran with `-Xmx3g` forced, because the VM then had 7.75 GiB and the fixture
asks for 8 G. Arm B ran with the fixture's own settings on a 11.91 GiB VM. The two
arms are therefore **not identically configured**. Arm B is the more faithful of
the pair, and both passed.
