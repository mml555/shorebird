# Constant blindness, second recorded instance

The manual-API fixture's first shape used a top-level const as the patch target:

```dart
const marker = 'MANUAL-V1';   // patch changes this to 'MANUAL-V2'
```

Release 3.0.0+1 (id 122) was cut against it, and the patch was **correctly
refused**:

    Verifying patch can be applied to release ... Done
    Nothing in this patch differs from the release, so it would install and
    change nothing.
    Nothing was uploaded.

## What this establishes

A changed const **declaration** is invisible to the coverage analyzer, which
compares procedure bodies. The const is not surfaced as a changed procedure, so
the change set is empty and the producer declines to publish a no-op.

This is the **same blindness the defines arm hit** (`evidence/p6-defines/
CONSTANT_BLINDNESS.md`), reached from a different direction: there the source was
identical and only a `String.fromEnvironment` value differed; here the source
literal itself changed, inside a const declaration. Both are invisible.

**The guard behaved correctly.** It refused rather than shipping a patch that
would install and change nothing — which is exactly the failure mode a
"successful" publication would have hidden until the device showed V1 forever.
It is a *capability* limit, not a correctness bug.

## Adaptation, recorded rather than quietly applied

The marker moved into a function body with the armor the flavor, custom-target
and obfuscation arms all used:

```dart
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'MANUAL-V1'
    : 'MANUAL-V1!';
```

Release **3.1.0+1** replaces 3.0.0+1 for this arm. 3.0.0+1 / release 122 is left
in place, unpatched, as the record of the refusal.

**Why the release had to be re-cut rather than the fixture merely edited:**
switching to a function-based marker adds a member, and a patch may not
introduce members — so against release 122 the new shape would have been refused
for a second, unrelated reason. The two options were "re-cut" or "abandon the
marker", and re-cutting costs one build.

## The debt this sharpens

Twice now, a fixture shape that reads naturally in Dart could not be patched, and
the refusal message says only that nothing differs. It does not say *why* — that
the change lived in a canonicalised constant the analyzer cannot see. A message
naming that case would have saved a release cycle here and in the defines arm.

Parked as a product debt, unchanged in scope: **the refusal is correct; the
diagnosis is missing.**
