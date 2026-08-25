# P1 device specimen — PASSED on the second attempt, after the first found a real producer bug

> **UPDATE 2026-08-25, patch 2.** With the interpolation lowering fixed
> (`9125eb13`), the device renders **`target=NEW-FLD-GET-MTH`** with
> `control=CTL` unmoved — the precommitted string, exactly. Seven of the eight
> conditions are now met with device evidence; the eighth (a device screenshot of
> the release baseline rendering `OLD`) was never captured and is called out
> honestly at the end. **The original failure below is kept in full**, because the
> bug it found is the most useful thing this specimen produced.
>
> | condition | evidence |
> |---|---|
> | exact target/library in the receipt | `lib=package:privatestate_probe/main.dart` `sel=_FooState.target` |
> | attach succeeds | `rc=0 attach_entered=1 attach_returned=1`, receipt `applied 1/1 targets, entering main` |
> | post-attach entry point IS `InterpretCall` | `uep_post_is_interpret_call=1`, and `fn_uep_post=0x107440044` == `interpret_call_ep=0x107440044`, sampled in the same run |
> | interpreted after attach | `bc_post=1 interp_post=1` |
> | release identity matched | receipt `built-for=32c5766f…` == `running=32c5766f…` |
> | UI renders the combined private field/getter/method | **`target=NEW-FLD-GET-MTH`** (`03_patch2_applied.png`) |
> | unrelated same-screen control unmoved | `control=CTL` |
> | withheld member still live in the release | `kept=WTH` |
>
> **What this closes.** A Route B patch replaced a method on an idiomatic private
> Flutter `State` class on physical iOS hardware, and the replacement consumed an
> explicitly granted private **field**, private **getter** and private **method**
> through the shipped member-only capability model, with construction withheld.
> That is exactly the gap release `31.0.0+1` left open — it proved a private field
> on a *public* class.
>
> **The one condition not observed on device: the `OLD` baseline.** To save a
> round trip I published patch 1 before the first tap, so launch 1 downloaded it
> and launch 2 applied it; no launch ever rendered the release body. The release
> source returns `'OLD'` and the patch is what changes it, but that is an argument
> rather than an observation. Closing it costs one rollback and two taps, and
> would demonstrate rollback-to-pristine on this specimen at the same time.

---

## The original run, kept because its failure is the finding

Run 2026-08-25. Release `1.0.1+1`, patch 1, cell
`93a375665d637f999bbff028488301a510bb611e`, iPhone 7 / iOS 15.8.8, wired.

## Scored against the precommitted table

| condition | result |
|---|---|
| exact cell `93a3756…` in the release lineage | **PASS** — `route_b.json.engineRevision`, and `dynamic_interface.yaml` with **0 bare private class items** (only the new generator emits that) |
| Route B artifact actually selected | **PASS** — `InterpretCall` in the shipped `Flutter.framework`; release patchable at **1,802 sites/MiB** (threshold 100) |
| exact `_FooState.target` in the receipt | **PASS** — published container names `package:privatestate_probe/main.dart#_FooState.target`, release build id `32c5766f…` |
| construction withheld | **PASS** — 0 unnamed-constructor grants in the shipped interface |
| attach succeeds, patched body runs | **PASS** — the rendered string begins `NEW-`, which only the replacement produces |
| private METHOD call | **PASS, and it is new** — `-MTH` is `self._method()` returning on device. This was host-proven only until now |
| unrelated same-screen control unmoved | **PASS** — `control=CTL` |
| **UI renders the combined field/getter/method result** | **FAIL** — rendered `NEW-Instance of '_FooState'._field-Instance of '_FooState'._getter-MTH` instead of `NEW-FLD-GET-MTH` |

**Not a pass.** The precommit required the combined value; two of the three private
accesses rendered wrong. Recorded as a failure rather than rescored, because the
whole point of precommitting was to stop exactly this kind of after-the-fact
reinterpretation.

## The bug, which is worse than the miss

The producer's lowering inserts a receiver prefix immediately before the
identifier. That is correct in ordinary expression position and **wrong inside a
simple `$identifier` string interpolation**. The emitted replacement was:

    String target(dynamic self) =>
        'NEW-$self._field-$self._getter-${self._method()}';

In Dart, `$self._field` means *interpolate `self`, then the literal text
`._field`* -- so the receiver's `toString()` is rendered followed by the member
name as text. The braced `${self._method()}` is unaffected, which is why exactly
one of the three accesses worked.

**Nothing failed.** It compiled, attached, executed, and rendered plausible text.
That is the silent-wrong class this project is organised against -- the same shape
as "attach, report success, do nothing", and it would have shipped a patch whose
UI quietly showed `Instance of '_FooState'._field` to a user.

`PARITY.md`'s proven spellings are plain reads (`label`, `this.label`,
`helper()`); a receiver access inside an interpolation was never among them, so
this was untested rather than regressed.

## What it does and does not license

**Does:** the capability model works on device for the idiomatic shape. A patch
attached to a method of a conventionally private `State` class and called a
private method of that class, on hardware, under the member-only interface with
construction withheld.

**Does not:** the P1 device claim as written. The field and getter reads were not
demonstrated on device, because the lowering mangled them before they ever ran.

## Fix, then re-run

The lowering must handle an access whose identifier is immediately preceded by
`$`: rewrite `$NAME` to `${self.NAME}` rather than inserting a bare prefix, or
refuse the target. Refusing is the safe default this project usually prefers, but
`'$_count'` is an everyday Flutter idiom, so a correct rewrite is worth more than
a refusal here. Either way it needs a red-first test at the producer level.
