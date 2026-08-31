# 2C.0a preflight — the engine revision is NOT artifact-visible. A marker is required.

No engine build was spent. Nothing certified moved.

## The question, and the measurement

> Does the engine source revision already participate in the Flutter
> device-slice bytes?

    device slice     out/ios_release/Flutter.framework/Flutter
                     arm64, non-fat — this IS the device slice
    args.gn          engine_version = "619fdad176ff457331b50230b9511e7230a6ed93"
    in the binary    619fdad176ff… ABSENT (0 hits, whole framework directory)
    symbol           GetFlutterEngineVersion  0 symbols — stripped

**The build receives the revision and the release link drops it.** `shell/version`
compiles `FLUTTER_ENGINE_VERSION` from the GN arg, and nothing in a release iOS
link keeps it.

So **the answer is NO**, and the docs-only candidate `b456dc0d` would produce a
device slice byte-identical to `619fdad1`'s — the same sha1, the same key, no
distinct identity. Building it now would spend hours to learn that.

## But provenance strings DO survive — and that is where a marker belongs

The device slice carries 74 shorebird strings, including the updater's own
revision:

    af6e842ccf87            the updater revision, in its 12-char wire form
    [shorebird] Preparing next boot.
    [shorebird] Verifying patch signature...

So artifact-visible provenance is not merely possible here, it is already the
established practice. An inert candidate marker placed alongside the existing
shorebird provenance is source-explainable and would survive the same link that
strips `FLUTTER_ENGINE_VERSION`.

That is the lever, and it is the one the ruling authorized under "if NO".

## A correction to my own earlier framing, and to the plan's arithmetic

I previously wrote that `publish_ios_overlay.sh` derives the hash as sha1 of the
device slice, and implied that hash is the cell key. Both halves are true
separately and the join was wrong:

    sha1(our device slice)          cc150ab64dbeef57be41fd7b1bd12bda5cb7e717
    pinned Flutter engine.version   4792f0eca461f3761001a1adbe131b4b115e3684
    cell key                        4792f0ec…  (the release's provenance.engineRevision)

`4792f0ec` is the **upstream** engine revision recorded by the pinned Flutter
`a4a3c0d1`. It is not derived from our fork's build at all. Our own engine
publishes under an artifact-derived hash — which is exactly what the existing
`experimental_hashes.map` entries are (`fc184af6…`, `760e3fab…`, each mapped to
a pinned fallback).

So the candidate chain is self-consistent only if the candidate Flutter pins
`engine.version` to **our** artifact-derived hash, and both the engine artifacts
and the cell are published under that same hash. That is what the existing
experimental entries already do; it just needs stating, because "engine.version"
means two different provenances depending on whether the engine is upstream's or
ours.

## Where this stops, and why

The remaining step is engine-source surgery: choosing a marker that provably
survives the release link, is never consulted for behaviour, and is not
whitespace, dead code, a timestamp, or build metadata. Getting that choice wrong
costs a full iOS engine build to discover.

The preflight has done its job — it converted "build and see" into a specific,
cheap-to-review design question:

> Which existing shorebird provenance surface should carry
> `shorebird-route-b-2c-candidate-v1`, such that it is retained by the release
> link and read by nothing?

`b456dc0d` is kept as the documented start of the candidate branch, exactly as
the ruling directed; the marker becomes one commit on top of it rather than a
rewrite.

## Ledger, re-verified

    engine fork HEAD    619fdad176ff4573…  on `route-b`, unchanged
    published cell      0696da541c2b9a9d…  unchanged
    compatibility.yaml  42a970f46a234794…  unchanged
    installed CLI       207c4a7ac91f937e…  unchanged
    experimental map    7bdc97bf9ed27082…  unchanged
