# TASK: publish one coherent wired iOS engine cell, and prove row-5 recovery on hardware

**Authoritative assignment.** Bounded on purpose. Everything needed is already
designed and frozen; nothing below requires rediscovering the project.

## OBJECTIVE

Take the already-built lifecycle wiring and telemetry from **BUILT / host-tested**
to **device-PROVEN**, without reopening lifecycle-policy design or earlier G15
mechanism work.

The only load-bearing product question:

> **After an ambiguous pre-success process disappearance, does the wired
> production path classify it as `ambiguous_boot_retry`, allow the next healthy
> launch, and then emit `recovered_after_ambiguity` instead of retiring the
> patch?**

## WORK SEQUENCE

### 1. Build the complete coherent artifact set
* run the documented `build_host_zips.sh`;
* apply the known fix for stale generated `version.cc` state (see §APPENDIX A);
* all four coherence members must come from ONE SDK/tool lineage:
  `Flutter.xcframework` · `gen_snapshot`/`analyze_snapshot` ·
  `flutter_patched_sdk_product` · `dart-sdk`.

### 2. Publish through the real pipeline
* `publish_ios_overlay.sh`, under one explicit engine/cell identity;
* **no manual edits or file swaps inside `~/.shorebird`.**

### 3. Prove what the CONSUMER actually receives
* fetch through the same path the CLI will use;
* verify fetched bytes against published bytes;
* verify SDK-hash coherence across all four artifact classes;
* verify the lifecycle wiring exists in the shipped engine;
* mechanically prove the updater in that engine corresponds to `ae1a4849`.

### 4. Only after step 3, update provenance
* `compatibility.yaml` to the exact updater revision actually shipped;
* **provenance describes CONSUMED bytes, never merely successful build output.**

### 5. Cut release 103
* fixture source unchanged from the frozen after-run fixture except required
  release/version metadata;
* preserve release evidence BEFORE patching.

### 6. Prepare the device without assuming install state
* install release 103;
* explicitly set `Documents/g15_mode` to the launch-1 mode and **read it back**;
* **do not assume install-over or `--rmtree` reset `Documents`** — it survives
  both;
* keep `rm` → `put` → read-back for every mode transition.

### 7. Run the frozen six-launch sequence
Same device, same checkpoints, same FFI SIGKILL primitive, same `afcclient`
observer, same scoring rules. **No debugger-driven launch inside the scored
sequence.**

### 8. Score row 5 at THREE layers — all must agree

| layer | required |
|---|---|
| **device/updater** | hard-kill leaves an ambiguous unfinished boot; next healthy launch does NOT retire the patch; state clears correctly after recovery |
| **client telemetry** | `ambiguous_boot_retry`, then `recovered_after_ambiguity`, under the SAME existing correlation identity: `client_id` + `app_id` + `release_version` + `patch_number` |
| **server** | both outcomes accepted; both persist DISTINCTLY; dedupe does not collapse them; lifecycle metrics count the client correctly |

## EXPECTED BEFORE / AFTER

Release 102's run is **immutable baseline evidence**. Do not re-score it.

| scenario | release 102 baseline | wired release 103 expected |
|---|---|---|
| hard-kill before success | breadcrumb remains | same |
| next process classification | terminal / single-strike retirement | **`ambiguous_boot_retry`** |
| healthy next launch | release fallback | **patched launch succeeds** |
| recovery telemetry | none | **`recovered_after_ambiguity`** |
| explicit Dart failure | explicit terminal failure | **must remain** explicit terminal failure |

That last row is a **regression control**: the new ambiguity policy must not
weaken explicit patch-blaming failure.

## NON-GOALS — do not spend time on

original Arm A · foldability / G15 execution mechanism · Route B language
widening · `TPOOL_AMBIGUOUS` · pragma effects · Android work · JWT issuer
configuration · the double-`main()` observation · redesigning lifecycle
thresholds *unless the frozen after-run disproves the current implementation* ·
general Flutter/Dart toolchain modernization.

**If the coherent publish pipeline fails, STOP and classify it as an
artifact-coherence/publishing issue. Do not turn this assignment into another
lifecycle investigation.**

## DEFINITION OF DONE — exactly two legitimate results

**PROVEN** — a coherent wired engine was published AND consumed, release 103 ran
the frozen sequence, and row 5 demonstrated
`hard-kill` → `ambiguous_boot_retry` → healthy patched launch →
`recovered_after_ambiguity`, with device, wire and server evidence agreeing.

**BLOCKED** — a coherent wired artifact set could not be produced or consumed
through the documented pipeline. The exact failed coherence/publish gate is
preserved, and **no lifecycle verdict is changed.**

---

# APPENDIX A — operational specifics (already established; do not re-derive)

## The stale-`version.cc` fix

Generated `version.cc` under `out/<cfg>/*/gen/.../dart/runtime/` hard-coded SDK
hash `6b58bb3a72` from 2026-08-10, while the Dart SDK git HEAD moved to
`9e8c898a4d2a3b4d…` on 2026-08-18. Delete those files so they regenerate from
current HEAD. This was NOT a toolchain defect. Diagnosed by noticing the freshly
built `gen_snapshot` was byte-identical to the old one, so the tool could not be
the variable.

## Mechanical provenance test for `ae1a4849`

The serde-generated string `recovered_after_ambiguity` appears in the shipped
binary; its source token `RecoveredAfterAmbiguity` is present at `ae1a4849` and
**absent at `ae1a4849~1`**. Grep the Rust variant, not the wire string — the wire
string never appears in source.

## Wiring discriminator in shipped bytes

BEFORE engine has **zero** occurrences of each; a wired engine has them:
`__patch_boot_lifecycle__`, `ambiguous_boot_retry`, `recovered_after_ambiguity`,
`retired_after_ambiguity`.

## Frozen identities

    fixture lib/main.dart  b284143628441e50543317f5f78ca7da12492aeca81987d29c4a4540589c813f
    release 102 App        D06B410E-9C99-38BD-952E-AD4A345A7908
    BEFORE engine (arm64)  4C4C44C0-5555-3144-A1DD-7EB2A7564480
    BEFORE engine sha256   4e2a46f1a5099c6e5f71afb27b254df4ed9e74bd9e969fa925c02ddfe71ffa71
    candidate wired engine 4C4C447D-5555-3144-A165-51D432516584  (built, never consumed)

Full freeze: `evidence/g15/sixlaunch_before/FREEZE.txt`.

## Device-state trap — check BEFORE launch 1

`Documents/g15_mode` currently reads **`dart-fail`**. `Documents` survives
install-over (proven: the receipt carried from release 101 to 102) and is NOT
under the `--rmtree` path. An unset mode would make launch 1 throw and the whole
sequence be scored against the wrong mode. **Set explicitly, verify by
read-back.** `afcclient`'s `put` does not overwrite an existing file and fails
silently.

## Rig state at handoff

`~/.shorebird` is restored to the coherent BEFORE set and verified by a real
patch build. Backups, hash-recorded in
`evidence/g15/build_coherence/ARTEFACTS.txt`:

    evidence_preserved/shorebird_ios_release_BEFORE   engine + snapshot tools
    evidence_preserved/shorebird_common_BEFORE        both patched SDKs
    evidence_preserved/build_coherence/               gen_snapshot pair + dill

## Already device-established — do not redo

* explicit vs inferred failure are observably different events — **device-PROVEN**;
* FFI SIGKILL hard-kill primitive — **device-qualified**, all four veto conditions;
* release-102 baseline — **PROVEN**, frozen;
* wiring + telemetry — BUILT, 287 updater tests, 299 server tests.

**Do not ship the wiring to devices ahead of the telemetry.**
