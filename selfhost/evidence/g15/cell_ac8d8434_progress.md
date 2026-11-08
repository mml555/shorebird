# CELL `ac8d8434` — publish progress and what the consumer gate caught

In progress. Recorded as it happens so a stop at any point is legible.

## THE GATE PAID FOR ITSELF IMMEDIATELY

The rule *"no provenance stamp until the published bytes are fetched back through
the normal consumption path and verified coherent"* caught a real incoherence on
its first use.

`publish_ios_overlay.sh` succeeded, all artifacts returned HTTP 200 — and the
fetched set was **still incoherent**:

| surface | as fetched |
|---|---|
| engine (`ios-release/artifacts.zip`) | `4C4C447D`, wiring present, **new** |
| `gen_snapshot_arm64` | universal, new |
| `flutter_patched_sdk_product.zip` | **`6b58bb3a72` — OLD** |
| `dart-sdk-darwin-arm64.zip` (`vm_platform_product.dill`) | **`6b58bb3a72` — OLD** |

Cause: the script's `HOST_REL` / `PSDK_REL` / `HOST_DBG` default to a DIFFERENT
tree (`/Volumes/build/ios-engine/...`), so it published stale host zips rather
than the ones just built. A successful publish and three HTTP 200s would have
looked like completion.

**Without the gate, `compatibility.yaml` would have been stamped over an
incoherent set.**

## A DOCUMENTED WARNING THAT DOES NOT APPLY TO THIS TREE

`publish_ios_overlay.sh` says:

> NOT `out/host_release_arm64`: that is Track E's killgate rig and carries
> `dart_dynamic_modules=true`, whose platform dill fails the iOS AOT step with
> "Unexpected tag 4 (Field)". Use a host_release configured like `out/ios_release`.

**That warning was written for the shipping `ios-engine` tree, whose `ios_release`
does NOT enable dynamic modules. In the route-b tree it DOES** — deliberately,
since the point is an engine whose runtime carries the interpreter. Measured:

    ios_release             dart_dynamic_modules = true   hash 9e8c898a4d
    host_release_arm64      dart_dynamic_modules = true   hash 9e8c898a4d
    host_release_arm64_nodm  (no dm)                      hash 6b58bb3a72

So for THIS tree `host_release_arm64` is the correct match and `nodm` is the
mismatch — the opposite of what the comment says, because the comment's premise
about `ios_release` is false here. Recorded rather than silently overridden.

## FIXES MADE ALONG THE WAY

1. **`dart_sdk_verification_hash` is a pinned GN ARG**, not derived. `host_release_arm64`
   still pinned `6b58bb3a72` while Dart HEAD was `9e8c898a4d`, so every dill it
   produced carried the old hash no matter how many times it was regenerated.
   Corrected in `args.gn` + `gn gen`. **This is the general form of the earlier
   `version.cc` finding** — the hash is configuration, not a build product.
2. **GN bug fixed and committed** (`flutter@route-b 2c7b8c3ea5`):
   `zip_bundle_from_file("dart_sdk_archive")` passed the entitlements file as a
   bare `$target_gen_dir`, i.e. GN source-absolute `//out/...`, which `zip.py`
   resolved against the filesystem as `/out/...`. The sibling entry rebases; this
   one did not, so `dart-sdk-darwin-arm64.zip` could never be rebuilt.
3. Stale generated artifacts cleared in layers, each caught by the next failure:
   `version.cc` → 14 stale dills under `gen/` → 9 more elsewhere in the out dir.

## OUTSTANDING

* `HOST_DBG` supplies `darwin-arm64/artifacts.zip` (`const_finder`,
  `frontend_server`) and `flutter_patched_sdk.zip`. The route-b tree has no
  `host_debug_arm64`; building `darwin-arm64-release-ddm/artifacts.zip` from
  `host_release_arm64` instead (~1740 targets, in progress) to supply a
  `const_finder` at `9e8c898a4d`. The script warns that a non-ours `const_finder`
  makes **every release die with "Invalid SDK hash"**.
* `flutter_patched_sdk.zip` (NON-product) has no target in this config. Release
  builds read the product variant, so a carried-forward stale copy should be
  inert — **to be proven by the build, not assumed.**
* The patch differ was built from `vendor/updater/patch` (pinned `1f85c4ab`), not
  `third_party/updater`. Separate crate from the updater library; noted so the
  provenance claim stays exact.

## NOT YET DONE

Provenance stamp · release 103 · device run. **The gate stands: nothing is
stamped until a fetched-back set verifies coherent on all four surfaces.**
