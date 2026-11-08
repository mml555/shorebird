# R12 preflight — the blocker is real, and a qualifying Linux builder exists

Discharges the preflight conditions before the decisive arms. **No decisive arm has
run yet.**

## The blocker, re-verified with the REAL revision

    cell                                        linux-x64   darwin-x64
    fc184af6509a93eaf6fc068c6820639b324175a8       200         404
    dabf1837976819e5da33f3e143c4f628749702da       200         302
    5b1a89658709b9a0d2e76c6f3d47ad1a26eecdee       200         404

The 2026-08-14 asymmetry reproduces exactly: our Route B Android cells publish a
**linux-x64 producer only**. The decisive arms cannot run on a Darwin host. A
missing prerequisite, not a failed gate.

### A preflight-harness error, and the guard that now prevents it

My first probe used a revision I **fabricated** by padding the 8-character prefix
`fc184af6` out of the evidence file to 40 characters. It returned **404 for both
slices**, which looks precisely like the blocker having changed — and
`arms_blocker_reverified.txt`, the file I took the prefix from, warns in as many
words that *"probing the wrong revision produces a symmetric answer that resembles
a finding."* I walked into a documented trap minutes after reading it.

A note in an evidence file did not prevent that, so it is now a check.
`ci/r12_revision_guard.sh` refuses unless the revision is 40 lowercase hex, resolves
to a cell that exists in the overlay, publishes `android-arm64-release/linux-x64.zip`,
and is served 200. Mutation-tested:

| input | result |
|---|---|
| `fc184af6` (the prefix) | REFUSE — *"A PREFIX IS NOT A REVISION"* |
| my fabricated 40-char SHA | REFUSE — no such cell |
| the real SHA uppercased | REFUSE — not lowercase hex |
| `4792f0ec…` (an **iOS** cell) | REFUSE — publishes no linux-x64 producer |

The last row matters most: an iOS cell 404s for **both** host slices, which is the
symmetric non-finding that started this.

## The qualifying builder

    host                Darwin arm64 (Apple Silicon)
    docker server       linux/arm64
    container platform  linux/amd64, executed under EMULATION
    uname -s            Linux
    uname -m            x86_64
    distro              Debian GNU/Linux 13 (trixie)

### The decisive fact: the published Linux producer EXECUTES

    slice     android-arm64-release/linux-x64.zip from fc184af6509a93ea…
    producer  gen_snapshot
    file      ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked
    sha256    82b794073e2d5d2f93e0a72c30bb24d8e1b3bc3e776a620d1f2ad562adfcecae

    $ gen_snapshot --version
    Dart SDK version: 3.12.2 (stable) (Wed Jul 29 18:18:37 2026 +0000) on "linux_simarm64"
    exit 0

Emulated x86-64 execution does not change the Linux ABI, the producer bytes, the
CLI behaviour under test, or the control-plane interaction. **Recorded as a scope
fact, not a defect**, and the certification language is fixed accordingly:

> R12 CERTIFIED for clean noninteractive Linux/amd64 execution. The qualifying
> builder was a Docker Linux/amd64 environment executed under emulation on Apple
> Silicon. Native x86-64 hardware performance and representative hosted-CI
> hardware were **not assessed**.

## CDN addressing — a network-namespace adaptation, proven not to be a different CDN

Inside a container `localhost` is the container, so the historical host-local
endpoint is reached as `host.docker.internal:8085`. The backing service and
artifacts are unchanged, and that is measured rather than asserted — the same
object fetched both ways:

    host      localhost:8085              e1c6402eb76cf7c38ea732628949b5b52c8e2f6c909339081509c7e48a2f35d6
    container host.docker.internal:8085   e1c6402eb76cf7c38ea732628949b5b52c8e2f6c909339081509c7e48a2f35d6
    IDENTICAL

> Docker network-namespace adaptation: the historical host-local CDN endpoint
> `localhost:8085` is reached from the Linux container as
> `host.docker.internal:8085`. Backing service and artifacts unchanged.

Not a product or configuration finding.

## What the decisive arms still require

`ci_noninteractive.sh` needs `--app-dir` and drives `shorebird release android` and
`shorebird patch android --no-confirm` against our control plane. So the container
must additionally carry a fresh Flutter/Dart toolchain, the Android SDK and a JDK,
and a freshly bootstrapped Shorebird CLI — with a fresh `HOME`, no host
`~/.shorebird`, no mounted caches, no developer credentials, and noninteractive
auth only.

That build is the next step. **Nothing in the certified runtime is touched by it.**
