# `privatestate_app` — the P1 device specimen

A patch to a method of a **conventionally private Flutter `State` class**, whose
replacement body consumes explicitly granted private members of that class. This
is the shape Phase 0 said dominates real patches, and the shape the existing
device specimen does **not** cover: release `31.0.0+1` proved a private field on
a **public** class.

## Why a dedicated fixture

* **`killswitch_app` is excluded by policy.** Its events feed the frozen
  lifecycle estimator (`selfhost/MEASUREMENT_MODE.md`). An engineering
  qualification launch has no business entering fleet-policy evidence, and its
  own app identity keeps it out **by construction** rather than by another
  exclusion rule written afterwards.
* **`airgap_app` is `R6`**, which `PARITY.md` §16 calls "the sharpest
  serializer". Taking it would block other lanes for no reason.

## The precommitted shape

    release  ->  target=OLD      control=CTL
    patch    ->  target=NEW-FLD-GET-MTH   control=CTL   (unchanged)

`target()` is the only patched member. Its replacement must consume all three
private capabilities — the field, the getter and the method — so a PASS cannot
come from any one of them working alone.

## The negative control

`_withheld()` exists in the release and is **deliberately unused by the positive
patch**. It is kept live by a call through a `dynamic` receiver, so nothing can
inline or devirtualize the member away — the same construction as arm B4b of
`probes/p1_bind_private_receiver.sh`. Its job is to leave evidence in the release
that ungranted private reach is *withheld* rather than *absent*. The runtime
refusal itself is already proven on the host by B4b, so nothing here has to crash
a device to make the point.

## Four analyzer warnings, all intended

`_field`, `_getter` and `_method` are unreferenced **by the release**. That is
the production shape: a release cannot know which of its privates a future patch
will reach, so retention comes from the interface naming them, not from a call
site. `_withheld` is referenced only dynamically. `lib/main.dart` carries the
`ignore_for_file` with that reason attached.

## Scoring

PASS requires all of: the exact cell in the release lineage; baseline `OLD`; the
Route B artifact actually selected; `_FooState.target` in the receipt; attach
success; post-attach entry point equal to `InterpretCall`; the combined
`NEW-FLD-GET-MTH` rendered; and `control=CTL` unmoved.
