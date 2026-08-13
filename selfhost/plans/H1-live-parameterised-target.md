# H1 — a parameterised target on the LIVE path (unblocks `G3.7`)

> At the end, the canonical fixture has instance methods carrying their **own source
> parameters** that the app calls on the path it actually takes, their release values
> asserted from the beacon on device as release 37 -- so `G3.7`'s device arm can be a
> patch that flips a value instead of a patch that executes never.

| field | value |
|---|---|
| status | **NOT BUILT** — no live parameterised target exists today. This order's host checks earn **BUILT**; the release launch on `R1` earns **PROVEN** for the *reachability prerequisite only*. `G3.7`'s own row stays at the **BUILT** it already has (`PARITY.md:341`) until a patch flips `OLD`→`NEW` on device |
| owns | `R6` `selfhost/fixtures/airgap_app`; `R8` `cps-ios` `:18080` (release 37); `R1` iPhone 7 for one launch. Reads `R11` — the mirror must keep serving cell `4df8f9b6` and must **not** be sealed |
| excludes | the Android leg of the canonical fixture (§16 hard rule 2), any other `R8` release-cutting goal, any other `R1` goal (§16 hard rule 1). Touches neither `R3` nor `R7`, so a compiler rung may run beside it |
| blocked by | nothing. Cell `4df8f9b6139b67d2cfe9f6aa8212372cade36278` is minted (`ba4e1c02`), release 36's bytes are preserved, and the `ios-release` Flutter is already warm (measured below) |
| unblocks | `G3.7`'s device gate — the last clause of the architectural question, priced at 33.2 % of structural reach (`PARITY.md:341`). Also every later rung wanting a parameterised live target |
| device needed | **R1 iPhone** — one release launch, no patch |
| mint needed | **no.** This is app source. `supportedRouteBAnalysisVersion = 8` (`route_b_coverage.dart:44`) already matches the cell's `route_b_analyze.aot` |
| est. shape | half a day: ~1 h of fixture + harness edits, one iOS release build, one device launch. Shape, not a promise |

**Provenance.** Authored against the tree at `c0619d13` with every path and command checked by its
author, but **the adversarial verification pass did not run** (session limit) — so citations here are
first-draft rather than double-checked. Re-verify a claim before you act on it, and fix it in place
when it is wrong. `PARITY.md:NNNN` anchors move whenever that file is edited: if one looks wrong,
re-locate by grepping the quoted heading. Schema and house rules: [`README.md`](README.md).

## Why this is the piece it is

It is the whole of block 2 of `c0619d13` and nothing else: a fixture shape plus the one
release that carries it. It deliberately does **not** cut a patch, does not touch the
producer or analyzer (`R7`), does not mint (`R3`), and does not claim anything for `G3.7`
— the parameter ABI is already host-proven 4/4 by `probes/g37_param_abi.sh` and its
precommitted table lives there (`g37_param_abi.sh:26-43`); what is missing is a place on
the device where that proof can be *observed*. Splitting it out keeps the fixture change
reviewable on its own and keeps one release's identity attributable to one change.

## Preconditions -- check these before claiming anything

1. **§17 claims table.** `sed -n '2846,2870p' selfhost/PARITY.md` — expect `R1`, `R6`, `R8`
   all **free**. Note the rows are *stale*: they read "released 2026-08-12" and describe
   release `23.0.0+1`, though releases 33-36 were cut on 08-13. Treat them as free but
   re-verify state from artifacts, not from the table; claim `R1`/`R6`/`R8` in the **same
   commit** as step 1's edits.
2. **Tree health.** `git status --short` → clean, and `git worktree list` → four entries
   (main plus three detached study trees). Stage explicit paths only.
3. **The fixture is in its RELEASE state, not a patch state.** `git diff --quiet HEAD --
   selfhost/fixtures/airgap_app/lib/main.dart && echo RELEASE-STATE` must print. The `R6`
   claims row records a release once cut with `main.dart` left at `value() => _secret`.
4. **THE CLI UNDER TEST MUST BE THE CLI YOU CHANGED** (`c0619d13` promoted precondition d;
   release 34 was DISCARDED for it). `git -C ~/.shorebird rev-parse --short HEAD` →
   `ba4e1c02`, `git -C ~/.shorebird branch --show-current` → `selfhost-under-test`, and
   `git log --oneline ba4e1c02..HEAD -- packages/shorebird_cli` → **empty**. H1 commits
   nothing under `packages/`, so this stays true; `cli_revision_check`
   (`airgap_acceptance.sh:114-141`) will print "revisions differ, but no shorebird_cli
   commits between them" and pass.
5. **Verify the CONSUMED bytes, never a stamp** (precondition a). Already GREEN, measured:
   `cat ~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/internal/engine.version`
   → `4df8f9b6139b67d2cfe9f6aa8212372cade36278`.
6. **Warm the cache before the release that matters** (precondition c; release 33 was
   DISCARDED for it). `isRouteBEngine` reads exactly this path
   (`ios_releaser.dart:236-248`) and returns `false` when it does not exist
   (`route_b.dart:29-33`):
   ```bash
   FL=~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98
   P=$FL/bin/cache/artifacts/engine/ios-release/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter
   ls -l "$P" && LC_ALL=C grep -ac InterpretCall "$P"
   ```
   Measured now: **19,071,568 bytes**, `InterpretCall` present (2 hits) — the exact size
   `ba4e1c02` minted. Do **not** clear the cache; if you do, cut a throwaway release first.
7. **Mirror reload / cache clearing** (precondition b) is **not** needed: no new cell. Leave
   `R11` unsealed and serving `4df8f9b6`; sealing is host-global (§16 hard rule 5).
8. **Release 36's dSYM exists only in an ignored, overwritable place.** Measured:
   `build/ios/archive/Runner.xcarchive/dSYMs/App.framework.dSYM` is 1.5 M and its UUID
   `45DBBCE4-1AE3-31D2-819D-9F97FFEBFEED` equals `evidence/releases/36/LC_UUID`
   (`45dbbce41ae331d2819d9f97ffebfeed`), so the archive is still release 36's. But
   `preserve_release_evidence.sh` writes only `App`, `LC_UUID`, `RECORDED` (see its header,
   `:29-32`) — there is **no dSYM under `selfhost/evidence/`**, and `build/` is gitignored.
   `c0619d13`'s "preserved with its dSYM" is true of the build tree only. Step 2 fixes this.

## Steps

1. **Read the fixture and confirm the finding at the cited lines** before editing
   `selfhost/fixtures/airgap_app/lib/main.dart`:
   - `:123-125` the only parameterised method:
     `String tagged(String x) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-$x' : 'X';`
   - `:176-179` the committed **release** body, whose live branch is a constant and whose
     dead branch is the only caller of `tagged`:
     ```dart
     String value() => DateTime.now().millisecondsSinceEpoch >= 0
         ? 'OLD-rel'
         : '${helper()}${tagged('ARG')}$label';
     ```
   - `:164-170` **why the dead branch exists**: it *names* `helper` and `tagged` so they
     survive the kernel prepass the dynamic interface is generated from; a method nothing
     calls is tree-shaken before the interface can name it, and a patch calling it would
     bind to nothing (rung D found that the hard way). The `DateTime.now()` guard keeps
     both branches alive because it is opaque to the type-flow analysis.
   - So `tagged` is doubly unusable as `G3.7`'s target: the branch never runs **and** its
     release value already reads `NEW-$x`, so an `OLD`→`NEW` flip is not even expressible.
   **The dead branch must not be deleted.** Retention is load-bearing for the release's
   dynamic interface, and `helper`/`label` have no other naming site.
2. **[MUTATES the evidence contract]** Preserve release 36's dSYM, and make preservation
   permanent. Edit `selfhost/engine/route_b/probes/preserve_release_evidence.sh`: when
   `$TARGET` is an `.xcarchive` (the branch at `:44-47`), also
   `cp -R "$TARGET/dSYMs/App.framework.dSYM" "$OUT/"` and name it in `RECORDED`. Then
   back-fill 36 by hand. **How you know:** `nm -n
   selfhost/evidence/releases/36/App.framework.dSYM/Contents/Resources/DWARF/App | grep
   'RouteBThing.tagged'` prints. Without a dSYM there is no `--symbol` locator for a named
   target on a shipped `App` (`assert_result_consumed.sh:74-84`), and `--fixture-signature`
   only ever finds `routeBValue()`'s site.
3. **Add the target, additively, in `lib/main.dart`.** A new **public, FIELDLESS** class
   plus one straight-line top-level caller per arity, mirroring `routeBValue()` at
   `:182-184`:
   ```dart
   /// G3.7's device target: a parameterised instance method on the LIVE path.
   ///
   /// FIELDLESS ON PURPOSE. `assert_result_consumed.sh --fixture-signature` locates
   /// `routeBValue()`'s site structurally, by three field-initialiser stores at
   /// +0x7/+0xf/+0x17 on one base register with that register pushed as the receiver
   /// (probes/assert_result_consumed.sh:465-491). A second three-field class allocated
   /// before a receiver call would make that locator match TWO sites and report
   /// AMBIGUOUS — which is gate 3 of ios_code_patch, so it would break the harness.
   /// Public on purpose: privacy is G3.6's goal and mixing them would let one pass be
   /// credited to the other.
   class RouteBParams {
     @pragma('vm:never-inline')
     String one(String x) =>
         DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-$x' : 'X';

     @pragma('vm:never-inline')
     String two(String a, int b) =>
         DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-$a-$b' : 'X';
   }

   /// ONE call site each, in tail position, with NO branch between entry and the call —
   /// that absence is what makes reachability decidable from the bytes.
   @pragma('vm:never-inline')
   @pragma('vm:entry-point')
   String routeBParamOne() => RouteBParams().one('ARG');

   @pragma('vm:never-inline')
   @pragma('vm:entry-point')
   String routeBParamTwo() => RouteBParams().two('a', 7);
   ```
   Release values `OLD-ARG` / `OLD-a-7`; the patch forms are `'NEW-$x'` / `'NEW-$a-$b'`,
   the same shapes `g37_param_abi.sh` proved host-side. **Do not add a field to
   `RouteBThing`** (`:77`, `:83`, `:104` are exactly the three the locator keys on) and
   **do not edit `value()`'s body text** — `airgap_acceptance.sh:508-517` matches it
   literally and exits *"refusing to guess at a patch edit"* on any difference.
4. **Put them on the path the app takes, with a catch.** In `_routeBRead`
   (`main.dart:281-294`), after `v` and `pc` are captured:
   ```dart
   var p1 = 'ERR', p2 = 'ERR';
   try { p1 = routeBParamOne(); p2 = routeBParamTwo(); }
   on Object catch (e) { p1 = 'ERR: $e'; p2 = 'ERR: $e'; }
   ```
   and set two new `_ProbeBodyState` fields (`_rbParamOne`, `_rbParamTwo`, both initialised
   `'—'`) in the same `setState`. The `try` introduces no conditional branch before the
   calls. The catch is deliberate: under a later `G3.7` patch an ABI mismatch can *throw*,
   and without it the app would die before `_beacon` runs, making "no beacon" ambiguous
   with "the device never launched".
5. **Beacon it, as two params.** In `_beacon` (`:316-345`) add
   `'param_one': _rbParamOne, 'param_two': _rbParamTwo` to `queryParameters` (`:322-336`),
   and extend the header comment at `:3-11`, which enumerates the facts the beacon carries.
   **Two params, not one joined value:** `read_beacon` (`airgap_acceptance.sh:282-288`)
   decodes only `%20` and `+`, so a `|` separator would arrive as `%7C` and every
   assertion string would carry the encoding.
6. **Keep the screen at seven rows.** In `build()` (`:362-380`) replace
   `_row('route B note', _rbNote)` with `_row('param', '$_rbParamOne $_rbParamTwo')`. The
   comment at `:347-349` says the seventh row already has to fit an iPhone 7's 1334 px
   without a RenderFlex overflow stripe, and an overflowing screenshot is an unreadable
   result rather than a failed one. `route B note` is the only row no harness asserts
   (`assert_beacon`/`assert_beacon_code` read `asset`, `assets_patch`, `route_b`,
   `private_class`, `code_patch`, `release`), so it is the one to spend.
7. **Assert the new fact in the harness, and guard the shape.** In `ios_release_patch`
   (`airgap_acceptance.sh:590-592`), beside `assert_beacon release BAKED-INTO-RELEASE
   none`, add a check that the release beacon carries `param_one=OLD-ARG` and
   `param_two=OLD-a-7`. Add a literal-match guard for `routeBParamOne`'s release body in
   the same style as `:508-517`, so a future edit cannot quietly return the target to a
   dead branch. **This is the check that closes the gap `assert_result_consumed.sh` cannot
   see** — see "what would establish reachability" below.
8. **[MUTATES R6 version — the control plane rejects a duplicate]** Bump
   `selfhost/fixtures/airgap_app/pubspec.yaml` `version: 36.0.0+1` → `37.0.0+1`. That line
   is what `app_release_version()` reads to derive `--release-version`
   (`airgap_acceptance.sh:244-246`, and the file's own comment at `:2-5`). Do **not** add a
   `dev_dependencies:` entry (e.g. `flutter_test`) for a host unit test: `pubspec.lock` is
   tracked and the sealed run does an offline `pub get`, so a lockfile change is a real risk
   for a test that per the status vocabulary would earn nothing anyway.
9. **[MUTATES R6 shorebird.yaml, R8 state]** Cut release 37.
   ```bash
   selfhost/scripts/prepare_airgap_fixture.sh --activate ios
   cd selfhost/fixtures/airgap_app && printf '%s\n' '{"origin": "BAKED-INTO-RELEASE"}' > assets/probe.json
   ~/.shorebird/bin/shorebird release ios --no-confirm --verbose \
     --export-method development \
     --flutter-version=c15ef6379403a0a55531a058bdb2c8e55bc05c98
   ```
   (the flags `airgap_acceptance.sh:571-573` uses; default `--dd-max-bytes` on purpose).
   **How you know:** `build/ios/shorebird/route_b.json` reads
   `engineRevision: 4df8f9b6139b67d2cfe9f6aa8212372cade36278`, `patchableCallSitesPerMiB`
   ≈ 1,775 (release 36 measured 7,144 / 1,775.4), `obfuscate: false`, and a
   `buildConfig.fingerprint` present. Release 36's for comparison: `494a8de866b142b6`.
10. **Preserve and gate on the host, before the phone.**
    ```bash
    ARCH=selfhost/fixtures/airgap_app/build/ios/archive/Runner.xcarchive
    selfhost/engine/route_b/probes/preserve_release_evidence.sh 37 "$ARCH"
    D=selfhost/evidence/releases/37/App.framework.dSYM/Contents/Resources/DWARF/App
    nm -n "$D" | grep -E 'RouteBParams\.(one|two)|routeBParam'
    P=selfhost/engine/route_b/probes/assert_result_consumed.sh
    $P selfhost/evidence/releases/37/App --symbols "$D" --symbol routeBParamOne
    $P selfhost/evidence/releases/37/App --symbols "$D" --symbol routeBParamTwo
    $P selfhost/evidence/releases/37/App --fixture-signature
    xcrun llvm-objdump -d --no-show-raw-insn "$D" >/dev/null  # symbols only; disassemble the App
    ```
    Expect exit 0 / one located site / `CONSUMED` for each of the two symbols, and exit 0
    with **exactly one** located site for `--fixture-signature` at a **new** pool offset
    (36's was `0xd4a0`; every release moves it). Then add the row to the corpus list at
    `assert_result_consumed.sh:203-208` with the re-derived offset and run `$P --corpus`.
11. **What check WOULD establish reachability?** Answer it explicitly rather than assuming,
    and label each candidate:
    - **`assert_result_consumed.sh` — cannot.** Measured today on release 36:
      `--at 0xc0e34` (a dead-branch instance call inside `RouteBThing.value`, pool offset
      `0xd4e0`) prints `VERDICT : CONSUMED` and
      *"RESULT CONSUMED — a patch's return value can reach the app"*. Correct and
      useless: the branch never runs. `--symbols <dSYM> --symbol 'RouteBThing.value'`
      finds 4 sites, all CONSUMED, and returns AMBIGUOUS. The limit is now written into
      the probe itself at `:44-58`, added by `c0619d13`.
    - **`classify_routeb_trace.py` — cannot.** Its deciding field is
      `('fn_uep_post', 'interpret_call_ep')` (`:30`): whether
      `Function::unchecked_entry_point_` moved to `InterpretCall`. Releases 25-30 had that
      transition *and* showed nothing. It answers attachment, never execution.
    - **Structural, host-decidable:** disassemble `routeBParamOne` and confirm there is no
      conditional branch between the function entry and the `blr`. Step 3's straight-line
      shape is what makes this decidable; it establishes the site runs **given the caller
      runs**.
    - **The release's own observable output — decisive, and needs `R1`.** The fields
      initialise to `'—'`, so `param_one=OLD-ARG` can only appear in the beacon if the
      calls actually executed on the shipped bytes. That is the check, and it is free: it
      rides the release launch the acceptance run already performs.
12. **[MUTATES R1]** One launch. Wired only (never a wirelessly-paired device). Install and
    run the release; read `docker logs cps-ios` for the beacon line. Do not cut a patch —
    that is `G3.7`'s order.

## Precommitted outcomes

`G3.7`'s own arm table is **not** restated here; it exists verbatim at
`selfhost/engine/route_b/probes/g37_param_abi.sh:26-43` (`one_param → NEW-ARG`,
`two_params → NEW-a-7`, `named → REFUSED`, `opt → REFUSED`, plus "any arm printing the
release's own `OLD-` value while the CLI reported success is the fold/dispatch class of
failure, not an arity result"). This table covers only H1's own observations.

| # | observation | what it MEANS | kind |
|---|---|---|---|
| H1 | `route_b.json` shows engine `4df8f9b6…`, ~1,775 sites/MiB, `buildConfig` with a fingerprint | release 37 is the release we meant to cut | host |
| H2 | ~8 sites / 2 per MiB | **release 33's failure recurred** — `isRouteBEngine` read a Flutter binary that did not exist. DISCARD 37, do not reuse the number, re-warm, cut 38 | host |
| H3 | `route_b.json` missing `buildConfig`, or analysisVersion refusals | the CLI under test was not the CLI you changed — **release 34's discard, which looks exactly like a `G3.7` failure and is not one** | host |
| H4 | `nm` finds `RouteBParams.one`/`.two` and `routeBParamOne`/`Two` | the methods survived AOT under whole-library retention (`dynamic_interface.yaml`: `callable: - library: 'package:airgap_probe/main.dart'`) | host |
| H5 | a symbol is missing | retention failed; the fixture is **not** fixed. Stop — this is the rung-D class of failure, not a device question | host |
| H6 | `--symbol routeBParamOne` → exit 0, 1 site, `CONSUMED` | necessary, **not sufficient**. Says nothing about execution | host |
| H7 | exit 1 (`DISCARDED`) | the fold recurred: a release body became a compile-time constant. Fix the body, cut again, never book the phone | host |
| H8 | exit 2 with 0 located | measurement incomplete, not a pass (`:59-64`). Usually a dSYM/symbol mismatch | host |
| H9 | `--fixture-signature` locates **2+** sites | the new class reproduced the three-field-store fingerprint → gate 3 of `ios_code_patch` is now AMBIGUOUS. The design regressed the harness; fix the fixture before proceeding | host |
| H10 | no conditional branch between `routeBParamOne`'s entry and its `blr` | the site is reachable **given the caller runs** | host |
| D1 | beacon `param_one=OLD-ARG param_two=OLD-a-7` | **the calls executed on the shipped bytes.** Reachability PROVEN; `G3.7`'s device arm is unblocked. The only observation that closes this order | device |
| D2 | `param_one=—` | the calls never ran; the new target is as dead as `tagged`. A green harness elsewhere must not be read as success | device |
| D3 | `param_one=ERR: <e>` | reachable, and the target throws. Classify the exception before touching `G3.7` | device |
| D4 | no beacon at all | ambiguous between "never launched" and "crashed before `_beacon`". Not a reachability result. Re-run once; if it repeats, the device arm is NOT RUNNABLE and the screenshot is the fallback | device |
| D5 | `route_b=OLD-rel`, `private_class=OLD-pc`, `release=AIRGAP-FIXTURE-V1` all unchanged | the change was genuinely additive. Any movement here means it was not | device |

## Exit criteria

- **BUILT** — H1, H4, H6, H9, H10 pass; the fixture change, the harness assertion, the
  corpus row and release 37's preserved evidence (including its dSYM) are committed.
- **PROVEN** — **only** D1, on `R1`, with release 37's identity asserted from the
  preserved `LC_UUID` (`assert_installed_release.sh <app> --expect <uuid>`, the form
  `RECORDED` prints). The claim earned is exactly: *"the fixture calls a parameterised
  instance method on the live path and its result is observable on device."* Nothing here
  upgrades `G3.7`; per the vocabulary (`PARITY.md:167-177`) that needs the real patch
  workflow flipping `OLD`→`NEW` on hardware.
- **NOT RUNNABLE** (a different label from unrun, per the classification rule) — if the
  `ios-release` Flutter binary is absent and re-warming is not available, or the mirror no
  longer serves `4df8f9b6`: the release cannot be cut, and the row must say which artifact
  is missing rather than reporting a failed gate.

## Evidence to record

- `selfhost/evidence/releases/37/App`, `LC_UUID`, `RECORDED` — written by
  `preserve_release_evidence.sh 37 <xcarchive>`; `RECORDED` carries the patchability
  measurement beside the identity, which is the point of the file (`:74-77`).
- `selfhost/evidence/releases/37/App.framework.dSYM/` (~1.5 M measured) and the same
  back-filled for 36 — the only way a named target can ever be located in shipped bytes.
- `selfhost/engine/route_b/probes/assert_result_consumed.sh:203-208` — new corpus row
  `37 0 0x<re-derived>` with a note naming what it proves. Never carry `0xd4a0` forward.
- The commit message, which is where the identity facts live: cell
  `4df8f9b6139b67d2cfe9f6aa8212372cade36278`, iOS engine donor
  `11e5695710275f829ef1e4a45636d39454ca1769`, Flutter
  `c15ef6379403a0a55531a058bdb2c8e55bc05c98`, release `37.0.0+1`, `route_b.json`
  fingerprint, `LC_UUID`, sites/MiB, R1 = iPhone 7 / iOS 15.8.8 wired, probes run,
  **no patch number** (there is no patch in this order).
- The beacon line copied out of `docker logs cps-ios`, verbatim, as the D1 evidence.
- **Do not cite a screenshot path as evidence.** Verified: `git log --all --diff-filter=A
  -- 'selfhost/evidence/*.png'` returns nothing — no PNG has ever been committed, so
  `PARITY`'s `evidence/arg_*`, `evidence/set_*` and
  `evidence/this_2_call_NEW-ARG.png` name files that are not in the tree. The beacon line
  is the assertable evidence; a screenshot (`build/airgap-release.png`, gitignored) is a
  human aid.

## Commit shape

**Commit A — the fixture and the harness (before the release):**
```bash
git add selfhost/fixtures/airgap_app/lib/main.dart \
        selfhost/fixtures/airgap_app/pubspec.yaml \
        selfhost/scripts/airgap_acceptance.sh \
        selfhost/engine/route_b/probes/preserve_release_evidence.sh \
        selfhost/evidence/releases/36/App.framework.dSYM \
        selfhost/plans/H1-live-parameterised-target.md \
        selfhost/PARITY.md
```
Title: `test(selfhost): a parameterised target on the path the app actually takes`
PARITY edits **in this commit**: §17 claims rows for `R1`/`R6`/`R8` set to held by `H1`
with tree health **GREEN**, `R6` noting "version bumps to 37 with this release"; and the
§3 blocked row at `:340` amended to point at this order rather than left as a bare block.

**Commit B — the release and its evidence (after the device launch):**
```bash
git add selfhost/evidence/releases/37 \
        selfhost/engine/route_b/probes/assert_result_consumed.sh \
        selfhost/PARITY.md
```
Title: `test(selfhost): release 37 shows a parameterised target executing on device`
PARITY edits **in this commit**: the §3 row records the prerequisite as met with the
beacon values and release identity; `G3.7`'s row at `:341` gains "device arm unblocked by
release 37" and **keeps its BUILT status**; the §17 rows for `R1`/`R6`/`R8` are **cleared**
with the state each was left in (installed release, fixture version, published release).

Never `git add -A`, never `commit -a`, no stash/checkout/branch-switch — three other
worktrees share this tree.

## Do not

- **Do not delete the dead branch** of `value()` (`:176-179`). It is the only naming site
  for `helper` and `label`, and the interface is generated from a kernel prepass
  (`:164-170`).
- **Do not touch `value()`'s body text.** `airgap_acceptance.sh:510-513` matches it
  literally and refuses to guess.
- **Do not make `tagged` the target.** Its release value is already `NEW-$x` (`:124-125`),
  so an `OLD`→`NEW` flip cannot be expressed.
- **Do not add a field to `RouteBThing`, or a three-field class allocated before a receiver
  call.** `has_field_init_signature` requires exactly `[0x7, 0xf, 0x17]` on one base with
  the receiver pushed (`assert_result_consumed.sh:485-491`); every clause is load-bearing
  because an over-matching locator "manufactures exactly the finding under test".
- **Do not read CONSUMED as reachability.** Measured: the dead site reports CONSUMED.
- **Do not write cache stamps to establish an engine**, do not clear the cache before the
  release that matters, and do not reuse a discarded release number — the three ways
  releases 33/34 were lost, each failing in the direction that looks like success.
- **Do not add a `dev_dependency` to the fixture.** `pubspec.lock` is tracked and the
  sealed run pub-gets offline.
- **Do not claim anything for `G3.7`.** No patch is cut here.

## Open questions

1. Should `two(String a, int b)`'s `int` be non-constant (e.g. derived from
   `DateTime.now()`)? A constant argument is what makes `OLD-a-7` assertable, but the
   fixture's own comment (`:118-122`) warns that `--aot` eliminates a parameter only ever
   passed a constant, and only the retained dynamic interface prevents it. Tradeoff:
   assertable string vs. a parameter that provably cannot be eliminated. Recommendation:
   keep the constant and treat an `ARG`-shaped device failure as *possible parameter
   elimination* before attributing it to the ABI.
2. Should every release's dSYM be preserved forever (~1.5 M each; `selfhost/evidence` is
   43 M today) or only for releases with an open device gate? Recommendation: preserve
   always — the alternative is re-cutting a release to recover a symbol table.
3. **Canonical `R6` or a clone? Position: change the canonical fixture, additively.**
   `airgap_acceptance.sh:75` defaults `APP_DIR` to `selfhost/fixtures/airgap_app`, and the
   whole six-gate code-patch chain (preserve → patchability → consumption → patch →
   installed identity → beacon) exists only for that app; a clone needs its own `app_id`,
   its own control-plane app, its own version counter, and would force every future
   release's identity to record *which* fixture it came from. §16 already names the clone
   as the parallelism unlock worth engineering, but that is a bigger piece than H1 and it
   is not on `G3.7`'s critical path. The cost of this position, accepted knowingly: release
   37's pool offsets shift for everyone (re-derive, never reuse `0xd4a0`), and every future
   device gate inherits two extra live calls in the beacon path — which is why step 4 wraps
   them in a catch, so a throwing target degrades to an observable `ERR:` instead of
   killing the `route_b` assertion.
4. Should `g37_param_abi.sh`'s `named`/`opt` **refusal** arms get device counterparts? They
   are refusals at patch time and the source determines them, so by the classification rule
   they are a KNOWN GAP, not an unvalidated question. Recommendation: do not queue `R1` time.
