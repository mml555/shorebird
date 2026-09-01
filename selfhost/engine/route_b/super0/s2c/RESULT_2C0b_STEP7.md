# D-SUPER-2C.0b · Step 7 — font-subset.zip for H

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT

    Step 7 contract          PASS — all arms, including the strong negative
    audit_overlay.sh for H   FAILED — four further gaps, NOT font-subset
    map                      REMAINS BLOCKED

## Command

    DART=<candidate>/dart-sdk/bin/dart publish_font_subset.sh \
      --overlay selfhost/cdn/overlay \
      --rev     a5a8be5854c529268378ce16762a16d6e31763e9 \
      --host    darwin-arm64 \
      --pinned  83675ed27633283e7fc296c8bca22e841224c096 \
      --mirror  http://localhost:8085/gcs

The SDK check was NOT skipped. `DART` was set to the Dart SDK published under H
itself — fetched through :8085 from `H/dart-sdk-darwin-arm64.zip`, Dart 3.12.2
(stable), i.e. the SDK a build against H actually uses, not a convenient local
one. The script printed:

    const_finder SDK-hash verified against …/h_sdk/dart-sdk/bin/dart

and NOT `DART not set; skipping…`.

## Acceptance gate — served through :8085

    HTTP            200
    X-Overlay       hit
    X-Engine-Hash   a5a8be5854c529268378ce16762a16d6e31763e9
    Etag            "dl3mnroddg1e1dr53"
    sha256          11f7e1064f10633e6e882efe43b793f1a7aa32a32232b9640125d9bff67ad990
    size            2,321,319

    members         const_finder.dart.snapshot
                    font-subset
                    LICENSE.font_subset.md          exactly three

## Provenance proved member-by-member, not taken from the publisher's word

### Candidate half — the candidate const_finder WON

Extracted independently from two separately served archives:

    served H/darwin-arm64/font-subset.zip  const_finder  df54370e…aac31
    served H/darwin-arm64/artifacts.zip    const_finder  df54370e…aac31
    EQUAL

Executed under the candidate SDK:

    dart const_finder.dart.snapshot
    -> FormatException: Option kernel-file is mandatory.

The snapshot LOADED and reached Dart-level argument parsing. That is the
positive result: it cleared the VM's snapshot-load gate, which is the gate that
`Invalid SDK hash` fails at. A usage error from inside the program is proof of
compatibility, not a failure.

### Upstream half — the native tool and licence are untouched upstream bytes

    font-subset             candidate 655400f0…fd66  ==  upstream 655400f0…fd66
    LICENSE.font_subset.md  candidate f982c1bf…fcac  ==  upstream f982c1bf…fcac
    arch gate               font-subset = arm64

Upstream is the already-verified `83675ed2…` archive fetched via `/gcs/`.

Complete statement:

    candidate kernel tool + unchanged upstream native font tool/licence
        = served H font-subset.zip

## STRONG NEGATIVE CONTROL — held, and it was free

The upstream archive turned out to CONTAIN a stock const_finder, so the control
needed no state change at all. That is also the direct evidence that this
artifact does real work: the publisher REPLACED a member rather than adding one.

    stock     const_finder  20da90a654b534c77544ef6814a17dd483b4ed928564d295249db885b710b7c5  (4,729,168 B)
    candidate const_finder  df54370e87950437b6945953bd82db1836a2c6ec5820516580d748e2447aac31  (4,729,072 B)

    candidate Dart + STOCK const_finder
    -> Can't load Kernel binary: Invalid SDK hash.

The SAME SDK that runs the candidate snapshot rejects the stock one. The
distinction is now a demonstrated compatibility boundary, not a provenance
claim — and it reproduces exactly the failure the whole artifact exists to
prevent.

## audit_overlay.sh --hash H --cell macos-ios — FAILED

font-subset is RESOLVED: it does not appear in the findings, and owned-built
rose to 14. Four other gaps stand, and the audit is the authority the Caddy
policy defers to:

    MISSING-REQUIRED  sky_engine.zip            Dart source of dart:ui
    MISSING-REQUIRED  flutter_gpu.zip           second getPackageDirs() entry
    MISSING-REQUIRED  artifacts_manifest.yaml   see --emit-manifest
    MISSING-REQUIRED  patch-darwin-x64.zip      cross-compiled, Rosetta-verified
    MISSING-REQUIRED  patch-linux-x64.zip       built on the Linux box

    UNPROTECTED       sky_engine.zip, flutter_gpu.zip

    AUDIT FAILED for a5a8be5854c529268378ce16762a16d6e31763e9 (macos-ios)

### CORRECTION to RESULT_2C0b_STEP4.md

That file listed `sky_engine.zip` and `flutter_gpu.zip` under "missing, falls
through by design". That was WRONG, and the audit is right. They are owned by
policy and REQUIRED for a macos-ios cell. Because H is not in
`@must_be_local_pkgs`, a miss does not 404 — it silently serves STOCK bytes from
the pinned hash, which is worse than a 404 and is the exact defect
`mint_route_b_cell.sh` documents: releases on this chain compiled against a
`pkg/sky_engine` fetched under a DIFFERENT engine hash, invisible because a
cache stamp made it look settled (`EPOCH_CROSSING_STOP.md`). The remedy on
record is to package sky_engine.zip from THIS engine's own build, never to fetch
a foreign one.

The step 4 reasoning is left in place; this supersedes its conclusion only.

Map entry and cdn-cache restart remain untouched.
