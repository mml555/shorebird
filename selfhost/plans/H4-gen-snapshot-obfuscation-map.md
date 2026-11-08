# H4 — gen_snapshot cannot load an obfuscation map (unblocks `G4.3`)

> At the end, our `gen_snapshot_arm64` accepts `--load-obfuscation-map`, an obfuscated Route B iOS release is patchable at all, and G4.3's arm table says honestly which of its five arms are constructible and which are not.

| field | value |
|---|---|
| status | **DONE 2026-08-14 — this order is executed. Do not take it.** ~~**NOT RUNNABLE** — not "unrun". The flag does not exist in our Dart tree, so the G4.3 obfuscated-matching arm has no harness. Building the harness is this order. Nothing here is PROVEN until step 12~~ All twelve steps ran. `selfhost/engine/0008-dart-load-obfuscation-map.patch` gives `gen_snapshot` `--load-obfuscation-map` (`4bcdcb9b`); `probes/g43_obfuscation_map_load.sh` **8/8** measuring `drift=0` AND `collisions=0`, with two sabotaged cursor modes reporting 44 and 81 collisions as the discriminating control; cell **`40eaa0ef6cb6485833bf2e10ac97224ca82cbf25`** minted, audited (18 checks) and published (`cdd32c8b`); and `G4.3`'s device arm **PROVEN** on `R1` — release 39 `--obfuscate`, patch 1, `OLD-rel` → `NEW-OBF` at `code_patch=1` with the release binary's `LC_UUID` unchanged (`550f0805`). **The verdict this order was written to produce: obfuscated iOS patching is REACHABLE, not a documented gap.** Three of the plan's own claims were refuted by measurement along the way and are corrected in the steps below — read those before reusing any of them |
| owns | `R3` route-b tree (Dart edit + iOS engine rebuild), `R4` ios-engine tree (only to land the patch on the `selfhost/experimental` Dart fork branch), `R11` sealed CDN (overlay publish + `experimental_hashes.map` entry). Device tier additionally claims `R1` iPhone, `R6` canonical fixture, `R8` `cps-ios` — claim those **when you reach step 11**, not up front |
| excludes | Any other goal needing `R3` (every Route B compiler change) or `R11` (every mint). Do **not** run concurrently with H1/H2 (the `G3.7` fixture, the `G4.2` flavored fixture) if those also intend to mint: two mints in flight produce two cell addresses and neither release can say which engine it consumed |
| blocked by | Nothing external. Blocked *internally* on step 3 landing before step 4 can be measured |
| unblocks | G4.3's `release --obfuscate, patch --obfuscate → patched value on device` arm (PARITY.md:3228). Also unblocks release 35 from `unpatchable by construction` (`probes/assert_result_consumed.sh:207`) |
| device needed | `R1` iPhone — for the PROVEN tier only. Steps 1–10 are host-only |
| mint needed | **Yes.** `gen_snapshot_arm64` ships inside `ios-release/artifacts.zip`, and that zip's digest participates in the cell address (`mint_route_b_cell.sh:71-93`, install verified at `:130-141`). A changed gen_snapshot is a new iOS engine hash and a new cell, by design |
| est. shape | Two to four days: a Dart-VM change (hours), a full iOS engine ninja (hours, unattended), a mint + overlay publish (an hour), a re-cut release and one device arm (an afternoon). Shape, not a promise — the cursor question in step 7 can eat a day on its own |

**Provenance.** Authored against the tree at `c0619d13` with every path and command checked by its
author, but **the adversarial verification pass did not run** (session limit) — so citations here are
first-draft rather than double-checked. Re-verify a claim before you act on it, and fix it in place
when it is wrong. `PARITY.md:NNNN` anchors move whenever that file is edited: if one looks wrong,
re-locate by grepping the quoted heading. Schema and house rules: [`README.md`](README.md).

## Why this is the piece it is

It is the only one of `c0619d13`'s four blocks that is **engine work**. H1 and H2 change a fixture; this changes the Dart VM, and therefore drags a mint, an overlay publish and a re-cut release behind it. Bundling it with a fixture order would make one commit whose failure mode is unattributable.

It deliberately does **not** include: the `--flavor` mismatch arms (H2), the parameterised-target fixture (H1), the two-engine host (H3), or any change to the CLI's obfuscation plumbing — the CLI already passes the flag correctly and its tests already assert it (`ios_patcher_test.dart:924`, `:950`). The bug is entirely below the CLI.

It also includes one piece of honest bookkeeping that costs nothing and is easy to skip: **reclassifying an arm that fixing gen_snapshot will not make constructible.**

## Preconditions — check these before claiming anything

1. **Tree clean, claims table read.** `git -C /Users/mendell/shorebird status --short` → empty; `sed -n '2846,2865p' /Users/mendell/shorebird/selfhost/PARITY.md` → confirm `R3`, `R4`, `R11` rows read **free**. Section 17's claims table starts at PARITY.md:2851. Note section 17:2795 still says `git worktree list` returns one entry; it returns **four** (main plus `shorebird-compat-study{,2,3}`, all detached HEAD). The rule stands, the count is stale.
2. **Write claim reports tree health, not just ownership. This is a HARD PRECONDITION of the iOS build, not a convenience check.** Before the engine build, `bash /Users/mendell/shorebird/selfhost/engine/dart_patches.sh --dest /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart --verify` → `OK: all 5 patches applied on the pinned base.` That output *is* the GREEN you report in the claims row. Anything else is RED and you stop.

   **Re-run it at the start of every sitting, and specifically before the iOS ninja.** A green verify recorded on a previous day says nothing about `R3` now: the tree is shared and not in git, so drift is invisible to `git status`. Since `2026-08-13` this is sharper than it used to be — `0005` and `0008` both edit `runtime/vm/compiler/aot/precompiler.cc`, so `PATCHES` order is load-bearing and an edit landing adjacent to `0005`'s hunk context makes `0005` report `[CONFLICT]` even though nothing is actually wrong with `0005`. Discovering that *after* a multi-hour iOS ninja costs the whole build; discovering it first costs seconds.
3. **The Dart base is the pinned one.** `git -C /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart log --oneline -2` → `6b58bb3a Add snapshot size accessors for code push` over `d684a576 Version 3.12.2`. `d684a576` is `PINNED_DART_COMMIT` at `dart_patches.sh:29`. A different base means the patch you derive will not apply anywhere else.
4. **[promoted precondition (a) — verify consumed bytes, never a stamp.]** Do not conclude anything about "our gen_snapshot" from a cache stamp. Measure the binary the CLI would actually exec — `shorebird_artifacts.dart:126-136` resolves it as `<flutterDirectory>/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64`:
   ```
   grep -c -a load-obfuscation-map ~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64
   ```
   → **0** today. And `cat ~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/internal/engine.version` → `4df8f9b6139b67d2cfe9f6aa8212372cade36278`, i.e. the cell, already installed over the stock stamp.
5. **[promoted precondition (d) — the CLI under test must be the CLI you changed.]** `git -C ~/.shorebird rev-parse --abbrev-ref HEAD` → `selfhost-under-test`; `git -C ~/.shorebird log --oneline -1` → `ba4e1c02`. It has a `fork` remote at `/Users/mendell/shorebird` and does **not** move when you commit here. Before step 11: `git -C ~/.shorebird fetch fork <branch> && git -C ~/.shorebird checkout --detach FETCH_HEAD`, then assert `grep -n 'supportedRouteBAnalysisVersion' ~/.shorebird/packages/shorebird_cli/lib/src/route_b_coverage.dart` → `8` (matches the cell; ours is at `route_b_coverage.dart:44`). Release 34 was DISCARDED for exactly this.
6. **[promoted precondition (b) — reload the mirror, clear caches that may hold fallback bytes.]** After step 9 writes the new hash into `selfhost/cdn/experimental_hashes.map`, the `cdn-cache` container must be recreated so Caddy re-reads the map. Caddy's `order cache before respond` means a cached fallback beats the 404 that ownership would return, so a stale cache silently serves the OLD engine.
7. **[promoted precondition (c) — warm the cache before the release that matters.]** Run one throwaway `shorebird release ios` (or `flutter precache`) on the new hash and confirm the gen_snapshot binary exists on disk *before* cutting the release you intend to keep. Release 33 was DISCARDED because a cleared cache plus a first build made `isRouteBEngine` read a Flutter binary that did not exist yet; the CLI took the non-Route-B path and **reported success** with 8 sites at 2/MB.
8. **Do not skip `assert_mint_ready.sh`.** `build_ios_release.sh` exits 0 whether or not ninja succeeded. `bash /Users/mendell/shorebird/selfhost/engine/route_b/probes/assert_mint_ready.sh` must print `VERDICT=success`. `unknown` is not success.

## Steps 1-2 EXECUTED — 2026-08-13, measured, not re-derivable by reading

**Step 1 settled: BRANCH B.** `grep -rn "load_obfuscation_map\|load-obfuscation-map"` over
`$D/runtime/` returns NOTHING, and our built `gen_snapshot_arm64 --help` advertises
`--save-obfuscation-map=<map-filename>` only. The feature must be written.

**Step 2 recovered, verbatim, from the previous pin's fork binary**
(`~/.shorebird/bin/cache/flutter/309dd657…/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64`).
This IS the contract — put it in the patch header as the derivation:

```
--load_obfuscation_map=
--load_obfuscation_map=%s
Empty value for option load_obfuscation_map
--load-obfuscation-map=<...> should only be specified when obfuscation is enabled
    by the --obfuscate flag.
Obfuscation map is already initialized.
Could not load obfuscation map: file callbacks not set
Could not open obfuscation map file: %s
Invalid obfuscation map: expected '['
Invalid obfuscation map: expected '"'
Invalid obfuscation map: unterminated string
Invalid obfuscation map: odd number of entries (expected pairs)
Path to a JSON obfuscation map file to load before kernel translation. Used for
    consistent obfuscation across patch builds.
```

Five design facts follow from those strings alone, and none of them is a guess:
1. the option is a STRING_OPTIONS_LIST entry with empty-value validation, exactly
   like `save`;
2. its validation MIRRORS save's (`--obfuscate` required);
3. loading twice is an ERROR, not a merge — "already initialized";
4. the file is read through the EMBEDDER FILE CALLBACKS, not `fopen` — which is why
   the setter belongs in the runtime beside `Dart_GetObfuscationMap`, not in `bin/`;
5. the parser is hand-written over a flat JSON array of PAIRS, not a `{}` object.

**Seams verified in OUR tree** (the plan's line numbers were first-draft; these are
measured):

| seam | where, verified |
|---|---|
| the option list | `runtime/bin/gen_snapshot.cc:117` — `V(save_obfuscation_map, obfuscation_map_filename)` |
| the getter to sit beside | `runtime/include/dart_api.h:4312`, impl `runtime/vm/dart_api_impl.cc:7157` |
| the state to populate | `runtime/vm/compiler/aot/precompiler.h:511-520` — `ObjectStore::obfuscation_map()` is a 2-element Array, `kSavedStateNameIndex = 0`, `kSavedStateRenamesIndex = 1` |

One correction to the plan: the validation string it cites at `gen_snapshot.cc:313-318`
does NOT appear in our tree with that wording — grep for the phrase returns nothing,
so locate save's validation by its option name rather than by the message text.

**STEP 7 BUILT AHEAD OF STEP 3, deliberately.**
`probes/g43_obfuscation_map_load.sh` exists and reports **NOT RUNNABLE (exit 2)**
today, naming the absent flag. Writing the acceptance criteria before the
implementation means the fix cannot be graded against its author's expectations —
and the probe's own header says why the flag alone is not the gate: accepting
`--load-obfuscation-map` and then renaming INCONSISTENTLY would be worse than
refusing it, because the patch would build, ship, and bind to names the release does
not have. Its three arms: the flag is advertised; every rename in map A survives
into B; and no two identifiers in B share an obfuscated name — the cursor question,
made measurable.

**THE MAP FORMAT, MEASURED** from the real 629 KB map our own engine wrote for
release 35 (`airgap_app/build/shorebird/obfuscation_map.json`): a FLAT JSON ARRAY of
strings, even length, consecutive `[original, renamed]` pairs — 39,660 entries,
19,830 pairs — and it DOES contain empty-string pairs, which the parser must
tolerate rather than reject. That is the parser's input contract and it agrees with
the reference binary's four error strings.

**STEP 3'S IMPLEMENTATION FACTS, ALL MEASURED — write the code from these**

| fact | measured at |
|---|---|
| the state is `Array[2]`: `[0]` = the rename cursor as a `String`, `[1]` = an `ObfuscationMap` hash table | `precompiler.cc:3991-3994` (`SaveState`) |
| a fresh Obfuscator only calls `InitializeRenamingMap()` when `obfuscation_map()` is NULL | `precompiler.cc:3832-3848` |
| so a PRE-SET map must already contain the identity renames — and a saved map does, because they were serialized with it | follows from the above |
| the table type and insertion API | `precompiler.h:445` `typedef UnorderedHashMap<ObfuscationMapTraits> ObfuscationMap`; `precompiler.cc:3959` `renames_.UpdateOrInsert(name, renamed_)`; `:4116` `ObfuscationMap renames_map(renames.ptr())`; `:3993` `renames_.Release()` |
| **the collision hazard is real, not hypothetical** | `precompiler.cc:4037` — `} while (renames_.GetOrNull(renamed_) == renamed_.ptr());` loops only while the candidate is an IDENTITY rename. A name already used as a VALUE is not rejected |
| the cursor buffer | `char name_[100]`, `precompiler.h:601` |

**THE CURSOR DECISION, made and to be measured rather than assumed.** ~~The JSON
carries pairs only, so the cursor must be reconstructed. Set it to the greatest
generated-looking value in the loaded map — comparing by LENGTH first, then
lexicographically, over values that are entirely `[a-z]` — because that is the order
`NewAtomicRename` generates in.~~ **REFUTED BY MEASUREMENT — see "What step 3
executed" below.** The premise (reconstruct the cursor as the greatest generated
value) is right; the *rule* is wrong three times over. Leaving it empty restarts at
`a` and, by `:4037` above, hands a second identifier a name the release already spent.
`probes/g43_obfuscation_map_load.sh` arm (c) is exactly this measurement, and it must
be run BOTH ways: with the cursor restored (expect 0 collisions) and, once, with it
deliberately zeroed to confirm the probe can SEE a collision. A probe that cannot
fail proves nothing.

**SHAPE THAT KEEPS THE VM SURFACE SMALL:** ~~parse the JSON in `bin/gen_snapshot.cc`,
where the reference binary's parser errors live, and hand the VM a flat
`const char** pairs, intptr_t count`. Then the new API is
`Dart_LoadObfuscationMap(const char** pairs, intptr_t count)` delegating to a new
`Obfuscator::LoadState(Thread*, const char**, intptr_t)` in `precompiler.cc`.~~
**REFUTED BY MEASUREMENT — this shape cannot work; see below.** It would place the
load *after* the obfuscation state is already seeded and already renaming, i.e. it
would accept the flag and rename inconsistently — the one outcome this order exists
to prevent. The claim that our shape "DIVERGES from the reference binary" was also
wrong in the other direction: the reference used a VM flag and embedder file
callbacks, and so, now, do we. We **converge** with it.

## What step 3 executed — 2026-08-13, and the two plan claims it REFUTED

Step 3 is **DONE on the host**. `selfhost/engine/0008-dart-load-obfuscation-map.patch`
exists, is appended to `dart_patches.sh`, and
`dart_patches.sh --dest $D --verify` → **`OK: all 5 patches applied on the pinned
base.`** The host `gen_snapshot` rebuilt clean and advertises the flag. Steps 6
(iOS rebuild), 8 (mint) and 10–13 are **not** started.

**REFUTATION 1 — the chosen shape could not have worked.** The plan put the loader
behind a `Dart_LoadObfuscationMap` called from `bin/gen_snapshot.cc`. Measured under
lldb on the host binary, breaking on `Obfuscator::InitializeRenamingMap`:

```
frame #0  dart::Obfuscator::InitializeRenamingMap()
frame #1  dart::Obfuscator::Obfuscator(dart::Thread*, dart::String const&)
frame #2  dart::BootstrapFromKernelSingleProgram(...)
frame #3  dart::Object::Init(dart::IsolateGroup*, ...)
frame #4  dart::CreateIsolate(...)
frame #5  Dart_CreateIsolateGroupFromKernel
frame #6  dart::bin::main(int, char**)
```

`Dart_Precompile` had not yet been reached. The map is seeded *inside*
`Dart_CreateIsolateGroupFromKernel`, so by the time `bin/` regains control it exists
and kernel translation has begun renaming — `kernel_translation_helper.cc` builds an
`Obfuscator` in **seven** places. An embedder-side call could only merge into a live
map. Related plan errors, corrected: library/script URLs are **not** renamed during
kernel translation (they are renamed at the end of precompilation, in
`Precompiler::Obfuscate`), and `dart_api_impl.cc:7157` / `dart_api.h:4312` are **not**
seams — no new embedder API is added.

The correct seam is the fresh-start branch of the `Obfuscator` constructor, reached
via a VM flag. Two controls prove the reference fork binary did the same: it carries
`--load_obfuscation_map=%s` (a forwarding format; no `--<flag>=%s` string exists in
ours), and `Dart_GetObfuscationMap` appears as a string in **both** binaries while no
`Dart_*Obfuscation*` Load/Set symbol appears in either.

**REFUTATION 2 — the cursor rule was wrong three times over.** `NextName` gives
`inc(a)=b … inc(z)=A … inc(Z)=a & carry`, a fresh position starts at `a`, and
`name_[0]` is the LEAST significant digit. The renames are a **bijective base-52
numeral written little-endian**. So the plan's "greatest value entirely `[a-z]`, by
length then lexicographic" is wrong because (i) the alphabet is `[a-zA-Z]`, (ii) the
most significant digit is the LAST character, so plain lexicographic reads it
backwards, and (iii) identity renames (`key == value`, e.g. `dynamic`) are not
generated names and must be excluded. Simulated against the generator, the plan's
rule lands **6** names early at 500 generated names, **10** at 3,000, and **2,398**
at 20,000 — and release 35's real map has 19,830 pairs.

**REFUTATION 3 — the step-7 probe could not fail.** `g43_obfuscation_map_load.sh`
compiled *the same kernel twice*, so every identifier was already in the loaded map,
`NewAtomicRename` was never called, and the cursor was never consulted. All three
cursor modes reported 0 collisions. Rewritten to compile a "release" and then a
"patch" containing new identifiers — which is what a patch build actually is — the
modes separate cleanly:

| specimen | mode 1 (correct) | mode 0 (no restore) | mode 2 (refuted rule) |
|---|---|---|---|
| same kernel twice | 0 collisions | **0** — cannot fail | **0** — cannot fail |
| release, then release+new | **0 collisions** | **44** | **81** |

Drift is **0 in every mode**, so consistency (arm c) passes even with a wrong cursor:
arm (d) is the only arm that catches this, and the new arm (e) is the only thing that
proves arm (d) is alive. Collisions have the predicted shape — a new patch identifier
sharing a name with a release one, e.g. `_Ua <- {_pf2b, _RegExpMatch}`.

**The instrument.** `--obfuscation_cursor_mode` ships with the patch: `1` correct
(default), `0` no restore, `2` the refuted rule. It exists so the probe can
demonstrate it distinguishes *correct* from *almost correct*, not merely *present*
from *absent*.

**STILL NOT STARTED: steps 6, 8–13.** The iOS engine rebuild, the mint, the release
and the device arm. `R3`'s Dart checkout is captured in `0008` and `--verify` is
green, so the shared-tree hazard below is closed for this edit.

## Steps

1. **Settle the branch question first — does upstream Dart have a load path at all?** This decides the whole order, so it is step 1 and both outcomes are precommitted below.
   ```
   D=/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart
   grep -rn "load_obfuscation_map\|load-obfuscation-map" $D/runtime/ | head
   git -C /Volumes/build/ios-engine/dart-sdk log --all --oneline -S"load_obfuscation_map"
   ```
   Both return **nothing** (measured 2026-08-13). Stock Dart 3.12.2 has `save` only: `gen_snapshot.cc:117` registers `V(save_obfuscation_map, obfuscation_map_filename)` and there is no `load` sibling. **Branch B is the live one: the feature must be written.**
2. **Recover the reference spec, read-only, from the Shorebird-fork binary we already have on disk.** The previous pin's engine `e1eaecbc` *does* carry the flag — `grep -c -a load-obfuscation-map ~/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64` → **10**. Its string table is the contract:
   ```
   strings -a ~/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64 | grep -i obfuscat | sort -u
   ```
   It yields, verbatim: a validation mirror (`--load-obfuscation-map=<...> should only be specified when obfuscation is enabled by the --obfuscate flag.`), an already-loaded guard (`Obfuscation map is already initialized.`), embedder-file-callback use (`Could not load obfuscation map: file callbacks not set`, `Could not open obfuscation map file: %s`), a hand-written JSON parser (`Invalid obfuscation map: expected '['` / `expected '"'` / `unterminated string` / `odd number of entries (expected pairs)`), and the help line **`Path to a JSON obfuscation map file to load before kernel translation. Used for consistent obfuscation across patch builds.`** Write this into the patch's header as the derivation, so nobody later thinks the design was invented.
3. **Write the patch.** Four seams, all cited:
   - `$D/runtime/bin/gen_snapshot.cc:110-117` — add `V(load_obfuscation_map, load_obfuscation_map_filename)` to `STRING_OPTIONS_LIST`.
   - `$D/runtime/bin/gen_snapshot.cc:313-318` — mirror the `save` validation for `load`.
   - `$D/runtime/vm/dart_api_impl.cc:7157` (`Dart_GetObfuscationMap`) + `$D/runtime/include/dart_api.h:4312` — add the setter next to the getter. It belongs in the runtime, not `bin/`: the reference's `file callbacks not set` message proves it reads the file through the embedder callbacks.
   - Call it from `gen_snapshot.cc` **before** kernel translation — the kernel is read in `CreateIsolateAndSnapshot` (`gen_snapshot.cc:748`) and precompilation starts at `gen_snapshot.cc:677` (`Dart_Precompile()`). Library URLs themselves are renamed (`precompiler.cc:3496-3499`), which is why "before kernel translation" and not merely "before Precompile".
   The state it must populate is `ObjectStore::obfuscation_map()`, the 2-element Array the `Obfuscator` constructor restores from (`precompiler.cc:3819-3847`; layout `kSavedStateNameIndex = 0`, `kSavedStateRenamesIndex = 1` at `precompiler.h:513-517`). **Good news:** the top-level obfuscator is built with an *empty* private key (`precompiler.cc:3477`), so no private key needs restoring.
   **[MUTATES the Dart checkout on /Volumes/build/route-b]** — it is not in git; that is exactly why `dart_patches.sh` exists.
4. **Answer the cursor question explicitly, in the patch, with a comment.** The JSON map carries pairs only. The saved state also carries the rename cursor `name_` (`char name_[100]`, `precompiler.h:601`), written by `SaveState` at `precompiler.cc:3991-3995`. `NewAtomicRename` (`precompiler.cc:4029-4040`) loops only while the candidate is an **identity** rename — it does not reject a name already in use as a *value*. So a load that leaves the cursor at zero restarts at `a` and can hand two distinct identifiers the same obfuscated name. No reference string mentions a cursor, so the reference may well not restore it. Pick one and say why; step 7 measures the consequence.
5. **Join the patch to the series and its `--verify` contract.** New file `selfhost/engine/0008-dart-load-obfuscation-map.patch` (siblings: `0004-dart-tearoff-selector-guard.patch`, `0005-dart-precompiler-link-info-and-tearoffs.patch`, `0006-dart-no-dispatch-call-for-hash-slots.patch`). Append it to `PATCHES` in `dart_patches.sh:38-43`. How you know it worked: `bash selfhost/engine/dart_patches.sh --dest $D --verify` → `OK: all 5 patches applied on the pinned base.` A `[CONFLICT]` line means re-derive; a `[MISSING]` line means you edited the tree without producing the patch.
6. **Rebuild the iOS engine.** `cd /Volumes/build/route-b && bash flutter/engine/src/flutter/../../../../selfhost/engine/route_b/build_ios.sh` — in practice use the SSD's `run_mint_build.sh` driver as the mint did; `build_ios.sh:63-65` is the ninja line. **How you know it worked:** `bash selfhost/engine/route_b/probes/assert_mint_ready.sh` → `VERDICT=success`, *and* the flag is now present:
   ```
   /Volumes/build/route-b/flutter/engine/src/out/ios_release/artifacts_arm64/gen_snapshot_arm64 --help 2>&1 | grep obfuscation-map
   ```
   → must list **both** `--save-obfuscation-map=` and `--load-obfuscation-map=`. Today it lists only `save` (measured).
7. **Build the probe that does not exist yet: `selfhost/engine/route_b/probes/g43_obfuscation_map_load.sh`.** `probes/` has no gen_snapshot-capability probe and no map-load probe; building it is this step. It must, host-only, with no CLI and no device:
   a. assert the flag is advertised (the `--help` grep above);
   b. compile one kernel twice — once with `--obfuscate --save-obfuscation-map=A`, then a second compilation with `--obfuscate --load-obfuscation-map=A --save-obfuscation-map=B`;
   c. assert every key in A maps to the same value in B (**consistency**, the flag's whole purpose);
   d. assert no two distinct keys in B share a value (**the cursor question from step 4, made measurable**).
   Model its shape and its "classified by measurement, not by name" discipline on `probes/g43_obfuscation_semantics.sh` (8/8; its header at lines 1-42 states the method).
8. **Mint.** ~~`bash selfhost/engine/route_b/publish_ios_overlay.sh`~~ — **PATH CORRECTED 2026-08-13: the script is `selfhost/engine/publish_ios_overlay.sh`, NOT under `route_b/`.** (The plan also spelled the override `/Volemes/`.) The `OUT` warning is real and confirmed, at `:29` rather than `:30`: it defaults to `/Volumes/build/ios-engine/...`, the *wrong tree* for a route-b build. Set `OUT=/Volumes/build/route-b/flutter/engine/src/out/ios_release` explicitly.

   **A prerequisite the plan does not mention, verified:** the publisher requires `$OUT/universal/gen_snapshot_arm64`, a **universal x86_64+arm64** binary (`:41`, `:45`, with an explicit `lipo -archs` assertion at `:52-54`) — *not* the arm64-only `artifacts_arm64/gen_snapshot_arm64`. It is a build output and the iOS ninja compiles both `clang_arm64` and `clang_x64` slices, so it regenerates. **Verify the flag in the UNIVERSAL binary and in BOTH slices.** That file is what ships in the zip and what a release actually execs; a stale x64 slice would leave the flag present on an arm64 host and absent on an Intel one — a favourable-looking failure of exactly the shape precondition 4 exists for. Then `bash selfhost/engine/route_b/mint_route_b_cell.sh --donor <the new iOS engine hash> --dry-run`, read the address, then run it for real. **[MUTATES selfhost/cdn/overlay and experimental_hashes.map]** The address MUST differ from `4df8f9b6139b67d2cfe9f6aa8212372cade36278` — the zip digest is in the manifest precisely so an embedder-only change cannot reuse an address (`mint_route_b_cell.sh:71-93`).
9. **Reload the mirror and clear the cache.** Precondition 6. **[MUTATES the running cdn-cache container]** How you know: the new hash's `ios-release/artifacts.zip` serves byte-identical to `selfhost/cdn/overlay/flutter_infra_release/flutter/<new>/ios-release/artifacts.zip`, and the *old* hash still serves its own bytes (the control).
10. **Sync the CLI under test, warm the cache, then cut the release that matters.** Preconditions 5 and 7, in that order. Cut an **obfuscated** release: `shorebird release ios --obfuscate` against `selfhost/fixtures/airgap_app`. `releaser.dart:198-205` adds `--extra-gen-snapshot-options=--save-obfuscation-map=<path>`; `releaser.dart:160-168` auto-adds `--split-debug-info`. **[MUTATES R6's pubspec version and R8's release table]** How you know: `bash selfhost/engine/route_b/probes/preserve_release_evidence.sh` writes `selfhost/evidence/releases/37/{App,LC_UUID,RECORDED}` with a four-figure `patchable` count in the thousands-per-MB range — release 35's `RECORDED` shows `7,139 (2,092 per MB)`; **8 sites at 2/MB means you are on the non-Route-B path** (release 33's failure).
11. **Patch it. This is the decisive step.** `shorebird patch ios` with **no** obfuscation flag — the CLI mirrors the release on its own: `patch_command.dart:653-661` injects `--obfuscate` and `--extra-gen-snapshot-options=--load-obfuscation-map=<map>`, and `patcher.dart:83-96` (`obfuscationGenSnapshotArgs`) supplies the bare-flag form to `ios_patcher.dart:152` (`buildElfAotSnapshot`) and `:308` (`runLinker`). Today this dies at `Target aot_assembly_release failed: AOT snapshotter exited with code 255`. **[MUTATES R6, R8, R1]**
12. **Device arm.** Install, apply, read the patched value on `R1`. Claim `R1`/`R6`/`R8` now, in the claims table, in the same commit.
13. **The bookkeeping step, which is not optional.** Edit PARITY.md's arm table (`:3218-3234`) per "The arm table, corrected" below, and append a status row for the new capability. Do **not** delete the ⛔ row at `PARITY.md:2086` — it remains a true statement about cell `4df8f9b6`. Point it at the new row.

## Precommitted outcomes

**Step 1 — does upstream Dart have a load path?** (host/source finding)

| observation | meaning |
|---|---|
| A: `load_obfuscation_map` appears in `$D/runtime/` | cherry-pick or enable, not write. Order shrinks to steps 5-13 |
| **B: it appears nowhere, and `git log --all -S` finds no commit** | **the measured result.** The feature must be written. Steps 2-4 are load-bearing |
| C: it appears only in `third_party` or a test | treat as B; a test fixture is not an implementation |

**Step 6 — the rebuilt binary's `--help`** (host finding)

| observation | meaning |
|---|---|
| both `save` and `load` listed | the flag exists. Says **nothing** about correctness — go to step 7 |
| only `save` listed, ninja exit 0 | the patch did not reach the binary. Suspect a stale `out/` or a `--verify` you skipped. **This is the favourable-looking failure**: a green build with an unchanged binary |
| ninja fails | ordinary compile error. Fix and repeat; do not mint |

**Step 7 — the map-load probe** (host findings, and the ones worth trusting)

| observation | meaning |
|---|---|
| 7c pass, 7d pass | consistency achieved and no value collisions. The cursor decision in step 4 was right. Earns **BUILT** for the capability |
| 7c pass, 7d **fail** | the flag loads but the cursor was not restored: two identifiers share one obfuscated name. **Do not mint.** Route B resolves its target by library URI and name at attach time, so this is exactly the class of bug that surfaces on device as "function not found" with every flag check passing first |
| 7c fail | not a load at all — the map was read and ignored, or the parser silently accepted garbage. Check the `odd number of entries` path |
| probe errors before arm (a) | NOT RUNNABLE, not a failure. Say so |

**Step 11 — the patch build** (host finding; the CLI's own log is the evidence)

| observation | meaning |
|---|---|
| exit 255 at `aot_assembly_release` | unchanged. The engine under test is not the engine you built — re-check precondition 4 against the **consumed** binary |
| AOT completes, Route B reached, container produced | the block is cleared. **BUILT.** Not PROVEN — nothing has executed |
| AOT completes but the CLI refuses on build-configuration mismatch | a real defect in step 3's plumbing, not an arm result: `ios_patcher.dart:774-793` compares `releaseConfig.agreesWith(patchConfig)` where `patchConfig` is built at `:757` from `[...forwardedArgs, ...extraBuildArgs]`. Since `extraBuildArgs` contains the injected `--obfuscate`, agreement is structural. A refusal here means the injection changed |

**Step 12 — the device arm.** Reuse PARITY.md:3222-3234 **verbatim**; do not restate it. The row this order retires is `release --obfuscate, patch --obfuscate → patched value on device`. Per that table's own rule: a refusal arm that reaches the device has already failed, and a matching arm that only shows "the CLI accepted it" proves nothing about execution.

## The arm table, corrected — and the arm that fixing gen_snapshot will NOT fix

PARITY.md:3222-3234 lists five arms. After this order:

| arm | verdict |
|---|---|
| release `--flavor foo`, patch `--flavor bar` → REFUSED | untouched; P3's business |
| **release `--obfuscate`, patch plain → REFUSED** | **UNCONSTRUCTIBLE THROUGH THE CLI — a KNOWN GAP in the harness, not an unvalidated question. Remove it from the device queue.** And note *why*, because it is not the missing flag: `patch_command.dart:724` sets `patcher.extraBuildArgs`, which contains `--obfuscate` whenever the release shipped a map (`:653-661`), and `ios_patcher.dart:757` derives the patch fingerprint from exactly those args. The two configurations agree **by construction**. Fixing gen_snapshot does not make this arm constructible; only removing the mirror would, and the mirror is the correct behaviour |
| release `--obfuscate`, patch `--obfuscate` → patched value on device | **this is what H4 unblocks** |
| release `--flavor foo`, patch `--flavor foo` | untouched; P3 |
| release flavored by `default-flavor` only | untouched; P3 |
| **NEW: release plain, patch `--obfuscate` → REFUSED** | **constructible TODAY, on the current engine, with no mint.** `patch_command.dart:627-634`: `flagPresent('obfuscate')` with a null `obfuscationMapFile` → `logger.err` + `ProcessExit(ExitCode.software.code)` at line ~630, and `buildPatchArtifact` is not called until `:745`. So the refusal happens **before any patch artifact exists**, which is precisely what the arm table requires of a refusal arm. This is a cheap, honest substitute for the claim "obfuscation is semantic" |

The semantic classification itself needs no device and is already earned by measurement: `route_b_build_config.dart:59-64` records that `--obfuscate` changes the stripped program bytes (so it is fingerprinted) and `:66-80` that `--split-debug-info` and its path change only DWARF (so they are excluded — on evidence, not oversight).

## Exit criteria

- **BUILT** — the rebuilt `gen_snapshot_arm64` advertises `--load-obfuscation-map`; `g43_obfuscation_map_load.sh` passes all four arms including the collision arm; the cell is minted and audited (`audit_route_b_compiler.sh` AUDIT CLEAN); an obfuscated release is cut and a patch container is produced for it. This is a host probe result. It earns BUILT and nothing more.
- **PROVEN** — and only this: the obfuscated release installed on `R1`, the patch downloaded from this control plane, applied on next launch, and **the patched value observed on the screen**. A CLI that exits 0 is not a proof.
- **NOT RUNNABLE** rather than unrun — if step 1 lands on branch B *and* the cursor question in step 4 has no answer that survives step 7d, the arm has no correct harness and must be recorded NOT RUNNABLE with the collision measurement attached. That is a real outcome, not a failure to try.

## Evidence to record

| path | must contain |
|---|---|
| `selfhost/engine/0008-dart-load-obfuscation-map.patch` | the diff, plus a header naming the four seams (`gen_snapshot.cc:110-117`, `:313-318`, `dart_api_impl.cc:7157`, `dart_api.h:4312`) and the step-2 string-table derivation |
| `selfhost/engine/dart_patches.sh` | the new patch appended to `PATCHES` (`:38-43`) |
| `selfhost/engine/route_b/probes/g43_obfuscation_map_load.sh` | four arms, each printing its own PASS/FAIL, exit non-zero on any failure |
| `selfhost/evidence/releases/37/{App,LC_UUID,RECORDED}` | via `preserve_release_evidence.sh`. `RECORDED` must show a four-figure `patchable` count and per-MB in the thousands |
| `selfhost/engine/route_b/probes/assert_result_consumed.sh` | a new corpus row for release 37, and **edit** row `35` (`:207`) only to cross-reference — 35 stays `unpatchable by construction`, which was true of the engine it was cut against |
| `selfhost/cdn/experimental_hashes.map` | the new cell → stock-hash entry |
| PARITY.md | new status row; the arm-table corrections above; claims rows |

Identity facts every one of these must state: **new cell address** (40 hex), **new iOS engine hash**, donor, `dart2bytecode.aot` and `route_b_analyze.aot` digests (unchanged from `4df8f9b6` — only the iOS zip moves), Flutter revision `c15ef6379403a0a55531a058bdb2c8e55bc05c98`, Dart base `d684a576` + `6b58bb3a`, release **37**, patch number, platform iOS / `R1` iPhone 7, probe `g43_obfuscation_map_load.sh`, and the commit SHA.

## Commit shape

Three commits, each independently true.

**1 — the engine capability (host, no device).**
```
git add selfhost/engine/0008-dart-load-obfuscation-map.patch \
        selfhost/engine/dart_patches.sh \
        selfhost/engine/route_b/probes/g43_obfuscation_map_load.sh \
        selfhost/PARITY.md
```
Title: `feat(selfhost): G4.3 — gen_snapshot learns to load an obfuscation map`. Same commit must carry the PARITY status row (**BUILT**, with the probe's arm counts) and the `R3`/`R4` claims rows with **tree health GREEN**.

**2 — the mint and the corrected arm table.**
```
git add selfhost/cdn/experimental_hashes.map \
        selfhost/engine/route_b/mint_route_b_cell.sh \
        selfhost/PARITY.md
```
Title: `feat(selfhost): mint <cell> — the iOS engine that can load a map`. This is the commit that carries the arm-table correction, because that is where the unconstructible arm becomes provable-by-reading rather than asserted.

**3 — the release and the device arm.**
```
git add selfhost/fixtures/airgap_app/pubspec.yaml \
        selfhost/evidence/releases/37 \
        selfhost/engine/route_b/probes/assert_result_consumed.sh \
        selfhost/PARITY.md
```
Title: `test(selfhost): G4.3 — an obfuscated iOS release, patched on device`. Same commit clears `R1`/`R6`/`R8`/`R11` claims rows.

Never `git add -A`, never `commit -a`, never stash/restore/checkout/branch-switch — section 17 rules 1 and 2; `9192a594` is the recorded cost.

## Do not

- **Do not "add the flag to the CLI."** It is already there and already tested (`patcher.dart:86`, `patch_command.dart:658`, `ios_patcher_test.dart:924`). The CLI is correct; the binary is not.
- **Do not conclude the flag exists from a `--help` you ran against the wrong binary.** `~/.shorebird` holds two Flutter caches; `309dd657` (previous pin, engine `e1eaecbc`) **has** the flag and `c15ef637` **does not**. Grepping the first one and believing it is the fastest way to skip this entire order for nothing.
- **Do not credit `gen_snapshot --help` as more than advertisement.** An advertised flag that silently ignores its file passes every check except step 7c. That is the favourable-looking outcome the precommitment rule exists for.
- **Do not mint from a build whose ninja you did not check.** `build_ios_release.sh` exits 0 regardless. `assert_mint_ready.sh` re-derives the verdict from primitives and reports a DISAGREEMENT between a build's summary line and its primitives as a **defect**, not a tiebreak.
- **Do not restamp `engine.version` and call the engine established.** Verify the consumed bytes (precondition 4). Release 25's stamp claimed artifacts the cache never fetched.
- **Do not cut the release before warming.** Release 33 read a Flutter binary that did not exist, took the non-Route-B path, and **reported success** at 8 sites / 2 per MB.
- **Do not cut with the unsynced CLI.** Release 34 recorded no `buildConfig` and pinned `analysisVersion` 7 against a v8 cell — every patch refused as too new, *which looks exactly like a G3.7 failure and is not one*.
- **Do not leave `release --obfuscate, patch plain` in the device queue** after step 13. It is a KNOWN GAP, decided by reading `patch_command.dart:724` and `ios_patcher.dart:757`. Queueing something source already closes is the classification error the house rules name.
- **Do not upgrade `PARITY.md:2086`.** It is a true statement about cell `4df8f9b6`. Add a row; cross-reference; leave the finding standing.

## Open questions

1. **Build it now, or defer it?** State the demand evidence honestly: **PARITY has no obfuscation frequency data at all.** Frequency evidence exists only for lexical features from the Phase 0 corpus (compound writes 0, `super` 2 occurrences — PARITY.md:487, :2976), and those are what "resume only on frequency evidence" (PARITY.md:3278) was written about. The nearest thing to demand for *this* is that **Android** obfuscated crash symbolication is already **PROVEN** (PARITY.md:2085), which does imply real users obfuscate — on the platform that already works. The tradeoff: building it costs a Dart-VM change, a full iOS engine rebuild, a mint, a CDN reload and a re-cut release, and it retires **one** of five arms. Deferring costs an *unbounded* hole — "an obfuscated release cannot be patched on this engine" is not a missing test, it is a missing product capability, and it will be discovered by the first user who ships obfuscated. **My read: build it, but sequence it after H2 and P3**, which each retire an arm for a fraction of the cost and need no mint. Do not decide this silently either way — record the decision with its reason.
2. **Restore the rename cursor, or not?** Restoring it needs a rule for deriving `name_` from a map that does not contain it (e.g. the greatest value under `NextName`'s `a..zA..Z`-with-carry ordering, `precompiler.cc:4006-4027`). Not restoring it matches what the reference binary's strings suggest, and is simpler, but step 7d may fail. If it does: is a duplicate obfuscated name actually harmful for Route B, whose attach-time lookup is by library URI *and* name? Answer by measurement, not by reasoning about it.
3. ~~**Should the new flag be added to `routeBUnfingerprintableOptions`?**~~ **ANSWERED 2026-08-13 by reading the code: NO — and it needs no change at all, because it already does not participate.**

   The classification is right: `--load-obfuscation-map` is a Route B patch-compilation input derived from release artifacts, not a release build-configuration input, and its presence or path must not affect release-vs-patch compatibility. But that is already the behaviour, and the proposed mechanism would be actively harmful.

   **Why no change is needed.** Equality is decided by `canonicalForm` (`route_b_build_config.dart:241-248`), which is `obfuscate` plus the sorted `effectiveDefines` — nothing else; `agreesWith` is just `canonicalForm == other.canonicalForm` (`:255-256`). `fromBuildArgs` (`:133-186`) recognises only `--obfuscate`, `--split-debug-info`, the unfingerprintable list, and `--dart-define`; **every other argument hits `continue` and is ignored.** `--extra-gen-snapshot-options=--load-obfuscation-map=<path>` matches none of them, so it lands only in `rawArgs`, which is documented "Audit only" (`:214`) and is not in `canonicalForm`. A correct obfuscated patch therefore already agrees with its release.

   **Why adding it to the list would be a defect.** `routeBUnfingerprintableOptions` is **not** an "exclude this option from the fingerprint" list. It is a poison pill: a match makes `fromBuildArgs` `return null` (`:157-160`), and null means *"cannot be fingerprinted"*, which the caller must treat as its own state (`:129-132`) and which surfaces as the refusal/skip messages at `ios_patcher.dart:784` and `:790`. Adding the flag there would make **every obfuscated patch** unfingerprintable and silently disable the define, flavor and `--obfuscate` comparison for exactly the releases that most need it. It is `--dart-define-from-file`'s list because that option makes the effective define set *unknowable*, which is a different thing from *irrelevant*.

   **Exclusion is not irrelevance — the same distinction `splitDebugInfoPath` carries** (`:239-240`, excluded "on the evidence… not by omission"). The map's correctness must be enforced elsewhere, and none of this is fingerprinting's job:
   * an obfuscated release must produce and preserve a release obfuscation map;
   * patch compilation must consume *that exact preserved map*, not any map;
   * a missing or wrong map must fail as an **artifact/provenance** error, loudly, not as a compatibility refusal;
   * its filesystem path must never be semantic.

   Add a narrow comment at the flag's injection site recording this, so the next reader does not re-derive it — but no list edit, and re-verify these anchors before acting, since `ios_patcher.dart` is not this lane's file.
4. **Does the patch belong on `/Volumes/build/ios-engine/dart-sdk`'s `selfhost/experimental` branch as well?** `create_dart_fork.sh` and `dart-fork/0001-snapshot-size-accessors.patch` exist so a build host is reproducible. If the answer is yes, `R4` is a write claim, not a read one.