# D-SUPER-2C.1 · RELEASE-B2 — release exists, provenance gate PASSES

    release 140   version 1.0.1+2
    flutterRevision   8427e3da6174007d2f654972a014671d09d64468   (F2)
    engineRevision    64ff9f592ae319eea04db6092b71319d4778b873   (H2, whole cell)

## The certified chain, verified before cutting

    CLI     6f97de7e7bd97355de517fb63a9c2f9b6a0f2243   HEAD, 0 dirty
      ->    flutter.version 8427e3da…
    Flutter 8427e3da6174007d2f654972a014671d09d64468   HEAD, 0 dirty
      ->    engine.version 64ff9f59…
    cell    64ff9f592ae319eea04db6092b71319d4778b873

No local CLI edits, no manual checkout after resolution, no cache substitution.
The Route B compiler cache for H2 was emptied first.

## The cell binding worked in the real release path

    Downloading Route B compiler for engine 64ff9f59…
    Done Downloading Route B compiler for engine 64ff9f59…

No "failed validation … not the engine it was published under". That warning is
what made release 139 non-patchable; it is gone.

## First attempt refused — correctly, and it is not a defect

    It looks like you have an existing ios release for version 1.0.0+1.

Release 139 already holds `1.0.0+1`. A NEW release identity needs a new version,
so `pubspec.yaml` went `1.0.0+1 -> 1.0.1+2`. The canonical B SOURCE is unchanged
and its digest is recorded below — the version bump is an identity change, not a
semantic one.

## DECISIVE GATE — satisfiable this time, and it passes

    release command exit        0
    new release ID              140   (!= 139)
    version/build               1.0.1+2
    flutter_revision            8427e3da…  == F2

    route_b.json EXISTS locally
        build/ios/shorebird/route_b.json
        engineRevision  64ff9f592ae319eea04db6092b71319d4778b873  == H2
        flutterRevision 8427e3da…                                  == F2

    route_b.json PRESENT IN THE UPLOADED SUPPLEMENT
        fetched from the control plane, not read off disk
        sha256 fd2c80640b05d6b1e5e295208f030e81f2f1f91cad3a07cc806768c7a455b3f7
        byte-identical to the locally generated file

`engineRevision` is the WHOLE-CELL address. It is deliberately NOT
`a5a8be58…`, which remains the compiler bundle's producer lineage — a different
identity, which is the whole point of CELL-BINDING-V2.

## The gap release 139 exposed is closed

    139   release exists   route_b.json ABSENT    not patchable
    140   release exists   route_b.json present locally AND remotely,
                           engineRevision = H2

## FROZEN release identity — do not recut

    release ID                140
    version                   1.0.1+2
    flutter_revision          8427e3da6174007d2f654972a014671d09d64468
    engineRevision            64ff9f592ae319eea04db6092b71319d4778b873
    canonical B source        9e73ba40ad81ce60a3c07b9e526b25bbb50eeeb9a9e8873b09027d62125bf33c
    releaseArtifactSha256     a0471ae8675bb533c1fbd5e7bdca3c31f02e17679f0251b585fa54e16c354bda
    releaseTarget             lib/main.dart
    patchableCallSites        8462   (1902.3 per MiB)
    compatibilityRevision     1
    supplement zip            c4a6e60be7f2f672d970dc4e068ab6fb4811778ec7ec12023653b16b74c83780
    route_b.json              fd2c80640b05d6b1e5e295208f030e81f2f1f91cad3a07cc806768c7a455b3f7

    link tables (sha256, first 32)
      App.ct.link              7875e37a0966a89a9b86569ecc7e5ec4
      App.ft.link              10d799d7229e3f4d79cb40562c8e705a
      App.dt.link              de16ce3d987f76af3ec65d2ad6f48ff9
      App.class_table.json     906666ff2a81bbd683f4e2cadc15949f
      App.field_table.json     552e2c5708dece340f45f67c7bc334d4
      App.dispatch_table.json  f4e55c63970809ceb8c5d9ffd73e01e3

The uploaded supplement carries the full Route B set — `release_app.dill`,
`dynamic_interface.yaml`, `route_b_capabilities.json`, `route_b_retention.json`,
`route_b_profile_binding.json`, `route_b_snapshot_profile.json` and the six link
tables — where 139's carried only the link tables.

A copy of the accepted provenance is banked at
`h2_address/release_b2_route_b.json`.

## ONE WARNING CARRIED FORWARD, not swallowed

Twice during the build:

    [WARN] Could not check the two release kernels against each other
           (The Route B coverage analyzer failed (exit 255): …)

Non-fatal, and the release completed with provenance. But it means a
release-time cross-check did NOT run, so it is recorded here rather than left in
a log. It should be understood before the patch is trusted, since the analyzer
is the component that authorizes super targets.

Also recorded from the same build, and expected:

    Route B retention: narrower contract — private members enumerated from the
    release prepass because the import kernel and the release prepass do not
    describe the same program.

## Release 139 untouched

Still present, still `1.0.0+1`, still non-patchable. Retained as the permanent
negative control. Not retrofitted, not deleted.

## Next

The B patch: change `Leaf.target()` from `TICKER:APP-STATE` to
`WRAP:TICKER:APP-STATE` and require the patch path to independently observe the
descriptor, the compiler archive `9d4ace27…`, producer lineage `a5a8be58…` and
the dual-kernel capability. No compiler-consumption claim before that.
