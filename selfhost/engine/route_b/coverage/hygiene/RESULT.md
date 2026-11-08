# D-HYGIENE — CLOSED. Capture-avoiding receiver naming, and what it cost.

Two runs of the same eleven controls, on the same host, through the same
shipping producer. The only thing that changed between them is how the receiver
parameter is named.

    case                                  before        after
    A  local `self` in the method body    UNSAFE   ->   SAFE
    B  closure PARAMETER named `self`     UNSAFE   ->   SAFE
    C  closure param `self`, also used    UNSAFE   ->   SAFE
    D  target's own parameter `self`      LOUD     ->   SAFE
    E  local `self` in a nested closure   UNSAFE   ->   SAFE
    F  local FUNCTION parameter `self`    UNSAFE   ->   SAFE
    G  two nested closures over `self`    UNSAFE   ->   SAFE
    H  declaration holds candidate 0      UNSAFE   ->   SAFE
    I  declaration holds candidates 0-2   UNSAFE   ->   SAFE
    J  a legitimate MEMBER named `self`   SAFE     ->   SAFE
    K  no `self` in the declaration       SAFE     ->   SAFE

`before` is measured, not remembered: it is the mutation arm below.

Environment: engine tree `619fdad176ff4573…`, cell
`4792f0eca461f3761001a1adbe131b4b115e3684` (its `route_b_analyze.aot`
`14538a67…` and `route_b_gen_kernel.aot` `81e1d8f4…` match this host tree's
build outputs byte for byte). Producer driven through
`producer/cli_produce.dart` — `RouteBCoverageAnalyzer` + `RouteBProducer`, the
code `shorebird patch` runs.

## The repair

`_freshReceiverName` in `route_b_producer.dart`. The receiver parameter's name
is allocated to be fresh with respect to **every byte of the declaration being
copied**, and that one name is then used at all four generation sites: the
synthetic parameter, the `this.`-replacement edit, the `$NAME` interpolation
rewrite, and the bare prefix insertion.

    self                            when the declaration does not spell it
    shorebirdReceiver0, 1, 2, …     the first spelling the declaration is free of

**Not a scope model.** It does not decide which occurrences of `self` bind; it
declines to use a name any occurrence could bind. Comments and string literals
count, so `String selfTest()` and a comment mentioning "self" both get a
generated name they did not need. That direction is free. The other direction is
a patch that runs and means something else.

**Not private.** `__shorebird_receiver_0` was the obvious spelling and is wrong
here: a `_`-prefixed name is caught by the producer's own backstop against
private identifiers the release did not grant, and the fix would have been to
carve an exemption into a safety check. The property that matters is freshness,
not the spelling.

## The allocator is what holds — mutation arm

`mutation_test.sh` rewrites `_freshReceiverName` to return `self`
unconditionally — the pre-repair behaviour — reruns the suite, and restores the
producer from a checksummed backup under a trap.

    A B C E F G H I   UNSAFE   every capture case fails without the allocator
    D                 LOUD     same-scope collision, dart2bytecode refuses
    J K               SAFE     unchanged, and that is the point

Three buckets rather than one, because "the suite goes red" is not a single
claim. **J was in the red bucket in the first draft of this test and that was
wrong.** `self` there is a *member* read off the receiver — `this.self`, not a
binding — so it lowers correctly with or without the allocator. Demanding it go
red would have credited the repair with a case it does not fix. It is now a
control for the opposite property: the rename must not damage a member that
happens to be named `self`, and it does not (`shorebirdReceiver0.self.label`).

## Preservation — byte-identical, measured in one directory

`K` has no `self` in its declaration, so the allocator returns the default and
the emitted source must be exactly what it was before the repair.

    source    BYTE-IDENTICAL
    bytecode  BYTE-IDENTICAL

Both runs write to the **same** work-directory path. That is not fastidiousness:
the compiled bytecode embeds the replacement's absolute source path, so two temp
directories differ in the bytecode even when the source is identical. The first
attempt at this check compared `…/mut3/…` against `…/hyg_all/…` and reported a
3-byte container difference — exactly the difference in path length. A
same-length pair (`pa01`/`pa02`) then produced equal sizes and unequal bytes at
offset 383, inside the embedded URI. Neither reading had anything to do with the
repair.

## Regression

    hygiene suite, 11 controls          11 SAFE
    mutation arm                        PASSED (8 UNSAFE, 1 LOUD, 2 SAFE)
    preservation                        source and bytecode byte-identical
    route_b_producer_test.dart          64 passed (59 existing + 5 new)
    route_b_* CLI suites                128 passed, 1 skipped (no macOS fixture)
    coverage/parity.sh                  8 passed, 0 failed
    route_b_analyze.aot                 14538a67… unchanged — analyzer untouched

The five new unit tests pin the allocator's contract directly, including the one
that matters most: *the generated name does not occur in the declaration*.

## Scope held

No device, no cell mint, no engine change, no dart2bytecode change, no analyzer
change, no language-surface gate widened. The only production edit is
`route_b_producer.dart`; `cli_produce.dart` gained a `ROUTE_B_ENGINE_HASH`
override for the harness, default unchanged.

## What is still open, stated rather than closed by silence

* **`this` capture is a different question and still refused.** `foo(() =>
  consume(this))` is refused by the analyzer's unconsumed-`this` rule, not by
  anything here.
* **This does not decide D1.** Hygienic renaming closed the defect without a
  scope model, so the hygiene finding on its own does not argue for structured
  lowering. Whether D1 is worth doing goes back to being a coverage question,
  which is D0.2's job.
* **`host_equivalence.sh` still defaults to a stale cell** (`591a9f8d…`,
  predating `route_b_release_probe.aot`, so it fails validation). Harness debt,
  deliberately not fixed here.

## Reproduce

    WORK=/tmp/hyg bash selfhost/engine/route_b/coverage/hygiene/run_hygiene.sh
    WORK=/tmp/mut bash selfhost/engine/route_b/coverage/hygiene/mutation_test.sh
