# TASK: make cell `ac8d8434…` consumable by the real CLI, then publish Route B producer tooling

**Authoritative assignment.** The lifecycle lane stays **FROZEN**. This lane is
**toolchain-consumer coherence** — not engine building, not lifecycle behaviour.

## OBJECTIVE

> Make cell `ac8d843451f0bb8524932db2bc1fe6ee58c03c0f` consumable by the real CLI
> with a Dart runner that understands the tooling snapshots produced by that
> cell, then publish the missing Route B producer tooling.

**Do not rebuild the engine** unless this task proves the published cell itself is
unusable. The engine is already built, published, and consumer-verified on four
surfaces (`evidence/g15/cell_ac8d8434_verdict.md`).

## 1. THE COHERENCE SET IS AT LEAST SEVEN MEMBERS

    Flutter.xcframework
    gen_snapshot / analyze_snapshot
    flutter_patched_sdk_product
    dart-sdk contents
    the Dart VM used to RUN the CLI / generated tooling
    the generated flutter_tools.snapshot
    Route B producer / compiler artifacts

**The invariant, stronger than hash equality:**

> **Every executable artifact and every serialized artifact it reads must belong
> to a mutually compatible Dart/Flutter lineage.**

"The hashes match" is not sufficient — the previous attempt had all four artifact
hashes agreeing and still failed, because the VM executing the tooling belonged to
a different lineage.

## 2. PROVE THE RUNNER MISMATCH MECHANICALLY — before changing anything

Convert "most likely move the pinned Dart" into a measured requirement:

* identify the **exact** Dart binary the CLI invokes;
* record its SDK / version / snapshot-format lineage;
* identify the regenerated `flutter_tools.snapshot`;
* demonstrate BOTH directions:
  * old runner + new snapshot → **deterministic rejection**
  * matching new runner + the SAME snapshot → **acceptance**

The observed failure to reproduce deliberately:

    Wrong full snapshot version,
      expected '21139db2770724220da55c72db00acdc'   <- VM running the tool
      found    '8889ac395b461aefb5344c2195559e94'   <- regenerated snapshot

Note that clearing `flutter_tools.snapshot` does NOT help: it regenerates in the
new format, which is exactly what the old VM rejects. They are mutually exclusive.

## 3. MOVE THE RUNNER THROUGH THE SUPPORTED DISTRIBUTION PATH

**No more `~/.shorebird` surgery.** Find where the CLI's pinned Dart is actually
sourced/published, and extend the existing cell/publish pipeline so the matching
runner arrives through that path.

Then apply the gate in its stricter form:

> **Verify the bytes the CLI actually SELECTS AND EXECUTES — not merely the
> archive you published.**

**Decisive success test is real work**: the CLI launches, regenerates or loads its
tooling, and completes an iOS build against the new cell with no kernel-format
errors.

## 4. FIX THE PUBLISH DEFAULTS — this is a correctness bug, not a trap to remember

`publish_ios_overlay.sh`'s `HOST_REL` / `PSDK_REL` / `HOST_DBG` default to a
DIFFERENT tree (`/Volumes/build/ios-engine/...`). The first publish therefore
shipped stale host zips while reporting success and serving HTTP 200.

**"Remember to override them" is not an acceptable permanent solution.** Make the
script either:

* derive them from the selected engine / build root, **or**
* require them explicitly and **fail** when absent;

and add a gate that **rejects a publish** when those inputs resolve outside the
intended lineage. The fetch-back gate remains mandatory even after this is fixed.

## 5. PUBLISH ROUTE B PRODUCER TOOLING — treat the warning as a HARD BLOCKER

`shorebird release` warned:

    Route B producer tooling has not been published for engine ac8d8434…

Before release 103:

* determine exactly which producer artifact(s) the cell expects;
* publish them under `ac8d8434…`;
* fetch them through the real consumer path;
* run a **tiny Route B producer probe** against the published versions.

**Do not let the lifecycle run be the first test that producer tooling was
packaged correctly.**

## DEFINITION OF DONE

**PROVEN**
* matching Dart runner consumed through the normal CLI path;
* new `flutter_tools.snapshot` accepted;
* coherent iOS build succeeds;
* Route B producer tooling published and consumed;
* cell `ac8d8434…` performs a real Route B build **without cache surgery**;
* **only then** stamp `compatibility.yaml`.

**BLOCKED**
* exact consumer/serialization boundary identified and preserved;
* rig restored and verified by real work;
* no release 103;
* no lifecycle verdict changed.

When green, **return immediately to the frozen lifecycle after-run.** Do not
broaden into SDK modernization and do not rebuild the already-qualified engine.

---

# APPENDIX — established facts, do not re-derive

## The published cell

    ac8d843451f0bb8524932db2bc1fe6ee58c03c0f
      engine arm64 LC_UUID  4C4C447D-5555-3144-A165-51D432516584
      wiring strings        __patch_boot_lifecycle__, ambiguous_boot_retry,
                            recovered_after_ambiguity, retired_after_ambiguity
      SDK hash (surfaces 3+4)  9e8c898a4d
      registered in          selfhost/cdn/experimental_hashes.map
    Published, NOT in service. Starting point, not litter.

## Two root causes already fixed

1. **`dart_sdk_verification_hash` is a pinned GN ARG, not derived.** A stale pin
   makes every regenerated dill carry the old hash however often it is rebuilt.
   **The SDK hash is configuration, not a build product.** Same root cause as the
   stale generated `version.cc`.
2. **GN bug, committed** `flutter@route-b 2c7b8c3ea5`: the `dart_sdk_archive`
   entitlements entry lacked `rebase_path`, leaving GN source-absolute `//out/...`
   that `zip.py` resolved against the filesystem. `dart-sdk-darwin-arm64.zip`
   could not rebuild at all before this.

## A documented warning that INVERTS in this tree

`publish_ios_overlay.sh` says avoid `out/host_release_arm64` for
`dart_dynamic_modules=true`. Written for the shipping `ios-engine` tree, whose
`ios_release` lacks dynamic modules. **Route-b's `ios_release` enables them
deliberately.** Measured: `ios_release` and `host_release_arm64` agree on the flag
AND the SDK hash; `nodm` disagrees. Here `host_release_arm64` is correct.

## Build-order facts

* build the host `gen_snapshot` BEFORE actions that consume it — ninja will
  otherwise use a stale one earlier in the same run;
* stale generated artifacts appear in layers: `version.cc`, then dills under
  `gen/`, then dills elsewhere in the out dir. Clear by SDK hash, not by path.
* `const_finder` and `frontend_server_aot.dart.snapshot` ARE buildable from
  `host_release_arm64`; the release-mode `darwin-arm64-release-ddm/artifacts.zip`
  does **not** contain them (~1740 targets, ~40 min, and still no const_finder).

## Frozen lifecycle facts — untouched by this lane

    fixture lib/main.dart  b284143628441e50543317f5f78ca7da12492aeca81987d29c4a4540589c813f
    release 102 App        D06B410E-9C99-38BD-952E-AD4A345A7908
    BEFORE engine (arm64)  4C4C44C0-5555-3144-A1DD-7EB2A7564480
    device g15_mode        currently `dart-fail` — Documents survives install-over
                           and is NOT under --rmtree. Set explicitly, verify by
                           read-back, before launch 1 of the after-run.

Standing verdicts: explicit-vs-inferred failure **device-PROVEN**; hard-kill
primitive **device-qualified**; release-102 baseline **PROVEN**; wiring +
telemetry **BUILT / host-tested**; row-5 recovery **pending**.

## Backups

    evidence_preserved/shorebird_ios_release_BEFORE   engine + snapshot tools
    evidence_preserved/shorebird_common_BEFORE        both patched SDKs
    evidence_preserved/build_coherence/               gen_snapshot pair, dill,
                                                      args.gn.host.BEFORE,
                                                      engine.version.BEFORE,
                                                      experimental_hashes.map.BEFORE

**Do not ship the wiring to devices ahead of the telemetry.**
