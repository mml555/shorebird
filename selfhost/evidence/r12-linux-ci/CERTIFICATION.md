# R12 — CERTIFIED, 2026-08-30

**R12 CERTIFIED — clean noninteractive Linux/amd64 execution.** Fresh Linux/amd64
containers with no host mounts, no pre-existing Shorebird/Flutter caches, and no
credentials beyond the explicitly supplied API token successfully bootstrapped the
self-hosted toolchain from owned Shorebird/Flutter artifact bytes and completed
real `shorebird release android` and `shorebird patch android` workflows against
the self-hosted control plane in two independent clean executions.

The qualifying builder was Docker `linux/amd64` executed under emulation on Apple
Silicon. **Native x86-64 hardware performance and representative hosted-CI
hardware were not assessed.**

The two successful executions were independent but not identical in builder
resource configuration: Arm A used an R12-specific Gradle heap constraint required
by the smaller Docker VM; Arm B used no R12 Gradle override and is the more
faithful project-as-authored execution. This difference does not affect the
certified noninteractive workflow property.

Outside the owned Shorebird/Flutter artifact seal, and therefore not represented
as self-hosted toolchain artifacts: repository cloning from `github.com` at an
immutable full SHA, `pub.dev`, Google Maven, and Maven Central.

---

## The two arms

| | Arm A | Arm B |
|---|---|---|
| repo | `8254706c…`(evidence at `9e810673…`) | `e2c8834e…` |
| version | 1.1.0+1 | 1.1.3+1 |
| release | ✅ Published | ✅ Published |
| patch | ✅ Published Patch 1, promoted | ✅ Published Patch 1, promoted |
| arm 2 `--json` | exit 0, 0 prompt hits | exit 0, 0 prompt hits |
| arm 3 chooser | exit 64, named | exit 64, named |
| seal | 25 × 200 all overlay, 0 upstream | 25 × 200 all overlay, 0 upstream |
| gradle | R12 heap constraint (`-Xmx3g`) | no R12 override |
| VM | 7.75 GiB | 11.91 GiB |

Between the two checkouts the changes are confined to the R12 harness and R12
evidence — **no product or runtime source change sits between the successes.**

## What the repetition was for

To establish that success did not depend on hidden state carried from the first
container. Both arms independently had a fresh container, fresh `HOME`, no host
mounts, no caches crossing, a fresh ephemeral signing key, an unused release
version, the same Flutter/engine identities, the same control plane, the same
sealed owned-artifact path, and the same frozen harness.

## What is NOT claimed

The daemon's effective `-Xmx` in Arm B was **not directly observed**. Established
instead: the R12 `GRADLE_OPTS` override was removed, R12 writes no
`GRADLE_USER_HOME/gradle.properties`, the harness refuses to proceed if one
exists, the fixture's project configuration therefore remained the authored
configuration source, and the build completed with peak container memory
~5.955 GiB. The actual JVM heap ceiling is irrelevant to R12 unless Gradle JVM
configuration were being certified, which it is not.

## Not the same as "CI productionized"

R12 proves the noninteractive workflow works on a clean Linux builder. It does not
mean a maintained GitHub Actions or self-hosted-runner deployment pipeline exists.
That is an operationalization task, not a remaining parity-certification blocker.

## Path

    9916321c  preflight
    4f7ca8c0  cold-bootstrap prerequisite discovered
    ed82c667  69f owned-artifact bootstrap closure + sealed cold bootstrap PASS
    45b5d1c8  release/patch closure CLOSED
    8254706c  decisive Arm A PASS
    c77ff66c  decisive Arm B PASS
