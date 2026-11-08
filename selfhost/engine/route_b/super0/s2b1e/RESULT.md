# D-SUPER-2B.1e — the lever is compilation REACHABILITY, not retention metadata.

Host only. No product wiring changed. `0015` stays UNSOUND AS DESIGNED. The patch
is identical in every variant (`s2b1d/armC_patch.dart`); only the RELEASE changes.

    variant                  release AOT   result
    control                     906,224    ABORT — Attempt to compile function
    E1  vm:entry-point on the
        mixin's own method      906,232    ABORT — identical abort   (+8 bytes)
    E2  mark the clone in
        the release Kernel            —    NOT ESTABLISHED (tool fault)
    E3  synthetic release root  923,048    PASS — TICKER:APP-STATE  (+16,824)

The **control is the mutation**: E3 minus the synthetic root is exactly the
control, and it returns to
`compiler.cc:1152: Attempt to compile function …__Leaf&Base&Ticker@…_close`. So
the root is what makes E3 pass.

## E1 — the source pragma does not reach the clone

    mixin Ticker on Base {
      @pragma('vm:entry-point')
      String close() => …

Both questions asked, and the one that matters answers **no**: whatever this does
for `Ticker.close` itself, it does **not** propagate to
`_Leaf&Base&Ticker.close`, the mixin-application clone the hierarchy actually
selects. Same abort, on the same function, for +8 bytes of snapshot.

That is worth stating plainly because it is the intuitive fix and it is wrong.

## E3 — a real super call in a retained root does work

    class Leaf extends Base with Ticker {
      @pragma('vm:entry-point')
      @pragma('vm:never-inline')
      String shorebirdSuperRoot() => super.close();

Never reached from `main`, kept by `vm:entry-point`, and its body is a genuine
`super.close()` — the same construct that forced the clone to be compiled in
arm B. The patch then binds and executes `TICKER:APP-STATE`.

**A dead branch would not do**, and that is not a guess: arm C's release already
retains the name and still aborts, and TFA has repeatedly been measured making
its own reachability decisions in this programme.

## E2 — not established, and not counted

Marking the clone directly in the release Kernel would be the cheap lever if it
worked. It could not be measured: rewriting the dill drops AOT metadata even with
every `package:vm` metadata repository registered before reading, and
`gen_snapshot` then fails with

    Missing table selector metadata!
    Probably gen_kernel was run in non-AOT mode or without TFA.

which blames the frontend for damage the transform did. The harness reports this
as **HARNESS FAULT / NOT ESTABLISHED** and does not score it — a tool fault must
not be readable as a product finding, which is the same discipline D0.1 needed.

So the question *"is marking the clone sufficient?"* remains **open**, and it is
the one that decides whether the broad capability is affordable.

## The cost, and why it should not be extrapolated yet

+16,824 bytes for **one** target, in a 906 KB toy. That is a large per-target
number, and if it held at scale a broad "compile every potential super target"
policy would be expensive: Wonderous alone has 44 super sites, and the set of
*potential* targets is much larger than the set of existing sites.

But this is one measurement on one synthetic app, where a single new compiled
function drags in whatever it transitively needs against a tiny baseline. **The
per-target cost in a real app is unmeasured**, and E2 — if it works — might cost
almost nothing. Do not price the broad capability off this number.

## Two notions of "available", now permanent

    NAME RETAINED           the dynamic interface grants it; it can be found
    FUNCTION CODE COMPILED  AOT emitted executable code for it

`super` direct dispatch needs **both**. The capability manifest describes the
first and must not be silently reused as evidence of the second. If a reliable
compilation-root mechanism is found, the release needs to publish that fact
separately — a `directCallCompiledTargets` set or an equivalent derivable from
release generation — so the patch path can fail closed before publication rather
than aborting inside a user's app.

## Recommendation

Given E1 is disproven, E2 unmeasured, and E3 expensive-looking, the **narrow v1**
now looks like the right first product:

> Admit a patched super site only when the RELEASE itself contained a super
> invocation resolving to the same semantic target — which is proof that target
> had to be compiled.

Arm B is exactly that case, and D0's demand is lifecycle methods where the patch
modifies code *around* an existing `super.dispose()` rather than introducing one.
The admission test should use the cross-kernel **provenance fingerprint** already
proven in 2A.2 (`fileUri | fileOffset | name | kind`), not a source-offset
comparison — 2B.1c-SITE is exactly why.

Arm D (an ordinary superclass, introduced site) would be a false negative under
that rule. That is acceptable for v1; an abort is not.

## Reproduce

    WORK=/tmp/1e bash selfhost/engine/route_b/super0/s2b1e/run_2b1e.sh

Exits non-zero: the control is expected to fail, and E2 is not established.
