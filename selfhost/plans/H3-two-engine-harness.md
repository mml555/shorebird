# H3 (`G15.1`) — the two-engine harness, and running 0007's tests (unblocks `G15`)

> At the end, something in this repo creates **two independently constructed `FlutterEngine`s in one process**, and patch `0007`'s three arming tests **run** instead of merely compiling — so `G15`'s device row stops being NOT RUNNABLE and becomes a bookable release cut.

| field | value |
|---|---|
| status | **NOT BUILT** — no host in this repo creates two engines, and `0007`'s tests have never executed (there is no linked `out/host_release_arm64/shorebird_unittests` binary, only a `.o`). Per the Status vocabulary (`selfhost/PARITY.md:169-178`) a compile earns nothing; §14b's own words are "a corrected diagnosis plus a compile-verified fix — not a closed gate" (`:2635`) |
| owns | `R3` `/Volumes/build/route-b` (**WRITE**, `BUILD.gn` + a host link/run), `R5` the build SSD (one host link, minutes) |
| excludes | any other `R3` build or a cell mint (§16 hard rule 4, `PARITY.md:2744-2746`; rules block `:2737-2748`). It does **not** exclude the `G3.7` / `G4.2` / `G4.3` device lane: those consume the published cell over the CDN and need `R1`/`R6`/`R8`, none of which this order touches |
| blocked by | nothing technical. **But another worker is mid-run right now** — see precondition 1. Coordination, not code, is the gate on starting |
| unblocks | `G15`'s second-engine device row (`PARITY.md:3113`, `:3121-3125`); `G9.2`'s "Embedded engine activation" row (`:2327`) is decided by the same harness |
| device needed | **none** (a simulator, which is not `R1`) |
| mint needed | **no — and the device gate no longer needs one either.** The mint landed: cell `4df8f9b6139b67d2cfe9f6aa8212372cade36278`, iOS engine donor `11e5695710275f829ef1e4a45636d39454ca1769` carrying `0007` (`PARITY.md:3127-3143`, engine row `:3090`), mapped at `selfhost/cdn/experimental_hashes.map:215` and present at `selfhost/cdn/overlay/download.shorebird.dev/shorebird/4df8f9b6139b67d2cfe9f6aa8212372cade36278/`. Queue item 4's "device gate needs a mint" (`:3069`, item `:3064-3072`) predates that and should be corrected |
| est. shape | a day of host work, two independent halves that can land separately; no hardware, no mint, no CDN change |

**Provenance.** Grounded against the tree and then adversarially verified — a second pass
re-read every cited path, line anchor and command. That verification ran at `ba4e1c02`, **before**
`c0619d13` landed, so this file has not been re-checked against the four prerequisite blocks that
commit recorded. `PARITY.md:NNNN` anchors move whenever that file is edited: if one looks wrong,
re-locate by grepping the quoted heading. Schema and house rules: [`README.md`](README.md).

## Why this is the piece it is

`G15` is **two mechanisms**, and only one of them has a fix in flight. This order is the *severe* half — second-engine arming — and within that half it is the **precondition**, not the verdict: `PARITY.md:3121-3125` says the device row is NOT RUNNABLE because the airgap fixture creates one engine, "the same distinction that reclassified the sealed code-patch row from NOT VALIDATED to NOT BUILT" (`:2506-2510`). Building the missing host is host work; running it is a later, cheap release cut.

It deliberately does **not** include: the device gate itself (needs `R1`, `R6`-clone, `R8`); any change to `shorebird.cc`'s ordering (already applied, see step 2); and the sibling launch-outcome mechanism below, which is untouched by `0007` and is a **KNOWN GAP** decided by source, not a question to queue a device for.

### The decomposition, with a status line each

| id | piece | mechanism | status | who owns the gate |
|---|---|---|---|---|
| **G15.1** *(this order)* | second-engine **arming** | arming sat below `if (!init_result) return;`, and `set_config()` refuses a second `shorebird_init` by design | **NOT BUILT** — harness absent, tests unrun; the source change itself is applied and compile-verified | host only, here |
| **G15.1-d** | second-engine **device verdict** | same | **NOT RUNNABLE** until G15.1 lands (`PARITY.md:3121-3125`) | `R1` + `R6`-clone + `R8`, release against `4df8f9b6` |
| **G15.2** | launch-outcome window: crash-backout (§5) + restart-required (§8) | `ReportLaunchSuccess` fires in the **`Shell` constructor** (`vendor/flutter/engine/src/flutter/shell/common/shell.cc:537`, whose own comment at `:530-532` says "at most once per process — only the first Shell's outcome is reported"), guarded in `vendor/flutter/engine/src/flutter/shell/common/shorebird/updater.h:96-101` + `updater.cc:59-67` — before any root isolate, therefore before any patch can fail | **KNOWN GAP** (`PARITY.md:2127`) — determined by source, so per the classification rule (`:3268-3284`, +24 once the pending edit lands) it is not an unvalidated question and must not be queued as a device gate | design work, not a run |

*(`G15.1`/`G15.2` numbering is introduced by this plan, following the `G3.6a-e` precedent; `PARITY.md` currently has one `G15` row.)*

**All `PARITY.md` line anchors in this file are as of `ba4e1c02`.** A pending staged edit inserts 24 lines after `:3158`, so every anchor past that point shifts by +24 once it lands — re-locate by grep (`Rule for updating this file`, `### The classification rule`, `Off-queue and nearly free`) rather than trusting the number.

## Preconditions — check these before claiming anything

1. `git -C /Users/mendell/shorebird status --porcelain` and `git log --oneline -3` → HEAD is `ba4e1c02` or later. **The tree is NOT clean as of this writing, and that is load-bearing:** `M  selfhost/PARITY.md`, `M  selfhost/engine/route_b/mint_route_b_cell.sh` (both **staged** by another worker) and `MM selfhost/fixtures/airgap_app/pubspec.yaml` (bumped to `34.0.0+1`). Per §17's tell (`PARITY.md:2818-2823`) a fixture version bump beside a fresh `experimental_hashes.map` line means a device gate is running **right now** — so `R6`, `R1`, `R8` are in use, and none of them are yours. `R3` is not implicated by those paths (the `mint_route_b_cell.sh` change is script text, not a build), but say out loud that you are taking `R3` before you build. §17 rule 5 (`:2813-2814`): read before acting.
2. `git worktree list` → **four** entries today: `/Users/mendell/shorebird` (this branch) plus three detached `shorebird-compat-study{,2,3}` trees. `PARITY.md:2793-2795` still says "exactly one entry" — stale; the load-bearing fact is that only one worktree holds this **branch**, so the shared-tree rules apply in full. Engine code work happens in `R3` (outside this repo entirely); `selfhost/PARITY.md` is docs and may be edited here.
3. `sed -n '2843,2914p' selfhost/PARITY.md` → §17 claims table (`:2848-2860`) plus the write-claim tree-health rules (`:2876-2904`) and the GREEN / RED-mid-edit definitions (`:2893-2896`). `R3` must read **free**. The table is stale about *state*: `R11` says "serving `ee001fd7`" (`:2859`) though `ba4e1c02` minted `4df8f9b6`, and `R6` says "version `23.0.0+1`" (`:2854`) though the fixture's `pubspec.yaml` now reads `34.0.0+1`. Ownership is what you must respect; state you must re-check.
4. Tree health of `R3` before you touch it:
   ```bash
   git -C /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart status --porcelain | head
   selfhost/engine/dart_patches.sh \
     --dest /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart --verify
   ls /Volumes/build/route-b/flutter/engine/src/out
   ```
   `--dest` is **required** — the script dies without it (`dart_patches.sh:60`, usage at `:14`). Expect **4 applied** (the series is four patches, `:38-43`) and `host_release_arm64  ios_release`.
5. `grep -n "InstallRouteBActivationHook\|if (!init_result)" /Volumes/build/route-b/flutter/engine/src/flutter/shell/common/shorebird/shorebird.cc` → expect `666:  InstallRouteBActivationHook(settings, route_b_path);` immediately above `668:  if (!init_result) {`. If that inverts, `0007` is not applied and step 2 is real work.
6. `grep -n 4df8f9b6 selfhost/cdn/experimental_hashes.map` → line `215` maps the G15 cell. `ls selfhost/cdn/overlay/download.shorebird.dev/shorebird/4df8f9b6139b67d2cfe9f6aa8212372cade36278 | head` → artifacts on disk.
7. `test -d selfhost/fixtures/airgap_app/ios && git check-ignore -v selfhost/fixtures/airgap_app/ios/Runner/AppDelegate.swift` → prints `.gitignore:37:selfhost/fixtures/airgap_app/ios/`. That is the whole reason step 5 exists.
8. `flutter --version` → must report the **stock** engine (today: `/opt/homebrew/bin/flutter`, Flutter 3.44.8, engine revision `0cd610717b…`), never a Route B experimental hash. The mint workflow restamps Flutter checkouts, so a restamped one would silently turn step 7 into an our-engine run and void its structural-only claim. `xcrun simctl list devices available | grep -i iphone` → note the udid you will use (an iPhone 17 Pro is booted today).

## Steps

1. **Read the seam before changing anything.** `sed -n '640,680p' /Volumes/build/route-b/flutter/engine/src/flutter/shell/common/shorebird/shorebird.cc` and all of `selfhost/engine/route_b/0007-g15-arm-activation-before-init-guard.patch`. The mechanism in one line: `Updater::Init` is `shorebird_init`; `third_party/updater/library/src/config.rs` `set_config()` bails with *"Updater already initialized, ignoring second shorebird_init call"*; so for engine two `init_result` is **false by design**, the old `if (!init_result) return;` fired, and `InstallRouteBActivationHook` was never reached — engine two's root isolate ran original AOT while engine one ran the patch. Check: you can state which line moved and why moving it is safe in both directions without re-reading the patch.

2. **Confirm, do not redo, the source change.** Precondition 5 shows the ordering. Do **not** infer "the tree equals `0007`": `git -C /Volumes/build/route-b/flutter/engine/src/flutter diff --stat -- shell/common/shorebird` is +528/-17 across four modified files (`shorebird.cc` alone 426 lines) plus three untracked, because `0003-4b-lifecycle-delivery.patch` also lives here uncommitted — the documented baseline of that tree (`PARITY.md:2898-2904`). Verify the **ordering** at `:666`/`:668` specifically. If it is right, this step is a no-op and you say so.

3. **[MUTATES `R3`: `shell/common/shorebird/BUILD.gn`]** **Make `0007`'s tests runnable.** The blocker is exact: `shorebird_unittests` (`BUILD.gn:157-179`) compiles `patch_cache_unittests.cc` (`:161`) and deps `//flutter/runtime/shorebird:patch_cache` (`:175`), whose `patch_cache.cc:39` calls `Shorebird_ReadLinkHeader` — a symbol only Shorebird's private Dart fork defines. Two facts make a slim target look viable: `source_set("shorebird")` (`:134-150`) does not depend on patch_cache, and `flutter/runtime/BUILD.gn:123-129` gates that dep on `shorebird_use_interpreter`, declared `= is_ios` at `flutter/common/config.gni:36` and not overridden in `out/host_release_arm64/args.gn` — so false on this host build. So add, **inside the existing `if (enable_unittests) { … }` block (`BUILD.gn:152-180`)** — at top level `:shorebird_fixtures` is an undefined label and gn errors:

   ```gn
   executable("shorebird_arming_unittests") {
     testonly = true
     sources = [ "shorebird_unittests.cc" ]
     deps = [ ":shorebird", ":shorebird_fixtures", ":updater",
              "//flutter/runtime", "//flutter/testing", "//flutter/testing:fixture_test" ]
   }
   ```
   Then:
   ```bash
   cd /Volumes/build/route-b/flutter/engine/src
   export PATH=/Volumes/build/ios-engine/depot_tools:$PATH   # the only ninja on this box
   export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
   export DEPOT_TOOLS_UPDATE=0                              # build_host.sh:26-28
   ./flutter/third_party/gn/gn gen out/host_release_arm64    # args.gn already correct
   ninja -C out/host_release_arm64 -j 8 shorebird_arming_unittests
   ./out/host_release_arm64/shorebird_arming_unittests --gtest_filter='Shorebird.RouteBArming*'
   ```
   No `--check`: it turns unrelated header-dependency errors elsewhere in the tree into a failed generation. If `args.gn` is ever lost, the documented full regeneration for this tree is `./flutter/tools/gn --runtime-mode=release --mac-cpu arm64 --no-prebuilt-dart-sdk --dart-dynamic-modules` (`build_host.sh:41-42`; the two required flags are explained at `:37-40`).

   **Then capture the edit as a patch, or it is lost.** `R3` is recreated from the series, so a BUILD.gn change that exists only in the tree evaporates and takes the committed evidence's meaning with it. `selfhost/engine/route_b/0008-g15-slim-arming-test-target.patch` **does not exist yet — creating it is part of this step.** Note the series' prefixes are inconsistent (`0003` uses `a/engine/src/flutter/…`, `0007` uses `a/shell/common/shorebird/…`): state in the patch header which root you generated from, and verify by **content** rather than by `git apply` exit code — `create_checkout.sh:58` says why.

   **How you know it worked:** three tests named at `shorebird_unittests.cc:27,36,46` report `[  PASSED  ] 3 tests`. Outcomes precommitted below — including the failure that means "not runnable here, move to `R4`".

4. **Decide where the harness lives, and record the reasoning.** It must be a **new fixture clone**, not an edit to `selfhost/fixtures/airgap_app`: (a) `R6` is "the sharpest serializer" (`PARITY.md:2704`) and its `shorebird.yaml`/version/`main.dart` are per-run mutable state (`:2712-2735`); (b) `:2733-2735` notes goals needing a new fixture "do not contend on `R6` at all", which is why `G8`/`G9` are parallel-friendly; (c) giving the fixture per-goal clones is the top off-queue item (`:3245-3246`). Create `selfhost/fixtures/twoengine_app/` committing a deliberate **subset** of what the canonical one commits — `pubspec.yaml`, `pubspec.lock`, `lib/main.dart`, `README.md`, `shorebird.yaml.template` — plus one new thing, `ios_overlay/AppDelegate.swift`. (The canonical fixture also commits `assets/probe.json`, `assets/routeb_patch.bytecode{,.provenance}`, `dynamic_modules/{pubspec.yaml,lib/routeb.dart}` and `lib/frame_bench.dart`; none of those are needed for a structural two-engine claim. Copy the *form* of `airgap_app/README.md`'s "What is committed vs generated" table, not the file list.)

5. **Write the harness host, and know why it cannot be an in-place edit.** `selfhost/fixtures/airgap_app/ios/` is generated by `flutter create` (`prepare_airgap_fixture.sh:70-76`, invocation `:72-73`, `--project-name airgap_probe`) and gitignored (`.gitignore:37`), so an edited `AppDelegate.swift` is deleted by the next materialize. The script's own precedent is **re-injection** — it re-adds two Info.plist keys every time (`:96-104`: `NSLocalNetworkUsageDescription`, a permission key, and `NSAppTransportSecurity:NSAllowsLocalNetworking`). So commit the Swift under `ios_overlay/` and copy it in. Its required shape, from source:
   - **the generated Runner already boots an IMPLICIT engine, and you must dispose of that first.** `ios/Runner/Info.plist:61-62` sets `UIMainStoryboardFile = Main`, `ios/Runner/Base.lproj/Main.storyboard` exists, and the generated `AppDelegate.swift:5` is `FlutterAppDelegate, FlutterImplicitEngineDelegate` with `didInitializeImplicitFlutterEngine` at `:13`. Construct two engines on top of that and you get **three**, or an unattributable mix. So delete `UIMainStoryboardFile` and build the `UIWindow` + root `FlutterViewController` yourself in `application(_:didFinishLaunchingWithOptions:)`. That plist deletion is generated state — it joins the two keys the prepare script re-injects.
   - **two `FlutterEngine`s, each with its own `FlutterDartProject`.** `FlutterEngine.mm:242` — `_dartProject = project ?: [[FlutterDartProject alloc] init];` — and `FlutterDartProject.mm:182` calls `ConfigureShorebird` from inside `FLTDefaultSettingsForBundle` (`:44`), reached via `-init` (`:315`) → `-initWithPrecompiledDartBundle:` (`:321`). One project per engine ⇒ two `ConfigureShorebird` calls ⇒ the second one is the case `0007` fixes. Pass each engine its own project **explicitly** so the probe can assert it.
   - **never `FlutterEngineGroup`, never `spawnWithEntrypoint:`.** `FlutterEngineGroup.mm:81` passes `self.project`; spawned engines take `project:self.dartProject` (`FlutterEngine.mm:1552-1554`); and `FlutterEngine.mm:875` copies `[self.dartProject settings]` into the Shell (`:934`). A shared project hands engine two an **already-armed** `root_isolate_create_callback`, so it runs patched code even without `0007` — a false pass, not a gate.
   - each engine runs a **distinct Dart entrypoint** (`runWithEntrypoint:`) so its output is attributable, and each writes a per-engine marker file into the app container. The second entrypoint needs `@pragma('vm:entry-point')`: without it it survives `flutter run` (debug/JIT) and is tree-shaken in AOT — fatal for the release-mode device gate this harness exists to unblock.
   **How you know it worked:** step 7's simulator run.

6. **Give the clone a prepare path.** `prepare_airgap_fixture.sh:32` hardcodes `FIXTURE=.../airgap_app` and has **no** flag to move it (arg parsing `:47-58`; an unknown flag dies at `:56`). Either add `--fixture <dir>` there or write `selfhost/scripts/prepare_twoengine_fixture.sh` that `flutter create`s the platform dirs, copies `ios_overlay/AppDelegate.swift` over `ios/Runner/AppDelegate.swift`, and re-injects the two Info.plist keys **plus** the `UIMainStoryboardFile` deletion. **Check:** `rm -rf selfhost/fixtures/twoengine_app/ios && <prepare> && grep -c FlutterDartProject selfhost/fixtures/twoengine_app/ios/Runner/AppDelegate.swift && /usr/libexec/PlistBuddy -c "Print :UIMainStoryboardFile" selfhost/fixtures/twoengine_app/ios/Runner/Info.plist` → the overlay survives a regenerate and the storyboard key is gone.

7. **Prove the harness on the simulator — no device, no mint, no our-engine.** `cd selfhost/fixtures/twoengine_app && flutter run -d <simulator-udid>`, against the stock Flutter of precondition 8. The claim under test is only *structural*: two engines, two root isolates, two independent Dart programs in one process. Wired-or-simulator only; never a wirelessly paired device. **How you know it worked:** both engines' markers exist with different content, and each engine's entrypoint logged once. Capture the log verbatim to evidence.

8. **Commit a probe that guards the shape.** `selfhost/engine/route_b/probes/g15_two_engine.sh`, in the style of `probes/g41_define_semantics.sh:38-42` (`pass`/`fail` counters, `check`, non-zero exit): assert the committed `AppDelegate.swift` constructs two engines with two projects, assert it contains neither `FlutterEngineGroup` nor `spawnWithEntrypoint`, assert the second entrypoint carries `@pragma('vm:entry-point')`, assert `ios_overlay/` is not gitignored. Label it in its own header as a **guard against regression of the harness shape**, not evidence that arming works.

9. **Record the report-collision fact, in the probe header and in the fixture README.** `RouteBReport` appends to `artifact_path + ".routeb"` (`selfhost/engine/route_b/instrumentation/flutter-shorebird.fulldiff.patch:116-125`), and both engines resolve the same lifecycle-selected path, so **both engines write the same file** — the trace goes to a sibling path for related reasons (`:127-132`). The real specimen `selfhost/evidence/releases/32/patch2.routeb` is four lines with no engine discriminator. The discriminator to lean on is the sibling trace: `selfhost/evidence/releases/32/patch2.routeb.trace` carries exactly one `rbtrace v=4 … fn=0x101e562a1 …` line, so two attaches in one process should give **two lines**. **Precommitted prediction, not a fact:** their `fn=` values should differ, because each engine has its own isolate and its own heap-allocated `Function` — never measured, so identical `fn=` is a thing to investigate, not automatically a failure. Writing this down now is what stops the later device gate reading "one block" as "engine two unarmed" when it may mean "engine two never booted".

10. **[MUTATES shared docs]** **Correct the three doc facts this order discovered.** In `selfhost/PARITY.md`: queue item 4 (`:3069`) says the G15 device gate "needs a mint" — the mint landed (`:3127-3143`, cell `4df8f9b6`), so what it needs is a **release cut against that cell plus this harness**; §9's prose still asserts arming is "once per process" (`:2333` and `:2337`), the claim §14b retracted at `:2593-2610`; and the precommitted specimen at `:3113` says "both engines' `.routeb` reports" when both engines append to **one** file. Per the file's own rule (`Rule for updating this file`, `:3250+`, and the correction rule `:3286-3307`), record each retraction **where the claim sits** rather than silently rewriting it.

## Precommitted outcomes

Two host experiments here; the device verdict is *not* one of them. Reused verbatim from `PARITY.md:3110-3113`, as the subject the later gate must answer and nothing else:

> | gate | preconditions of its own | specimen | verdict is about |
> |---|---|---|---|
> | `G15` second engine | a host that creates TWO `FlutterEngine`s in one process — the fixture as it stands creates one, so this gate needs its own harness before it can run | both engines' `.routeb` reports | whether engine two is armed at all |

(Its "both engines' `.routeb` reports" is imprecise — step 9 — and that correction belongs beside it.)

**Experiment A — `shorebird_arming_unittests` (step 3). Producer/host finding in every row.**

| observation | meaning |
|---|---|
| links, 3/3 pass | the arming contract is pinned by *executed* tests: inert on empty path, armed for a missing container file, existing callback chained. `0007` moves from compile-verified to host-tested. Still says nothing about two engines |
| links, but `RouteBArmingIsInertWithoutAPatch` fails | a callback is installed with no patch — a regression that would run on nearly every app. Fix before anything else; this is the favourable-looking direction's opposite and the cheapest possible catch |
| links, but `RouteBArmingInstallsACallbackForAPatch` fails | arming silently does nothing when there *is* a patch — the G15 bug itself, reappearing one layer down from the ordering fix. Everything else in this order is moot until it passes |
| links, but `RouteBArmingChainsAnExistingCallback` fails | arming replaces an embedder hook instead of chaining. Real defect, symptom would surface nowhere near Route B (`shorebird.h` doc comment, `:57-71`; chaining contract `:61-62`) |
| fails to link on `Shorebird_ReadLinkHeader` **even without** `patch_cache_unittests.cc` and the patch_cache dep | the symbol arrives through `//flutter/runtime` after all, so the slim-target route is **NOT RUNNABLE in `R3`** and the honest move is `PARITY.md`'s other option: build the tests in the shipping iOS tree (`R4`). Record it and stop; do not start deleting deps to chase a link |
| gn refuses the target (`enable_unittests` false) | contradicted before you run it: the existing target is in the **current** graph (`out/host_release_arm64/obj/flutter/shell/common/shorebird/shorebird_unittests.ninja` exists, `build.ninja` references it) and `shorebird_unittests.shorebird_unittests.o` is dated 2026-08-13 03:31, while **no linked binary** sits at `out/host_release_arm64/shorebird_unittests` — which is the link failure, not a config one. Investigate the gn args before believing it |

**Experiment B — the simulator two-engine boot (step 7). Host finding in every row; none of them is a Route B result.**

| observation | meaning |
|---|---|
| two markers, different content, each entrypoint logged once | the harness is real: two engines, two root isolates, one process. This is exactly the missing precondition and it earns the harness BUILT |
| one marker, or identical content | the second engine did not boot, or both ran the same entrypoint. Harness bug — and the row that matters most, because shipping this shape would make the later device gate's "one `.routeb` block" unattributable |
| three engines, or one entrypoint logged twice | the storyboard's implicit engine is still alive (step 5's first bullet). Not a finding about arming; delete `UIMainStoryboardFile` and build the window yourself |
| both engines boot only when they share a `FlutterDartProject` | you built the false-pass shape (`FlutterEngine.mm:875`, `:1552-1554`). Not a finding about arming; rewrite the host |
| second engine crashes on construction on the simulator | a Flutter/embedder limitation to characterise before booking `R1`. Cheap here, expensive there |
| it works on the simulator | says nothing about arming, which needs our engine, a release and a patch. Do not let a green simulator run be reported against `G15` |

## Exit criteria

- **Earns BUILT:** `shorebird_arming_unittests` runs 3/3 on the host **and** `selfhost/fixtures/twoengine_app` boots two independently constructed engines with two distinct markers on a simulator, with `probes/g15_two_engine.sh` committed and green, and the BUILD.gn edit captured in `0008-…patch`. That is "implementation exists with automated/host tests" — nothing more.
- **Earns PROVEN:** nothing in this order can. `G15`'s second-engine gate is PROVEN only when, on `R1`, a release cut against cell `4df8f9b6` with a Route B patch installed shows **two** `.routeb` arming blocks in the shared report and **two** `rbtrace` attach lines — one per engine. Their `fn=` values are *predicted* to differ; equal `fn=` is investigated, not silently accepted, and not silently called a failure either.
- **NOT RUNNABLE rather than unrun:** if Experiment A's `Shorebird_ReadLinkHeader` row fires, the tests-runnable half is NOT RUNNABLE in `R3` and moves to `R4` — say so in `PARITY.md` instead of leaving it as "unrun". If the second engine cannot be constructed at all on iOS in this Flutter revision, then `G15.1-d` is NOT RUNNABLE for a reason no harness fixes, and that finding is worth more than the gate.

## Evidence to record

| path | must contain |
|---|---|
| `selfhost/engine/route_b/evidence/g15_arming_unittests.txt` | the full gtest output including the `[  PASSED  ] 3 tests` line, the gn/ninja invocation, the out dir, and the four `args.gn` lines that matter (`dart_dynamic_modules = true`, `target_cpu = "arm64"`, `flutter_runtime_mode = "release"`, and the **absence** of `shorebird_use_interpreter` — default `is_ios`, `flutter/common/config.gni:36`) |
| `selfhost/engine/route_b/evidence/g15_two_engine_sim.txt` | the simulator udid and iOS version, `flutter --version` proving a stock engine, the `flutter run` log with both entrypoints, both marker paths and their contents, and the `AppDelegate.swift` sha256 that produced it |
| `selfhost/engine/route_b/evidence/g15_two_engine_sim.png` | the two-engine screen, if the harness renders one |
| `selfhost/engine/route_b/evidence/README.md` | a new per-episode section in the standing form (`:11-17`) indexing the three files above — evidence that is not in that table is evidence nobody finds |
| `selfhost/fixtures/twoengine_app/README.md` | committed-vs-generated table (copying `airgap_app/README.md`'s form), why the AppDelegate is an overlay and not an edit (`.gitignore:37`), why the storyboard key is deleted, and why `FlutterEngineGroup` is forbidden here |

Identity facts to record beside the result, per the *Rule for updating this file*: route-b tree = Flutter revision `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (`out/host_release_arm64/args.gn`); the four modified + three untracked files in `shell/common/shorebird/`; cell `4df8f9b6139b67d2cfe9f6aa8212372cade36278` and engine donor `11e5695710275f829ef1e4a45636d39454ca1769` named as the cell the **later** gate will use (not as evidence for this one); platform = simulator, with model and iOS version; probe name `g15_two_engine.sh`; and the commit sha of the implementation.

## Commit shape

Two commits, so either half can land alone and the other's failure does not swallow it.

**Before staging `selfhost/PARITY.md`, run `git diff --cached selfhost/PARITY.md`.** Another worker has hunks staged there right now (24 lines after `:3158`). Staging over them commits their work inside yours — precisely the `9192a594` accident §17 records at `:2833-2838`. If foreign hunks are staged, coordinate or wait; do not "just include" them.

```bash
# 1 — tests runnable (R3 write claim + verdict in the same commit)
git add selfhost/engine/route_b/0007-g15-arm-activation-before-init-guard.patch \
        selfhost/engine/route_b/0008-g15-slim-arming-test-target.patch \
        selfhost/engine/route_b/evidence/g15_arming_unittests.txt \
        selfhost/engine/route_b/evidence/README.md \
        selfhost/PARITY.md
git commit -m "test(selfhost): G15 — run 0007's arming tests via a slim gn target"

# 2 — the harness
git add selfhost/fixtures/twoengine_app/pubspec.yaml \
        selfhost/fixtures/twoengine_app/pubspec.lock \
        selfhost/fixtures/twoengine_app/lib/main.dart \
        selfhost/fixtures/twoengine_app/shorebird.yaml.template \
        selfhost/fixtures/twoengine_app/ios_overlay/AppDelegate.swift \
        selfhost/fixtures/twoengine_app/README.md \
        selfhost/scripts/prepare_twoengine_fixture.sh \
        selfhost/engine/route_b/probes/g15_two_engine.sh \
        selfhost/engine/route_b/evidence/g15_two_engine_sim.txt \
        selfhost/engine/route_b/evidence/g15_two_engine_sim.png \
        selfhost/engine/route_b/evidence/README.md \
        .gitignore \
        selfhost/PARITY.md
git commit -m "feat(selfhost): G15.1 — a host that creates two engines in one process"
```

`.gitignore` must gain `selfhost/fixtures/twoengine_app/{ios,android,.dart_tool,build}/` and `.../shorebird.yaml`, mirroring `.gitignore:37-40,44` — hence its presence in commit 2's list.

Explicit paths only: never `git add -A`, never `commit -a`, never stash/restore/checkout/branch-switch (§17 rules 1-2, `PARITY.md:2799-2805`). On §17 rule 3 (`:2806-2808`): code under `selfhost/engine/route_b/` is meant to live in its own worktree, but git cannot check this branch out twice and the three existing worktrees are detached HEADs — so the engine edit happens in `R3`, outside this repo, and every repo-side path above is **new**, with no collision surface. Say that rather than claiming the rule was satisfied.

`PARITY.md` edits that must land **in the same commit** as the work:
- §17 claims table (`:2848-2860`): claim `R3` **with tree health** — GREEN or RED/mid-edit per the definitions at `:2893-2896`, stated while true — and clear the row when you stop, even mid-goal, saying what state the tree is in.
- §14b (`:2568+`): a `G15.1` status line reading NOT BUILT → BUILT with what earned it, and the correction that the mint landed so the device row needs a **release cut against `4df8f9b6`**, not a mint.
- Queue item 4 (`:3064-3072`, the mint claim at `:3069`) and the NOT RUNNABLE note (`:3121-3125`): re-aim from "needs a harness that does not exist yet" to "harness exists at `selfhost/fixtures/twoengine_app`; the device row is now unrun rather than NOT RUNNABLE."
- The precommitted specimen (`:3113`): both engines write **one** shared `.routeb`; the per-engine discriminator is the `rbtrace` line count.
- §9 iOS (`:2318-2340`): record the retraction of the "once per process" prose beside it, at `:2333` and `:2337`.

## Do not

- **Do not edit `selfhost/fixtures/airgap_app`.** It is `R6`, the sharpest serializer (`:2704`), and its `pubspec.yaml` is bumped-but-uncommitted right now at `34.0.0+1` — somebody is mid-release in it. §17's `R6` row also warns `lib/main.dart` is left in a patch state, and the row is stale about the version, so trust the tree over the table.
- **Do not build the harness on `FlutterEngineGroup` or `spawnWithEntrypoint:`.** Shared `FlutterDartProject` ⇒ shared armed `Settings` ⇒ passes with or without `0007`. This is the specific false green this goal can produce.
- **Do not leave the storyboard's implicit engine in place.** `Info.plist:61-62` + `AppDelegate.swift:5,13` mean you would be counting an engine you did not construct.
- **Do not put the AppDelegate in `ios/`.** `.gitignore:37`; `flutter create` will erase it and the loss is silent.
- **Do not report a green simulator run against `G15`.** It proves engine multiplicity, not arming. Route B activation needs our engine, a release, a patch and `R1`.
- **Do not call the compile a pass.** `PARITY.md:2624-2635` already states `shorebird.cc` compiles and the tests do not run; upgrading that to BUILT is exactly the move the status vocabulary forbids.
- **Do not leave the BUILD.gn edit only in `R3`.** Uncaptured tree state is how a re-created checkout silently deletes a landed change and leaves its evidence file lying.
- **Do not `gclient sync` in `R3`**, and re-run `dart_patches.sh --dest … --verify` if anything does (§16 `R3`, `:2701`).
- **Do not book `R1`, and do not mint.** Both are the *next* order's, and one of them turns out not to be needed at all. Someone else is holding `R1`/`R6`/`R8` as of this writing.
- **Do not seal the CDN or touch `R11`.** Host-global; `G13` runs alone (§16 hard rule 5, `:2747-2748`).
- **Do not read "one `.routeb` block" as "engine two unarmed"** without independent proof engine two booted — the two engines share one report file, so absence is ambiguous by construction.

## Open questions

1. **Where does the second engine's UI go?** A hidden/headless second engine is simplest and enough for an arming verdict; two visible `FlutterViewController`s make the divergence *visible* on a screenshot, which is better evidence for `G9.2` later. Tradeoff: screenshot value against harness complexity, and headless engines need `allowHeadlessExecution` (`FlutterEngine.mm:1554` shows spawn propagating it).
2. **Does the harness get its own control-plane app id, or ride `cps-ios`?** Its own app id keeps `R8`'s history clean and matches the `G8`/`G9` pattern; riding the existing one saves a `POST /api/v1/apps` and a `shorebird.yaml` generation. Decide before the device gate, not during it. (Step 7 needs neither — a plain `flutter run` never reaches the control plane.)
3. **Should the second engine run the *same* entrypoint as the first?** Same entrypoint is the mainstream add-to-app shape and the most faithful test; distinct entrypoints are what makes each engine's output attributable, and only distinct ones need the `vm:entry-point` pragma. A per-engine argument passed to one shared entrypoint may get both — worth ten minutes before choosing.
4. **`--fixture` flag on `prepare_airgap_fixture.sh`, or a second script?** The flag pays down `R6` (the top off-queue parallelism item, `:3245-3246`) for every future clone; a second script keeps the acceptance harness's blast radius at zero, which matters more than usual while another worker is mid-release in that fixture. The flag is the better long-term answer and the riskier commit **today**.