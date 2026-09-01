# D-SUPER-2C.1 · release against H2 — STOP at the acceptance gate

    release EXISTS but is NOT PATCHABLE
    provenance.engineRevision   NOT CLAIMED — no provenance was generated

## What passed

    CLI2 -> F2 -> H2 chain            tracked, remote-banked, fresh-fetch verified
    empty-cache resolution            CLI cloned F2 itself; engine.stamp = H2
    consumed bytes                    all three iOS archives match the H2 manifest
    local flutter build ipa           EXIT=0, zero "Invalid SDK hash"
    shorebird release ios             EXIT=0
    release recorded                  id 139, version 1.0.0+1,
                                      flutter_revision 8427e3da… (= F2)

The host-lineage repair is therefore CONFIRMED end to end: the identical app
that died in the AOT snapshotter under H builds and releases under H2.

## THE STOP — the release is not patchable, so there is no provenance to accept

From the release log:

    Downloading Route B compiler for engine 64ff9f59…
    [WARN] Could not resolve this engine's Route B tooling (Route B producer
    tooling for engine 64ff9f592ae319eea04db6092b71319d4778b873 failed
    validation: the bundle records engine
    a5a8be5854c529268378ce16762a16d6e31763e9, not the engine it was published
    under. … cutting a new release would not fix it. Nothing was uploaded.);
    this release will not be patchable.

Consequently `writeRouteBReleaseProvenance` never ran: there is no `route_b.json`
anywhere in the build tree, and the uploaded `ios_supplement` carries only the
link tables (`App.ct.link`, `App.field_table.json`, `App.ft.link`,
`App.dt.link`, `App.class_table.json`, `App.dispatch_table.json`).

    ACCEPTANCE GATE  provenance.engineRevision = H2
    RESULT           UNSATISFIABLE — no provenance object exists

Per the ruling this is NOT inferred from `engine.version`, the resolver URL, or
`engine.stamp`, all three of which do say H2. The gate asks for generated
provenance, and none was generated.

## Root cause — measured, and it is structural

The compiler bundle carries its own `PROVENANCE.txt`:

    engine revision  : a5a8be5854c529268378ce16762a16d6e31763e9
    host out         : …/out/host_release_arm64
    dart revision    : 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c

and `route_b_compiler.dart:252` refuses when that recorded engine differs from
the hash the bundle was published under:

    if (recordedEngine != engineHash) throw _invalid(…)

H2 published the compiler bundle byte-identically from H — as instructed, and as
verified at `9d4ace27…`. But the bundle RECORDS the address it was published
under, so a byte-identical clone under a NEW address is self-inconsistent by
construction. The check is correct; it is catching a real mismatch between the
bundle's claim and its location.

This is the case the ruling named in advance:

> The compiler must remain 9d4ace27… unless something unexpectedly forces it to
> change, in which case STOP rather than silently requalifying it.

Something has forced it. The bundle cannot simultaneously be byte-identical to
H's and record H2.

## Why this was not visible earlier

Every prior check on the compiler was on its ARCHIVE identity — the served
sha256 and the capability probe — which a clone preserves exactly. Nothing
compared the bundle's INTERNAL engine claim against its address. The audit does
not do it either; only the CLI's producer-tooling resolution does, on the patch
path. `9d4ace27…` is still the qualified bundle; it is qualified for H.

## The options, none taken

1. Republish the compiler bundle under H2 with `PROVENANCE.txt` recording H2.
   That changes the bundle's bytes, so it changes the v2 address — H2 as
   currently published would be superseded by an H3. It also means the
   qualification evidence (`9d4ace27…`) must be re-established for the new
   bytes, or explicitly carried over on the argument that only a provenance
   line changed.

2. Change the CLI's validation to accept a bundle whose recorded engine differs
   from its address. That weakens a check which exists to catch mixed
   provenance, and this lane has repeatedly found that class of defect real.

3. Make the bundle's recorded engine not participate in its own identity —
   e.g. record the SOURCE engine separately from the publication address, so a
   clone is legitimately addressable. This is the only option that resolves the
   contradiction rather than choosing a side of it, but it is a product change.

Option 1 is mechanical but re-opens the address; option 3 is the correct
modelling and is larger. This is a design decision, not a repair, so it is
raised rather than chosen.

## State

    release 139        EXISTS, installable, NOT patchable
    provenance         NOT GENERATED, gate unsatisfiable
    H2                 ACTIVE, 16/16 verified
    host repair        CONFIRMED by the successful build and release
    B patch controls   BLOCKED
