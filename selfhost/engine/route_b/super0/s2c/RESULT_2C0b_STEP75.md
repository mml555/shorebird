# D-SUPER-2C.0b · Step 7.5 — pre-map artifact closure for H

    H = a5a8be5854c529268378ce16762a16d6e31763e9

    audit at start   missing-required: 5   unprotected: 2
    audit now        missing-required: 2   unprotected: 0

## 7.5a — sky_engine.zip + flutter_gpu.zip  DONE

Packaged from the candidate tree that earned H. No rebuild; the existing
`out/ios_release` was used.

    sky_engine   from  out/ios_release/gen/dart-pkg/sky_engine
    flutter_gpu  from  flutter/lib/gpu
    engine source     dfa2b24ac38477f3705ff0357530f33fe09474b8

Served through :8085, both `X-Overlay: hit`, `X-Engine-Hash` = H:

    sky_engine.zip   200   1,563,044 B   7e440994e0b2f0895e8e57a82d18c30ebc44931a57eb8c1a56dc5f4973b2f6e9
    flutter_gpu.zip  200      51,550 B   9bd35eff110adb3cbf6865e2d9bcc333576e81e6d427093c23145d8599ecb787

### THE STOCK COMPARISON IS NOT ACADEMIC — sky_engine DIFFERS FROM STOCK

    flutter_gpu   CONTENT matches stock: yes   (zip bytes differ; owned honestly)
    sky_engine    CONTENT matches stock: NO

Three files differ:

    sky_engine/lib/_internal/vm/lib/internal_patch.dart
    sky_engine/lib/internal/internal.dart
    sky_engine/lib/ui/hooks.dart

    stock  92434d1ccb235115373276715cfdb9b0e3c7d5b2b231744dd75e0ec93197b335
    ours   7e440994e0b2f0895e8e57a82d18c30ebc44931a57eb8c1a56dc5f4973b2f6e9

Full diff banked at `<H>/sky_engine.content-diff.txt`.

This is exactly the case `publish_sky_packages.sh` predicted in its own header:
`killgate/0001-attach-bytecode-native.patch` modifies `internal_patch.dart`, so a
tree carrying it produces a DIFFERENT sky_engine "while we happily served stock."

Consequence, stated plainly: had H been mapped without this artifact, every build
against H would have compiled `dart:ui` and `dart:_internal` against STOCK
sources that do not match the engine actually running on device — silently,
because the bytes are absent locally but present in the response. The audit's
"missing-required" was protecting against a real defect here, not a formality.
This retires the step 4 conclusion that these two were benign fall-through.

## 7.5b — protection added, narrowly  DONE

`H` appended to the EXISTING `@must_be_local_pkgs` hash alternation, for
`sky_engine|flutter_gpu` only. The matcher was NOT broadened globally, and the
`linux-x64/font-subset.zip` clause remains scoped to `760e3fab` alone.

One line changed in `selfhost/cdn/Caddyfile`. Safe before mapping: the matcher's
expression also requires `stock_engine_hash != ""`, so while H is unmapped the
change has no serving effect. `unprotected` went 2 -> 0.

## 7.5d — patch-darwin-x64.zip  DONE

Native cross build, no Rosetta in the provenance path. `x86_64-apple-darwin` was
already installed, so no toolchain component was added.

Source identity banked BEFORE building:

    control repo HEAD       175944e1a5474e9051f65e75b453c91bff29a459
    vendor/updater subtree  9c380007fd5eae6f6dc755406d098c42f8c6c5d1
    Cargo.lock sha256       466b66f5d695bf12259d1513703f2a1eb99c256e97953b742743c54fa0d1ac6d
    publish_patch_tool.sh   ba652fdef714c0c4c8a41bea7a5409e9c412e4fa9429076ae377ab7383f2d7ca

Served through :8085:

    HTTP 200, X-Overlay: hit
    sha256      0dda5145e3c55db7f2d5cd67f305ffe68a6da5b7e55b375904f83d6a87613c20
    size        352,299
    members     patch          (single, at zip root)
    perms       -rwxr-xr-x
    arch        Mach-O 64-bit executable x86_64
    interface   Usage: patch <base> <new> <output>

The interface line was produced by EXECUTING the x64 binary on this arm64 host,
so Rosetta corroborates it — but the provenance is the native cross build.

## 7.5c — artifacts_manifest.yaml  BLOCKED ON A RULING CONFLICT

See CONFLICT below. Not written; writing either variant is a state change.

## 7.5e — patch-linux-x64.zip  BLOCKED, needs the Linux host

## Remaining audit findings

    MISSING-REQUIRED  <H>/artifacts_manifest.yaml
    MISSING-REQUIRED  <H>/patch-linux-x64.zip

    AUDIT FAILED for a5a8be5854c529268378ce16762a16d6e31763e9 (macos-ios)

Map and cdn-cache untouched.

---

# CONFLICT — the ruling's manifest acceptance test contradicts the repo's policy

The ruling directs `ci/internal/generate_manifest.sh H` and requires the served
result to carry `flutter_engine_revision: H`.

That upstream script writes its argument verbatim into that field
(`generate_manifest.sh:24`), so passing H yields `flutter_engine_revision: <H>`.

`selfhost/engine/generate_manifest.sh` exists specifically to stop that. Its
header records the field's meaning from
`artifact_proxy/lib/src/models/artifacts_manifest.dart:50` — "the flutter engine
revision that this engine mapping is based on", i.e. the UPSTREAM Flutter
engine, the revision the proxy resolves any NON-overridden artifact from on
Flutter's CDN. It states that naming our own hash there "points those lookups at
a revision Flutter has never published", and that this is inert today only
because Caddy rewrites an experimental hash to the pinned one before
artifact_proxy sees it — load-bearing behaviour written down nowhere.

The published corpus agrees with the policy, 11 to 4:

    83675ed2 (upstream)   69f9831c, 70974f81, 760e3fab, 4df8f9b6, 9f4d3942,
                          bbddaa6e, b4817db8, 5a6b0b09, 70b2e762, 40eaa0ef, ...
    own hash (outliers)   881e4129, 5b1a8965, fc184af6, dabf1837

Both SUPPORTED cells (70974f81, 760e3fab) and the pinned revision 69f9831c use
`83675ed2`. The four self-naming manifests are the drift our tool documents.

`83675ed2` is also the exact upstream revision this lane already used, and
verified, as `--pinned` for font-subset in step 7 — so the two would agree.

Not resolved unilaterally: complying reproduces a documented defect, deviating
fails the stated acceptance test. Raised for ruling.
