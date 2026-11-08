# CELL `ac8d8434` — BLOCKED, with a coherent set published and consumed

Outcome per the assignment's definition of done: **BLOCKED**, not PROVEN. The
exact failed gate is preserved and **no lifecycle verdict is changed.**

## WHAT SUCCEEDED — steps 1-3 complete

A coherent wired artifact set was **built, published, and verified through the
consumer path.** The four-surface gate PASSED, fetched over HTTP from the CDN the
CLI uses:

| surface | as FETCHED |
|---|---|
| engine `ios-release/artifacts.zip` | `LC_UUID 4C4C447D`, wiring strings present |
| `gen_snapshot_arm64` | universal x86_64+arm64 |
| `flutter_patched_sdk_product` | **`9e8c898a4d`** |
| `dart-sdk` `vm_platform_product.dill` | **`9e8c898a4d`** |
| `frontend_server` + `const_finder` | dated 08-20 — ours, not stock |

Cell `ac8d843451f0bb8524932db2bc1fe6ee58c03c0f`, registered in
`experimental_hashes.map`, served 200 for owned artifacts and 302 fallback for
the rest.

## WHERE IT BLOCKED — a FIFTH coherence surface

    Wrong full snapshot version,
      expected '21139db2770724220da55c72db00acdc'   <- the VM running the tool
      found    '8889ac395b461aefb5344c2195559e94'   <- the regenerated snapshot

**Artifact coherence was necessary but not sufficient.** Beyond the four artifact
surfaces there is a fifth: **the Dart VM that RUNS the build tooling**. Moving the
SDK revision regenerates `flutter_tools.snapshot` in the new snapshot format,
and a VM still pinned to the old format cannot execute it.

Clearing `flutter_tools.snapshot` did not help — it regenerates in the NEW format,
which is exactly what the old VM rejects. The two are mutually exclusive: the
snapshot must match whichever VM will run it, and that VM is not one of the four
published artifacts.

Also unresolved, and independent: `shorebird release` warned **"Route B producer
tooling has not been published for engine ac8d8434…"** — the Route B compiler
artifacts are a separate publish keyed by engine hash, and were never produced
for this cell.

## THE LESSON, sharper than the four-surface rule

> **Coherence includes the tool RUNNER, not only the tool INPUTS.** Publishing a
> self-consistent artifact set is not enough if the process that consumes it
> executes snapshots built by a different Dart.

## TWO REAL BUGS FIXED ALONG THE WAY

1. **`dart_sdk_verification_hash` is a pinned GN arg, not derived.**
   `host_release_arm64` pinned `6b58bb3a72` while Dart HEAD was `9e8c898a4d`, so
   every dill it produced carried the old hash however many times it was
   regenerated. This is the general form of the earlier stale-`version.cc`
   finding: **the SDK hash is configuration, not a build product.**
2. **A genuine GN bug, committed** as `flutter@route-b 2c7b8c3ea5`:
   `zip_bundle_from_file("dart_sdk_archive")` passed the entitlements file as a
   bare `$target_gen_dir` — GN source-absolute `//out/...` — which `zip.py`
   resolved against the filesystem as `/out/...`. The sibling entry rebases; this
   one did not, so `dart-sdk-darwin-arm64.zip` could never be rebuilt at all.

## A DOCUMENTED WARNING THAT DOES NOT APPLY HERE

`publish_ios_overlay.sh` says to avoid `out/host_release_arm64` because it carries
`dart_dynamic_modules=true`. That was written for the shipping `ios-engine` tree,
whose `ios_release` does NOT enable dynamic modules. **Route-b's `ios_release`
enables them deliberately** — the interpreter is the point — and both dirs agree
on the flag AND the SDK hash while `nodm` disagrees. So here the warning inverts.
Overridden with evidence, not ignored.

## THE GATE EARNED ITS PLACE ON FIRST USE

The first publish succeeded and returned HTTP 200 for everything — while
`flutter_patched_sdk_product` and `dart-sdk` were **still at the old hash**,
because the script's `HOST_REL`/`PSDK_REL`/`HOST_DBG` default to a different tree.
**Without the fetch-back gate, provenance would have been stamped over an
incoherent set.** It was stamped only after the gate passed, and reverted when
the run blocked.

## RIG STATE — RESTORED AND VERIFIED

* `engine.version` → `50bdae36…` (the working cell);
* checkout cache re-consumed from that cell; Dart back to the Aug 3 build;
* `compatibility.yaml` reverted — **no provenance claim survives a blocked run**;
* fixture back to `1.2.0+1`; **no release 103 exists**;
* verified by real work, not hashes: `✓ Built Runner.xcarchive` and
  `Done Verifying patch can be applied to release`.

Cell `ac8d8434` is left published but **not in service** — it is the starting
point for the next attempt, not litter.

## WHAT IS UNCHANGED

Every lifecycle verdict stands exactly as before: explicit-vs-inferred failure
**device-PROVEN**; hard-kill primitive **device-qualified**; release-102 baseline
**PROVEN**; wiring + telemetry **BUILT / host-tested**; row-5 recovery **pending**.
