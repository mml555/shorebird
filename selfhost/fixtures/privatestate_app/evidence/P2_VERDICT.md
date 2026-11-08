# P2 device specimen — PASS. Required-positional ABI on physical iOS.

Run 2026-08-25. `privatestate_app`, release `1.0.2+1`, patch 1, cell
`93a375665d637f999bbff028488301a510bb611e`, iPhone 7 / iOS 15.8.8, wired.

    release   ->  target=OLD   args=OLD           control=CTL
    patched   ->  target=OLD   args=NEW-A-7-FLD   control=CTL
    rollback  ->  target=OLD   args=OLD           control=CTL

One positive required-positional patch plus rollback. Nothing else was sent to the
phone.

## Scored against the precommitted table

| condition | required | observed |
|---|---|---|
| target | `_FooState.targetArgs` in the receipt | `sel=_FooState.targetArgs` |
| release identity | built-for == running | both `f5bcf33fd53e36bb8bb4bf8f6aab3b73` |
| attach | `rc=0`, entered + returned | `rc=0 attach_entered=1 attach_returned=1` |
| bytecode | `bc_post=1` | `bc_post=1` |
| interpreted | `interp_post=1` | `interp_post=1` |
| dispatch | `uep_post_is_interpret_call=1` | `1`, with `fn_uep_post=0x105840044` == `interpret_call_ep=0x105840044` |
| receiver | a private `_FooState` instance works | the body read `self._field` and got `FLD` |
| **arg 0** | `String label` arrives as `A` | `NEW-A-…` |
| **arg 1** | `int count` arrives as `7` | `…-7-…` |
| private access | same body consumes a granted private member | `…-FLD` |
| control | unrelated value unchanged | `control=CTL` in all three states |

## Two discriminators that came for free

* **`target=OLD` throughout.** `target()` and `targetArgs()` are both methods of
  the same private class and only the second was patched. A lowering that attached
  to the wrong member of `_FooState` would have moved this line.
* **Asymmetric argument values.** `A` and `7` cannot be swapped into a plausible
  result: swapped binding renders `NEW-7-A-FLD`, a visibly different string. The
  host probe already owns the fine-grained order discrimination
  (`p2_private_receiver_with_args.sh` D0 `A-L-7` against D2 `A-7-L`); this
  specimen only had to avoid being satisfiable by a swap, and it is not.

## The lowering that was under test

    source   String targetArgs(String label, int count) => 'NEW-$label-$count-$_field';
    emitted  String targetArgs(dynamic self, String label, int count) =>
                 'NEW-$label-$count-${self._field}';

The receiver is prepended, so **both source parameters shift by one** — that shift
is the thing this specimen exists to check on hardware, and it is also why P1's
no-argument proof did not cover it. Note the two locals stay bare interpolations
while only the receiver access is braced: the interpolation fix from the P1
specimen is scoped to receiver accesses and did not over-reach.

## Rollback

Patch withdrawn with `rollback=true`
(`{"withdrawn":true,"patch_id":77,"rolled_back":true}`); after two tap-launches
`args=OLD` and the updater is pristine — `next_boot_patch`, `last_booted_patch`
and `currently_booting_patch` all null, `boot_attempt_count` 0, `patches/` empty.

## What is deliberately NOT here

* **No named or optional-positional patch was sent to the phone.** The negative
  proof already exists at the right layer: the same shipped compiler refuses both
  before publication, against identical release bytes
  (`g37_param_abi.sh`, and `p2_private_receiver_with_args.sh` D3). Sending an
  unsupported shape to hardware would test nothing new.
* **No type arguments.** Generic instantiation is not carried by the payload.
* **No compatibility percentage.** P1.5 produced no blocker ranking; see
  `ROADMAP.md`'s P1.5 banner. This specimen says the ABI works, not how much of
  real-world Dart it unlocks.
