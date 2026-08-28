# R12 — CI / noninteractive certification on a clean Linux builder

The frozen decision record for this lane. **Nothing here may be "improved" for
Docker mid-run.** If a shell or path assumption fails, classify the failure
before changing anything.

## Frozen parameters

    fixture         selfhost/fixtures/android_signing_app
    android signing ephemeral release keystore, generated INSIDE each container,
                    same key for release + patch within one arm, destroyed with
                    the container, no signing assertion made
    flutter         owned mirror, exact revision
                    a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    CLI             supported self-hosted CLI 1.6.115+selfhost.1, freshly
                    bootstrapped in the container
    producer        exact revision
                    fc184af6509a93eaf6fc068c6820639b324175a8
    fallback        NONE — no upstream Flutter/Dart/engine substitution
    workflow        the frozen selfhost/scripts/ci_noninteractive.sh, unmodified
    repetition      two independently fresh containers

If an owned Linux bootstrap artifact is absent: **stop at that exact artifact**,
report the URL, revision, slice and response, and do not repair during the
decisive arm.

## Why the toolchain is not in the image

`Dockerfile` is a **generic builder substrate only** — pinned Debian base, JDK,
Android SDK, basic utilities, accepted licences. It contains no Flutter, no Dart
and no Shorebird, and the build fails if any of them are present.

A preassembled image would prove that *a preassembled image works*. R12 is meant
to prove that a clean Linux CI builder can reproduce the supported environment
from owned bytes, so the toolchain is bootstrapped after the container starts.

## Boundaries the arm enforces on itself

The container gets **no host mounts at all** — not the working tree, not a
Flutter, Dart, Shorebird, pub or Gradle cache, not `~/.shorebird`. The toolchain
arrives over the network from owned services, and evidence comes back out with
`docker cp` afterwards so there is never a writable host path inside the arm.
`run_arm.sh` re-checks all of this from the inside and refuses to continue if any
of it is untrue, because an arm that quietly used a warm cache would be a no-op
that looks like a pass.

The only injected secret is `SHOREBIRD_TOKEN`. The Android keystore is minted in
the container rather than injected.

## Recorded adaptations — scope facts, not defects

**Emulation.** `linux/amd64` executed under emulation on Apple Silicon. The
published ELF x86-64 `gen_snapshot` runs there (Dart 3.12.2, exit 0). Native
x86-64 hardware and representative hosted-CI hardware are **NOT ASSESSED**, and
the certification language must say so.

**CDN and control-plane addressing.** Inside a container `localhost` is the
container, so the historical host-local endpoints are reached as
`host.docker.internal:8085` and `:18081`. Byte identity of the CDN was proved,
not assumed — see `../../evidence/r12-linux-ci/PREFLIGHT.md`.

**Flutter mirror transport.** The owned bare mirror is served over `git://` by
`mirror_service.sh` rather than bind-mounted, for the same reason the CDN is a
service: no host filesystem inside the arm. The launcher verifies the mirror
serves the *pinned revision*, not merely that it is up.

**Release version.** A release version is immutable on the control plane, so two
independent arms cannot both publish `1.0.0+1`. `run_arm.sh` sets the fixture's
pubspec version per arm. The harness derives its version from that same pubspec,
so it stays self-consistent and **unmodified**.

## Running it

    ./mirror_service.sh                     # owned Flutter mirror, verified pinned
    export SHOREBIRD_TOKEN=sb_api_…         # the one required credential
    export R12_REPO_SHA=<full 40-hex>       # owned CLI commit; a prefix is refused
    ./launch.sh A 1.0.0+1
    ./launch.sh B 1.0.1+1                   # a second, independently fresh container
