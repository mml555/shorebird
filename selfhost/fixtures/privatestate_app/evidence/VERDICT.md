# P1 device specimen — FAILED AS PRECOMMITTED, and it found a real producer bug

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
