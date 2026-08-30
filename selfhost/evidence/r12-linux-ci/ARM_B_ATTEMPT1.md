# Arm B, first attempt — FAILED. Resource contention, and the evidence to say so
# was destroyed by my own collector.

Arm A passed. Arm B, same code and same settings, died in the release build:

    The message received from the daemon indicates that the daemon has
    disappeared.

## What is ruled out

**Not the artifact closure.** The seal over Arm B is identical to Arm A's:

    200, X-Overlay: hit    25
    200 not from overlay    0
    /gcs/ passthroughs      0
    502 sealed refusals     1   <- URI "/", the arm's own TLS reachability probe

**Not the heap override failing to apply.** Confirmed from the daemon's own
startup line in Arm B's log:

    daemonOpts=-XX:MaxMetaspaceSize=1g,-XX:ReservedCodeCacheSize=256m,-Xmx3g

So the remedy was in force and the daemon still died.

**Not the arms themselves.** Arm 3 passed (exit 64, chooser refused by name), and
both detector self-tests fired.

## What I cannot prove, and why

`OOMKilled` is the one fact that separates *killed by the kernel* from *crashed on
its own*, and it is unreadable: `launch.sh` destroyed the container as part of
collecting evidence, before recording it. **The evidence collector destroyed the
evidence.** That is a defect in the harness, now fixed — container state
(`ExitCode`, `OOMKilled`, `Error`) and host memory are captured *before* removal.

## The leading hypothesis, stated as such

The builder is **not isolated**. The Docker VM has 7.75 GiB total and is shared
with unrelated workloads; at inspection an unrelated `app_libpostal_test` held
1.519 GiB, alongside the coolify stack and two idle discovery containers I had
left running. An emulated release build asking for a 3 GiB heap plus a JVM, a
Dart process and qemu overhead has little margin left.

Arm A passing and Arm B failing under identical configuration is consistent with
contention, but **co-tenancy at inspection time is not proof of co-tenancy at
failure time**, and I did not record it during Arm A. So this is a hypothesis with
supporting circumstance, not a conclusion.

## What changed

    launch.sh   captures container state + host memory BEFORE removing the container
    launch.sh   prints docker VM MemTotal and co-tenant usage in preflight
    cleanup     my two idle discovery containers removed (the user's workloads
                were left alone — they are not mine to stop)

The next Arm B will therefore either succeed, or fail with `OOMKilled` recorded
and the memory picture alongside it. Either way the answer stops being a guess.

## Not banked

Arm B is not a pass and is not being presented as one. R12 stays BLOCKED on a
second independently clean arm.
