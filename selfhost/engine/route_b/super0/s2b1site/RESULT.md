# 2B.1c-SITE — **STOP.** A patched source offset is not an identity in the release body.

Host only. Nothing changed in the product. The throwaway compiler patch was
applied and restored from a checksummed backup.

## Leg 1 — what a `fileOffset` is stable across

    site                              RELEASE     PATCH     PATCH
                                       import    no-AOT       AOT
    LifeState.target super.close         1951      1886      1886
    LifeState.target super._quiet        1968      1903      1903

    stable across OPTIMIZATION of one source version   YES
    stable across SOURCE VERSION                       NO

The two source bodies differ, so the offsets differ — by 65, uniformly. Nothing
surprising, and exactly what makes the current rule wrong: **0015 takes the
offset the analyzer read from the PATCHED kernel and searches the RELEASE import
kernel's original body for a site at that offset.**

`s2b1/run_2b1.sh` could not have caught this. It authors its own replacement
against the UNPATCHED source and points at that source's own site, so release and
patch are the same body there. The isolated harness proved the primitive; it
could not prove the pipeline.

## Leg 2 — the dangerous direction, MEASURED

Offsets simply not matching is the safe failure: the compiler refuses. The hazard
is a program where they coincide. So one was built — release and patch
byte-aligned at the site, `(   )` and `('x')` both five characters:

    release   String original() => super.close(   );     offset 1074, 0 args
    patch     String original() => super.close('x');     offset 1074, 1 arg

Same offset. Same member name. Every guard in 0015 except the argument check
passes, and the argument check is reading the release body.

    compiler ACCEPTED.
      release super call  : BASE:NONE:APP
      virtual             : LEAF:v:APP
      patched             : BASE:NONE:APP

      the patch author wrote : super.close('x')   -> BASE:x:APP
      what actually executes : BASE:NONE:APP

**Silent wrong semantics.** The compiler verified the release body's empty
argument list for a site the patch wrote with one argument, emitted a
receiver-only `DirectCall`, and the patch runs and returns a different value than
the source it stands in for. No refusal, no crash, no diagnostic.

## What this costs the 2B.1a claim

2B.1a's claim was an **independent** backstop. That claim holds for the primitive
and does not survive the cross-version pipeline:

> The producer's source gate and the compiler's argument check are not two
> readings of one fact. They read DIFFERENT BODIES — the patch's and the
> release's — and only one of them is the body being lowered.

So for a cross-version patch the source gate is the only real gate, which is the
single-gate situation the two-gate design existed to avoid. The cross-gate
mutation, had it been runnable, would have failed.

## The architectural correction, not yet implemented

The compiler needs an **unspecialised kernel of the PATCHED source** for
invocation-shape verification and site rediscovery, not the release body's AST:

    release AOT kernel      release compatibility, retention
    patched source          what the developer wrote
    patched no-AOT kernel   the compiler's authority for the genuine super
                            site, its true argument shape, and its structure
    release import universe the target that must bind to the shipped app

Leg 1 already establishes the property that makes this work: the offset **is**
stable between the patched no-AOT and patched AOT kernels (1886/1903 in both), so
an offset read from the analyzer's AOT kernel is a valid key in a patched no-AOT
kernel of the same source. It is only invalid against a different source version.

That also removes a limitation nobody had noticed: a patch may legitimately
**introduce** a `super.foo()` call where the release body had none. Today the
release body has no site to rediscover and the compiler must refuse a perfectly
valid patch.

## What must be probed before implementing it

> Can `dart2bytecode` compile the replacement against a **patched** no-AOT import
> kernel, re-derive the super target there, emit the `DirectCall`, and have that
> reference bind against the already-AOT-compiled RELEASE?

D-SUPER-1 established binding with a RELEASE-derived import kernel. Changing the
import component to patched source changes what the reference is resolved
against, and that is a different fact. Required observable stays stateful —
`TICKER:APP-STATE`, not successful linking.

Route B already prohibits signature and hierarchy changes, so the patched import
graph should differ only in bodies. That is a reason to expect it to work, not
evidence that it does.

## Not fixed by a nicer fixture

The four-member TFA contamination in `s2b1c/` is still real and still needs the
symmetric specimen. But it is now the second problem, not the first: making the
offsets line up in a fixture would certify an accidental property the product
cannot require.

## Reproduce

    WORK=/tmp/site    bash selfhost/engine/route_b/super0/s2b1site/run_site.sh
    WORK=/tmp/collide bash selfhost/engine/route_b/super0/s2b1site/run_collide.sh

Both exit non-zero: the first because the offsets do not cross versions, the
second because the compiler accepts a patch it should refuse.
