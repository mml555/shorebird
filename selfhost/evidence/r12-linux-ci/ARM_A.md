# Decisive Arm A — PASS

One uninterrupted run, fresh container, sealed cold owned mirror, noninteractive
throughout. Nothing stitched in from discovery.

    repo        9e8106735c1234167de72f9aa3b281d3ceaedac6
    producer    fc184af6509a93eaf6fc068c6820639b324175a8
    flutter     a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61 (owned mirror)
    engine      69f9831c360d9152862ec3897c67fb09ae843f3b
    mirror      https://host.docker.internal:8087 — SEALED, own empty cache,
                CA validation enforced
    control pl. http://localhost:18081 — the historical endpoint, reached by
                forwarding the container's own loopback
    version     1.1.0+1 (unused)
    key         ephemeral release keystore, minted in-container, died with it

## Preflight

    REVISION ACCEPTED  fc184af6509a93eaf6fc068c6820639b324175a8
    CLOSURE OK  a4a3c0d1b1b0f997 -> 69f9831c360d9152  (2 artifacts, size + sha256)
    proxy mapping pinned: manifest f1e398c80973e969 -> flutter_engine_revision 83675ed2
    flutter/dart/shorebird absent from PATH, no caches, NO host mounts

## The frozen ci_noninteractive.sh, unmodified

    self-test A   exit 64   'non-interactive context' lines: 1   (expected >=1)
    self-test B   exit 64   interactive_prompt_required: 1       (expected >=1)
    arm 1 release exit 0    ✅ Published Release 1.1.0+1!  (AAB 46.4MB)
    arm 1 patch   exit 0    ✅ Published Patch 1!  (promoted to stable)
    arm 2 --json  exit 0    interactive_prompt_required: 0       (expected 0)
    arm 3 chooser exit 64   named it: "Which release would you like to patch?"
    verdict       PASS
    arm A exit    0

The self-tests are what make arm 2's zero meaningful: a reached prompt DOES exit
64 and IS named in both output modes, so "0 hits" is a measurement rather than a
broken grep. Arm 3 is the only arm that exercises `release_chooser.dart`, and it
refused by name — outcome 11, the good failure.

## The seal held, measured from the mirror's own log

    200, X-Overlay: hit    25
    200 not from overlay    0
    /gcs/ passthroughs      0
    502 sealed refusals     1   <- URI "/", the arm's own TLS reachability probe
                                   against the mirror root, which has no overlay
                                   file. Not an artifact.

Every artifact the release and the patch consumed came from owned bytes, on a
mirror that could not have reached upstream if it had wanted to.

## What this does NOT claim

Native x86-64 hardware and representative hosted-CI hardware: **NOT ASSESSED**
(emulated linux/amd64 on Apple Silicon).

External dependencies not represented as owned Shorebird/Flutter artifacts, and
outside the seal: github.com (repo clone at a full immutable SHA), pub.dev
(package resolution), Google Maven and Maven Central (AGP/Kotlin).

Gradle ran with a bounded heap (`-Xmx3g` via `GRADLE_USER_HOME`) because the
fixture asks for 8G and the VM has 7.75GiB. That constrains the builder, not the
product; the fixture is unmodified.

R12 needs a second, independently fresh arm before the row moves.
