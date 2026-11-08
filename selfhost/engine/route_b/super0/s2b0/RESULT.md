# D-SUPER-2B.0 — source is the authority for argument presence. PASS.

Host only. **No super support is implemented or claimed by this commit.** It
lands the argument gate and its control ahead of the feature, so the repair for
the TFA hole is evidence in its own right rather than a detail inside a support
implementation.

## The division of authority, now enforced rather than described

    AOT kernel     a genuine super operation exists here, and what it retains
    PATCH SOURCE   what the developer actually wrote          <-- this lane
    import kernel  what that super means locally (dart2bytecode, proven in 2A.2)

## The three-kernel fact, re-measured by the control rather than remembered

    import kernel: ArgChild site args        2
    AOT kernel:    ArgChild site args        0
    site offset is the SAME in both       1066

One site, `super.tag('a', 7)`. TFA specialised `ArgParent.tag` for its single
call site: the parameters are gone and the two values are frozen into the callee
as constants, so the AOT call site passes nothing.

The offset is stable across the boundary, which is what makes it usable as the
key the source gate reads from.

## The shipping gate

`routeBSuperCallArgs` (`route_b_super_source.dart`), run at those exact offsets:

    source gate: super.tag('a', 7)      hasArguments
    source gate: super.plain()          zeroArguments

Three outcomes, and only `zeroArguments` admits. `unverifiable` is a refusal, not
a shrug: an offset that does not name the member, a missing `super.` prefix, a
super tear-off with no argument list, a comment between `super` and `.`. Reading
comments backwards cannot be done correctly without lexing the file forward — a
`*/` can sit inside a string — so that case is refused rather than mis-lexed.
Under-reading is safe here; over-reading is not.

`super.foo<int>()` reports `hasArguments` rather than `unverifiable`: it is
perfectly readable, and it is a shape v1 declines.

## The mutation, stated rather than implied

> An admission rule of "AOT call-site args == 0" would **ADMIT**
> `super.tag('a', 7)` — the AOT kernel reports 0 arguments for it. The source
> gate refuses the same site.

The control fails loudly if the AOT kernel ever stops reporting 0 there, because
at that point the specimen would no longer demonstrate the hole and every result
above it would be worth nothing.

## Tests

    route_b_super_source_test.dart   6 passed
      admits an empty list, including across newlines, nested block comments,
      and `super . plain()`
      THE CONTROL: refuses super.tag('a', 7)
      refuses every argument shape, including `named:` and a closure literal
      refuses a generic super invocation
      refuses what it cannot read: bad offset, out of range, no `super.` prefix,
      a tear-off, a comment before the `.`
      does not match `tag` inside `tagged`

## What is deliberately NOT here

* No analyzer change, so `analysisVersion` stays **9**. The analyzer still
  refuses every super site; nothing pretends support exists.
* No producer wiring, no intrinsic, no compiler change.
* The compiler-side backstop — so a producer bug cannot turn
  `super.tag('a', 7)` into an intrinsic indistinguishable from `super.tag()` —
  belongs to 2B.1 and is not attempted here.

## Reproduce

    WORK=/tmp/2b0 bash selfhost/engine/route_b/super0/s2b0/run_2b0.sh
