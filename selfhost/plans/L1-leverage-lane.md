# L1 — the leverage lane: fixture clones first, sealed run last

> Four orders, in the only order they can be run in. **(a)** makes the acceptance fixture
> cloneable per goal, which is the one item on this page that raises the ceiling for everything
> else; **(c)** and **(d)** then run in parallel against that ceiling; **(b)** seals the CDN and
> therefore runs alone, last, after every other lane has stopped.

**Why (a) is first, and it is not a preference.** [`PARITY.md`](../PARITY.md) §16 ends with
*"That is the honest ceiling: **four**, of which two need no device at all. Raise the ceiling by
fixing `R6` — nothing else on this list buys as much parallelism per hour spent."* The queue's own
off-queue list agrees independently (`:3245-3246`): *"Give the canonical fixture per-goal clones
(`R6`, §16). The single highest parallelism-per-hour item on this page."* Every other order here is
*consumption* of capacity: (c) and (d) each want a device plus a fixture, and (b) wants the whole
machine. (a) is the only one that changes how much capacity exists, and it needs no device, no
mint, and no release. It is also the cheapest of the four, so ordering it anywhere but first pays
its cost without collecting its return.

**Read before starting any order:** §16 (`PARITY.md:2689`) for what collides, §17 (`:2786`) for the
claims table and staging rules, `Status vocabulary` (`:167`), and the three rules in the tail —
classification (`:3268`), correction (`:3286`), precommitment (`:3309`).

**Note on one word used throughout.** `NOT RUNNABLE` is **not** one of §167's status labels. It
describes the *run* — the order did not start, rather than started and failed. A parity row keeps
whatever label it already had. Do not write `NOT RUNNABLE` into a status table.

**Tree state at grounding time (2026-08-13).** `HEAD` is `ba4e1c02` *("mint the batch cell
4df8f9b6, with its identity closed by measurement")* and `git status --porcelain` is **empty**.
Re-read `git log --oneline -5` before acting on anything below.

**§17's claims table is stale on six rows, and every row here says "free".** Verified against the
tree, not inferred:

* `R1` says *"Left with release `23.0.0+1` installed and patch 1 active"* — `selfhost/evidence/releases/`
  holds 24 through 32, and release 32 carries **two** patches.
* `R8` says *"Release 69 (`23.0.0+1`) and patch 1 published"* — same staleness.
* `R6` says *"free at version `23.0.0+1`"* with `main.dart` *"left in its PATCH state"* — the fixture
  is at `32.0.0+1` (`pubspec.yaml:9`) and `value()` is the committed release-form ternary
  (`lib/main.dart:177-179`).
* `R3` and `R11` say cell `ee001fd7` — `experimental_hashes.map:215` carries `4df8f9b6`, minted by
  `ba4e1c02`.
* `R7` says *"Analyzer is **v7**"* — `packages/shorebird_cli/lib/src/route_b_coverage.dart:44` says
  `const supportedRouteBAnalysisVersion = 8`.

Treat the whole table as untrustworthy and re-derive from the tree. Declare your own row anyway;
that is what §17 asks for.

**The queue ahead of this page, which the mint just unblocked.** `PARITY.md:3077` precommits the
next session as **ONE MINT carrying THREE INDEPENDENT GATES** — `G3.7` (patches `0006` +
`analysisVersion 8`), `G15` (patch `0007`, arming above the `!init_result` return), and the
private-CALL arm riding release 32 as patch 2. **That mint has landed** (`ba4e1c02`, cell
`4df8f9b6`), so those three device gates are now runnable and they hold `R1` + `R3` + `R6`
between them. **Order (a) below collides with them** under §16 hard rule 2 — one canonical-fixture
leg at a time. Either those gates run first, or (a) runs while they are stopped. Say which out
loud before claiming anything.

**Control planes, as grounded.** `docker ps` returns `cps-ios`, `shorebird-cdn-cdn-cache-1`,
`shorebird-cdn-artifact-proxy-1`. **`cps-android` is not running.** Orders (a) step 4 and all of
(c) are NOT RUNNABLE until someone starts it.

---
---

# (a) R6-CLONES — per-goal fixture clones

> One acceptance-fixture directory per goal, each with its own `app_id`, its own version counter
> and its own `shorebird.yaml`, so that "who holds the fixture" stops being a scheduling question
> and the iOS and Android legs can run at the same time.

| field | value |
|---|---|
| status | **NOT BUILT** — no clone mechanism exists; `prepare_airgap_fixture.sh:32` hard-codes `FIXTURE="$HERE/../fixtures/airgap_app"` and there is exactly one fixture on disk |
| owns | `R6` canonical fixture (read, plus one `--activate` smoke). Touches `R8`/`R9` for one `POST /api/v1/apps` each — registration is not release-cutting, so it does **not** take those lanes |
| excludes | any goal holding `R6` while this runs (§16 hard rule 2 — one canonical-fixture leg at a time). **Named collision: the three precommitted device gates at `PARITY.md:3077`, now unblocked by `ba4e1c02`, hold `R1` + `R3` + `R6`.** Nothing else: no device, no `R3`, no `R7`, no `R11` |
| blocked by | nothing technical. Scheduling-blocked behind the §3077 gates if they are running |
| unblocks | concurrent iOS + Android legs; order (d)'s Android rows; every future goal that would otherwise queue behind one `shorebird.yaml`. Retires §16's `--activate` race |
| device needed | none |
| mint needed | no |
| est. shape | half a day of host work plus a no-build smoke; no hardware, no release |

**Provenance.** Grounded against the tree and then adversarially verified — a second pass
re-read every cited path, line anchor and command. That verification ran at `ba4e1c02`, **before**
`c0619d13` landed, so this file has not been re-checked against the four prerequisite blocks that
commit recorded. `PARITY.md:NNNN` anchors move whenever that file is edited: if one looks wrong,
re-locate by grepping the quoted heading. Schema and house rules: [`README.md`](README.md).

## Why this is the piece it is

`R6` is one directory carrying three pieces of mutable per-run state (§16:2712): a *generated*
`shorebird.yaml` stamped by `--activate <leg>`, whose own script comment says *"the last invocation
is the one the next leg would silently use"*; the `pubspec.yaml` `version:` line that derives
`--release-version`, which the control plane rejects on duplicate; and `lib/main.dart`, which every
language rung edits. All three are per-directory, so a per-goal directory dissolves all three at
once — the fix is a *namespace*, not a lock.

It deliberately does **not** include: cutting any release from a clone, building any clone on a
device, changing `airgap_acceptance.sh` (its `--app` is already the parameter — `:43`, default at
`:74`), or building the new fixtures that `G4.2`/`G8`/`G9` need. Those goals need a *different*
app, not a clone of this one, and §16 already notes they do not contend on `R6` at all — verified:
the canonical fixture's top-level `flutter:` map has no `module:` key, so it could not be an
add-to-app fixture.

## Preconditions — check these before claiming anything

1. `git log --oneline -5 && git status --porcelain` → expect `ba4e1c02`, clean. Assume the tree
   moves; a mint landed during this grounding.
2. `git worktree list` → prints four entries: `/Users/mendell/shorebird` on
   `feat/engine-improvements` at `ba4e1c02`, plus `shorebird-compat-study`, `-study2`, `-study3` at
   detached HEADs (`aa36f92d`, `8f5d7d4b`, `2da51f65`). **§17's "returns exactly one entry"
   (`PARITY.md:2793-2795`) is stale** — but only one worktree is on the branch, so the shared-tree
   rules still apply unchanged.
3. §17 claims (`PARITY.md:2843`, rows from `:2849`): `sed -n '2843,2872p' selfhost/PARITY.md` → the
   `R6` row must read free. It currently reads *"free at version `23.0.0+1`"* with `main.dart`
   *"left in its PATCH state"* — **both false** (see *Do not*). Six rows are stale; re-derive.
4. The tell (§17:2818-2824): `git status --porcelain selfhost/fixtures/airgap_app/pubspec.yaml
   selfhost/cdn/experimental_hashes.map` → **must be empty.** An uncommitted version bump plus a
   fresh hash line means someone is mid-release; back off `R1`, `R3`, `R6`.
5. Fixture really is in release state: `sed -n '177,179p' selfhost/fixtures/airgap_app/lib/main.dart`
   → the non-foldable `'OLD-rel'` ternary that `ios_code_patch`'s python edit
   (`airgap_acceptance.sh:507-517`) refuses to guess at if it differs. Record its sha256.
6. Control planes up: `docker ps --format '{{.Names}}'` → **as grounded only `cps-ios` is
   running.** Without `cps-android`, step 4 cannot register the Android app and this order is
   NOT RUNNABLE for the Android half. Start it, or scope the smoke to iOS and say so.

## Steps

1. **Write `selfhost/scripts/clone_airgap_fixture.sh` — it does not exist yet.** Input: a goal id.
   It copies exactly the committed source set (`git ls-files selfhost/fixtures/airgap_app` —
   verified **11** files: `README.md`, `assets/probe.json`,
   `assets/routeb_patch.bytecode`, `assets/routeb_patch.bytecode.provenance`,
   `dynamic_modules/lib/routeb.dart`, `dynamic_modules/pubspec.yaml`, `lib/frame_bench.dart`,
   `lib/main.dart`, `pubspec.lock`, `pubspec.yaml`, `shorebird.yaml.template`) to
   `selfhost/fixtures/<goal>_app/`. **The depth is mandatory, not cosmetic:**
   `fixtures/airgap_app/pubspec.yaml:27-28` declares `code_push_runtime: path:
   ../../../packages/code_push_runtime`, which resolves to the repo root only from
   `selfhost/fixtures/<x>/`. A clone one level deeper resolves to `selfhost/` and will not pub-get.
   *Check:* `cd` into the clone and `PUB_CACHE=$(pwd)/../airgap/pub-cache flutter pub get --offline`
   resolves `code_push_runtime`.
2. **Keep `name: airgap_probe` in every clone.** `probes/policy_arms.sh:43` defaults
   `ENTRY=package:airgap_probe/main.dart` and `:44` defaults
   `APP_PREFIX=package:airgap_probe/`. Renaming the package silently changes what every probe
   measures. Give the clone its own **version base** instead (its own hundreds block, e.g.
   `100.0.0+1`) so a log line names the clone unambiguously — the server-side separation is already
   real (`repository.dart:393` `UNIQUE(app_id, version)`), this is only for readability.
   *Check:* `grep -n '^name:\|^version:' <clone>/pubspec.yaml`.
3. **Teach `prepare_airgap_fixture.sh` a `--fixture <dir>` flag.** Three edits, all in that file:
   `FIXTURE=` (`:32`) becomes the flag's default; the `flutter create --project-name airgap_probe
   --org dev.selfhost` line (`:73`) must take a per-clone `--org` so two clones can coexist on one
   phone (today both would be `dev.selfhost.airgapProbe` — the value comes from that `--org`, and
   the generated, gitignored `ios/Runner.xcodeproj/project.pbxproj` confirms it on disk); and the
   "no app_id yet" die text (`:178-186`) must name the clone. `GEN_DIR` (`:116`) and `--activate`
   (`:166-172`) then become per-clone with no further change — **that is the whole race fix**,
   because the hazard is a property of one shared `shorebird.yaml`, not of the copy operation.
4. **Register one control-plane app per clone per leg.** **[MUTATES control-plane state — `cps-ios`
   / `cps-android` app tables]** iOS on `:18080`, Android on `:18081`:
   ```bash
   curl -sS -X POST http://localhost:18080/api/v1/apps \
     -H "Authorization: Bearer $SHOREBIRD_TOKEN" -H 'Content-Type: application/json' \
     -d '{"display_name":"<goal>-fixture"}'
   ```
   `app_id` is server-generated (`_createApp`, `api.dart:1043-1059`, reads only `display_name` and
   `organization_id` and ignores any requested id). Record it in the gitignored
   `selfhost/fixtures/airgap/acceptance.env` as `<GOAL>_IOS_APP_ID=` / `<GOAL>_ANDROID_APP_ID=`,
   never in a committed file. *Check:* the two clones' `.generated/` configs carry different
   `app_id`s.
5. **Leave the pub seed shared.** It is derived from `pubspec.lock`
   (`prepare_airgap_fixture.sh:194-219`), and a clone that keeps the lockfile shares the seed
   correctly. `--seed-out` (`:53`) already exists for a clone whose dependencies differ — that is
   `G9`'s problem, not this order's. *Check:* `fixtures/airgap/SEED.txt`'s `pubspec_lock_sha`
   matches `shasum -a 256 <clone>/pubspec.lock`. (Grounded: the canonical pair is already
   **drifted** — `a66687bc…` in `SEED.txt` vs `205f237f…` on disk. That is §13's known drift and
   this order must not refresh it.)
6. **Everything else is a wrapper, not a script change.** Verify each by reading, not by assuming:
   `airgap_acceptance.sh --app` (`:43`, default at `:74`); `probes/device_handpack.sh:24` and
   `probes/policy_arms.sh:42` both honour `APP=`; `airgap_run.sh:71-79` honours
   `AIRGAP_PUB_CACHE`. The one exception is `prepare_ios_endpoint.sh:172`, which greps
   `^IOS_APP_ID=` out of `acceptance.env` — it needs a `--fixture`/`--app-id-var` argument.
   Its stamp (`:54`, read at `airgap_acceptance.sh:542`) stays global and shared: it records the
   **endpoint URL only**, so every iOS clone agrees on it.
7. **The smoke test, which is the actual claim.** Clone one goal fixture; `sha256` the canonical
   `fixtures/airgap_app/shorebird.yaml`; run `prepare_airgap_fixture.sh --fixture
   selfhost/fixtures/<goal>_app --leg android --app-id <new> --skip-seed` (`--app-id` **requires**
   `--leg`, `:145`) then `--fixture <dir> --activate android --skip-seed`; `sha256` the canonical
   file again. **The canonical hash must be identical and the clone's must be new.** No build, no
   device.
8. **Document it where the constraint is recorded.** §16:2712 gains the clone escape hatch and the
   fourth-state note (the endpoint stamp is endpoint-scoped, so it is shared safely); §16's `R6`
   row (`:2701`) gains *"canonical fixture; clones are per-goal and do not serialize"*; §17's
   claims row is updated in the same commit.

## Precommitted outcomes

Host findings only — no device is involved, so nothing here can earn PROVEN.

| observation | meaning |
|---|---|
| canonical `shorebird.yaml` sha unchanged, clone's written | the mechanism works. `--activate` is no longer global state. **BUILT**, host finding |
| both files written | `--fixture` did not reach `GEN_DIR`/`ACTIVATE`; the clone is stamping the canonical fixture. Worse than failing, because it looks like success |
| clone's `pub get` cannot resolve `code_push_runtime` | the clone is at the wrong depth. Producer/host finding, fix the path not the pubspec |
| clone builds but its probes report canonical-fixture values | `ENTRY`/`APP_PREFIX` defaults leaked (`policy_arms.sh:43-44`). The measurement was of the wrong app |
| a later clone release is refused for a **duplicate version** | the `app_id` was reused, so the clone shares a version namespace (`repository.dart:393` `UNIQUE(app_id, version)`). The clone is cosmetic, not real. **This is the tell — not an artifact conflict:** the server does throw `Artifact already registered for $arch/$platform` (`api.dart:1454`, `:1503`), but the Android/AAR upload path catches `CodePushConflictException` and logs *"artifact already exists, continuing…"* (`code_push_client_wrapper.dart:699-704`). A reused `app_id` will therefore NOT announce itself at artifact upload |
| two clones' iOS builds produce the same bundle id | expected today (`dev.selfhost.airgapProbe`); harmless while `R1` is one-goal-at-a-time, fatal the moment two clones must coexist on the phone. Fix with per-clone `--org` (step 3), do not discover it on a device |

## Exit criteria

* **BUILT** — `clone_airgap_fixture.sh` exists, `prepare_airgap_fixture.sh --fixture` works, and the
  step-7 smoke shows the canonical fixture byte-unchanged while a clone is activated. Host only.
* **PROVEN** — an iOS leg and an Android leg complete their *real* release→patch workflows
  concurrently, each on its own clone, neither touching the other's `shorebird.yaml` or version
  counter. That verdict is earned by the first two consuming goals; **this order may not claim it.**
* **NOT RUNNABLE** rather than unrun if a control plane is down — as grounded, `cps-android` is not
  running, so step 4 cannot mint the Android `app_id`, and a clone without its own `app_id` is not a
  clone. Either start it or scope the smoke to iOS and record which half ran.

## Evidence to record

* `selfhost/fixtures/CLONES.md` (does not exist yet — creating it is part of this order): one row
  per clone — goal id, directory, package name, version base, which control plane, which leg.
  **No `app_id`s** (server-generated, instance-specific — the same reason `shorebird.yaml` is
  gitignored at `.gitignore:44`).
* `selfhost/fixtures/airgap/clone-smoke.txt` (gitignored via `.gitignore:41`): the two `sha256`
  pairs from step 7, the clone directory, timestamp, and the commit the smoke ran at.
* Identity facts: commit sha of the enablement change; `cps-ios`/`cps-android` container ids;
  the canonical fixture's `pubspec.yaml` version at the time (`32.0.0+1` as grounded). No engine
  hash, no release, no patch number — none is involved, and inventing one would misrepresent it.

## Commit shape

```bash
git add selfhost/scripts/clone_airgap_fixture.sh \
        selfhost/scripts/prepare_airgap_fixture.sh \
        selfhost/scripts/prepare_ios_endpoint.sh \
        selfhost/fixtures/CLONES.md \
        .gitignore \
        selfhost/PARITY.md
git commit   # feat(selfhost): R6 — one fixture per goal, so the fixture stops serializing
```

Same commit must carry: §16's `R6` exclusivity row and the §16:2712 subsection; §17's claims row
for `R6` (**cleared** on stop, with tree health stated GREEN vs RED/mid-edit). Never `-A`, never
`commit -a` — another worker's edits may be sitting unstaged.

## Do not

* Do not trust §17's `R6` row. It says version `23.0.0+1` with `main.dart` in its *patch* state
  (`value() => _secret`); the fixture is at `32.0.0+1` (`pubspec.yaml:9`) and `value()` is the
  committed release-form ternary (`lib/main.dart:177-179`). Re-derive from the files.
* Do not rename the clone's Dart package to make it "clearly different" — that breaks every probe
  default silently (step 2).
* Do not commit a clone's `shorebird.yaml`, `.generated/`, `ios/`, `android/` or `build/`. The
  `.gitignore` rules at `:36-52` are **path-literal for `airgap_app`** (`:37-40`, `:44-47`) and will
  **not** cover a new directory; `:41` ignores all of `selfhost/fixtures/airgap/` but that is a
  different path. Extend them in the same commit.
* Do not run `prepare_airgap_fixture.sh` without `--skip-seed` during the smoke: the seed step
  network-resolves (`:194-219`) and would churn `R6`'s shared seed for no result (§13's *"Do not
  refresh the seed today"*).

## Open questions

* **Per-clone `--org`, or one bundle id?** Per-clone lets two clones coexist on `R1` and costs a
  signing identity per clone. Be precise about the constraint that is actually recorded:
  `prepare_ios_endpoint.sh:25-40` says only that **iOS will not launch a development-signed app it
  cannot verify online** — it says nothing about provisioning profiles per bundle id. So the cost of
  a per-clone bundle id is unmeasured, not documented. One bundle id is free and forbids clone
  coexistence on the phone. Recommendation: per-clone `--org` only for clones that will ever be
  iOS, and measure the signing cost on the first one rather than asserting it.
* **Clone the whole tree, or symlink `lib/`?** A symlinked `lib/main.dart` would re-share the third
  piece of mutable state and defeat the point; a full copy means language-rung edits diverge and
  must be reconciled by hand. Recommendation: full copy, and say in `CLONES.md` which clone's
  `main.dart` is authoritative for a given rung.

---
---

# (c) G9.1 — add-to-app on Android, and the gate that reading the code found

> Android add-to-app releases can be *activated* on our control plane at all — which they cannot
> be today — and the release→patch→relaunch→rollback chain runs on `R2` from a Flutter-module
> fixture with a native host.

| field | value |
|---|---|
| status | **KNOWN GAP** for the release row (source-determined, see below), **NOT VALIDATED** for patch / relaunch / rollback downstream of it. §9's Android table (`PARITY.md:2308-2316`) currently lists all four as NOT VALIDATED — that must be corrected first |
| owns | `R10` `code_push_server` source for the gate fix; then `R2` Android device + `R9` `cps-android`; **its own fixture — no `R6`** |
| excludes | `G4.2`(android) and order (d)'s Android rows — all want `R2` and `R9`. Independent of `R1`, `R3`, `R6`, `R7`, `R11` |
| blocked by | nothing. Independent of order (a): a module fixture is a new app, not a clone. **Environment-blocked right now: `cps-android` is not running** |
| unblocks | §15's *"Add-to-app passes on Android"* gate (`PARITY.md:2666`); and the same server fix is a precondition for `G9.2` iOS, which is blocked at the identical seam |
| device needed | `R2` Android |
| mint needed | no |
| est. shape | server fix + tests is a half day with no hardware; the module fixture and the device leg is a separate day |

## Why this is the piece it is

§9 says *"Splits cleanly by platform — `G9.1 android` (AAR) and `G9.2 ios` (xcframework) share no
hardware and no fixture"*, and that iOS is blocked twice over (arch gate, then a second
`FlutterEngine` that never arms — the latter now `G15`'s patch `0007`). So Android first. But
reading the source moves the Android half too: **the release row is a KNOWN GAP, not an
unvalidated question.**

`api.dart:121` — `'android': {'aab'}` inside `_requiredArchs` (`:105`) — is enforced on the
activate path: `present` at `:1277`, `_requiredArchs[platform]?.difference(present)` at `:1278`,
and `throw conflict('Release $releaseId ($platform) is missing artifacts: …')` at `:1281`. An AAR
release uploads per-ABI `libapp.so` (`code_push_client_wrapper.dart:677-694`, `libapp.so` at
`:682`, `arch: arch.arch` at `:694`) and the arch string `'aar'` (`:719`) and never an `aab`.
`_requiredAnyArchs['android']` (`api.dart:131`, checked at `:1287`) is satisfied by the per-ABI
artifacts, so the failure is precisely and only the `aab` requirement. This is the *same* gate §9
already blames for iOS (`PARITY.md:2323`).

This order does **not** include `G9.2` iOS, and does not touch `R6`.

## Preconditions — check these before claiming anything

1. Reproduce the gate before changing it: `cd packages/code_push_server && dart test -x
   integration` green first, then read `sed -n '105,133p' lib/src/api.dart` and
   `sed -n '1267,1295p' lib/src/api.dart` — that range holds the "unknown platforms are
   deliberately unchecked" comment (`:1274-1276`) **and** both gates, which is the pair the fix has
   to respect together.
2. Confirm the CLI side: `grep -n "arch: 'aar'" packages/shorebird_cli/lib/src/code_push_client_wrapper.dart`
   → `:719`. And `grep -n "androidPackageName" packages/shorebird_cli/lib/src/commands/release/aar_releaser.dart`
   → `:67`, `:124`, `:135`, `:180`.
3. Confirm the fixture requirement. **Do not grep for the bare word `module`** — that returns three
   false hits from the `dynamic_modules` path dependency (`pubspec.yaml:15-17`). Scope it to the
   top-level `flutter:` map, which is what the CLI reads:
   ```bash
   awk '/^flutter:/{f=1} f && /^[[:space:]]+module:/{print NR": "$0}' \
     selfhost/fixtures/airgap_app/pubspec.yaml
   ```
   → **prints nothing.** `shorebird_env.dart:255-258` reads `pubspec?.flutter?['module']` then
   `['androidPackage']`, so the canonical fixture cannot do an AAR release. This is §16's
   *happy accident* (`:2733-2736`), verified.
4. §17 claims: `R2`, `R9`, `R10` must read free. Claim `R10` for the server work with tree health;
   claim `R2`+`R9` only when the device leg starts, and clear them when it stops.
5. `docker ps --format '{{.Names}}' | grep cps-android` → **as grounded this returns nothing; the
   container is not running.** Start it, and confirm `adb devices -l` shows the device **wired**
   (memory: never a wirelessly-paired device).

## Steps

1. **Correct §9 before doing any work.** The Android *Release* row (`PARITY.md:2313`) becomes
   **KNOWN GAP** with the `api.dart:121` + `:1278` citation; §9's note that iOS is blocked "twice
   over" gains that the first blocker is shared, not iOS-specific. This is the classification rule
   applied literally: *"Before adding a row to the device queue, check whether reading the code
   closes it."* No device is booked by this step. *Check:* the row cites file:line.
2. **Fix the gate in `packages/code_push_server`** — the required set must depend on what kind of
   release this is, not on the platform string alone. Shape: when a live artifact with arch `aar`
   is present, require `aar` instead of `aab`; leave unknown platforms unchecked (the existing
   comment at `api.dart:1274-1276` already establishes that principle). Do not delete the gate — the
   comment at `:1267-1272` records why it exists: an interrupted upload once published a release no
   patch could be built against. *Check:* new tests in `test/api_test.dart` covering (i) `aab`-only
   still activates, (ii) `aar` + per-ABI activates, (iii) `aar` alone with no code artifact is still
   refused by `_requiredAnyArchs` (`:1287-1293`). `cd packages/code_push_server && dart test -x
   integration`.
3. **Build the module fixture — it does not exist yet.** `flutter create --template module` with a
   `module: androidPackage:` key under the top-level `flutter:` map, plus a minimal native Android
   host that embeds it, plus the beacon/probe shape the canonical fixture uses (`lib/main.dart`'s
   beacon at `:320-330` is the mechanism; screenshots are evidence only). Live under
   `selfhost/fixtures/<name>/` at the same depth for the same relative-path reason as order (a)
   step 1. *Check:* `shorebird release aar` reaches the build, and `androidPackageName` resolves
   (`aar_releaser.dart:67` dies with *"Could not find androidPackage in pubspec.yaml"* otherwise).
4. **Register its app on `cps-android`.** **[MUTATES control-plane state]** Same `curl` as (a)
   step 4 against `:18081`; record in the gitignored `acceptance.env`.
5. **Cut the AAR release.** **[MUTATES `R9` release history]** `shorebird release aar
   --release-version=<explicit>` — note `aar_releaser.dart:74-78` (`assertArgsAreValid`) **requires**
   `--release-version` explicitly, so this goal does not inherit the fixture's version-counter
   contention at all. *Check:* the release activates (that is step 2's verdict, arriving through
   the product path).
6. **Patch, relaunch, rollback on the device.** **[MUTATES device install]** Per-ABI patch artifacts
   are a multi-arch patch (`PLATFORM_MATRIX.md:71`) — all must upload and verify before the patch
   goes ready. *Check:* the host app shows the patched value; relaunch keeps it; withdraw returns
   to the release.

## Precommitted outcomes

| observation | meaning |
|---|---|
| activation refused *"missing artifacts: aab"* before step 2 | the gate is confirmed at the product path. **Server/host finding** — this is the expected pre-fix result and it *closes* the classification, it does not open a question |
| after step 2, activation succeeds and the AAR release is live | the gate was the whole release-row blocker. Server finding; earns **BUILT** for the server half, nothing for the device rows |
| activation succeeds but the patch never goes ready | a *different* seam — multi-arch readiness (`_maybeMarkPatchReady`, `api.dart:1840`, called at `:1759` and `:1829`). Do not report it as the add-to-app gate |
| host app shows the patched value | **device finding.** Android add-to-app patching PROVEN, for this fixture shape only |
| host app shows the patched value on first launch | favourable-looking and **suspect**: the patch may have been compiled into the AAR the host embeds. Re-verify the embedded artifact's identity before believing it, the same way `AIRGAP_EXPECT_UUID` does on iOS (`airgap_acceptance.sh:523-530`) |
| release activates but the *standalone* Android leg then regresses | `G1`'s hold-the-line clause. The server change is shared; a regression there outranks this goal |

## Exit criteria

* **BUILT** — the server gate accepts an add-to-app release set with unit coverage for all three
  cases, and §9's Android release row is reclassified with its citation. No device.
* **PROVEN** — release → patch → relaunch → rollback all observed on `R2` with Flutter embedded in
  a native host, evidence recorded per §15's *"Add-to-app passes on Android"*.
* **NOT RUNNABLE** if the module fixture does not exist — step 3 is the build, and until it lands
  every device row here is unrunnable rather than unrun. Also NOT RUNNABLE while `cps-android` is
  down.

## Evidence to record

* `selfhost/evidence/addtoapp/android/<release>/`: the activate request/response pair (the 409
  before, the 200 after), the artifact list the release registered (`arch`/`platform`), the patch's
  per-ABI artifact list, and device output for baseline / patched / relaunched / withdrawn.
* Identity facts: release version, patch number, platform `android` + arch `aar`, device
  `CPH2551`/Android 16, the `cps-android` container id, the commit carrying the server fix and its
  tests. No engine hash unless a fork engine was used — say which.

## Commit shape

```bash
# server half
git add packages/code_push_server/lib/src/api.dart \
        packages/code_push_server/test/api_test.dart \
        selfhost/PARITY.md selfhost/PLATFORM_MATRIX.md
git commit  # fix(server): add-to-app releases activate on the arch set they actually upload
```
The `PARITY.md` edits in that same commit: §9's Android release row → **KNOWN GAP** with citation,
and §17's `R10` claim row with tree health. Device evidence lands in a second commit that also
carries the `R2`/`R9` claim rows and clears them. Explicit paths only — never `-A`, never
`commit -a`.

## Do not

* Do not whitelist `arch` while you are in there. `PLATFORM_MATRIX.md:159-162` records why: the set
  is open-ended and a whitelist would be more fragile than the hole.
* Do not reuse the canonical fixture — it has no `flutter: module:` key, and adding one would
  convert `R6` into an add-to-app fixture and break every other goal that uses it.
* Do not report `G9.2` iOS as unblocked by this. The second blocker is a second `FlutterEngine`
  that never arms; its **fix already exists** — patch `0007`, carried by the G15 iOS engine
  `11e56957` and by cell `4df8f9b6` (`experimental_hashes.map:202-208`, `:214-215`) — but it is
  **not device-proven**, and that device gate is `G15`'s, not this order's. "Fix written" is not
  "blocker cleared".

## Open questions

* **Does the fix key on the presence of `aar`, or on a release "kind" the CLI declares?** Presence
  is inferable today and needs no wire change; a declared kind is explicit but touches the CLI and
  the protocol package. Recommendation: presence, with the reasoning written at the seam
  (`api.dart:1277-1281`).

---
---

# (d) G5 — the lifecycle remainder, after the classification rule takes its cut

> §5's open rows are reduced to what a device can actually settle: two Android rows on `R2`, one
> server test on `R10`, and two rows honestly retired. Nothing is queued that reading the source
> already closes.

| field | value |
|---|---|
| status | **CORE PROVEN / SAFETY EDGES ARE GAPS, NOT UNKNOWNS** (§5's own summary line, `PARITY.md:2164`). After `G15` takes the crash-backout row, and after the reclassification in step 1, what is left is **PARTIAL** ×2 and one missing **BUILT** test |
| owns | `R10` for the server test; `R2` + `R9` for both device rows; `R6` **or its clone from order (a)** |
| excludes | order (c) and `G4.2`(android) — same `R2`, same `R9`. Excludes nothing on `R1`/`R3`/`R7` |
| blocked by | nothing hard. Order (a) makes it *cheap*: without a clone this order holds `R6` and blocks the iOS lane — including the three precommitted gates at `PARITY.md:3077` |
| unblocks | part of §15's *"Rollback / rejection / failure matrix passes"* (`:2668`). It cannot close that gate alone — `G15` owns two §15 gates that were carved out of it |
| device needed | `R2` Android only. **No `R1`** — that is the point of step 1 |
| mint needed | no |
| est. shape | a morning of reading and doc-correction, a server test, then one Android device session |

## Why this is the piece it is

§5's 2026-08-11 pass checked every row rather than carrying it forward, and **six changed**; three
of those were safety claims reclassified from *untested* to KNOWN GAP purely by reading source
(`PARITY.md:2140-2141`). This order finishes that pass rather than repeating the mistake it
corrected: three of the remaining rows are also decidable at a desk, and only two need hardware.

It does not include `G15`'s crash-backout row, which §14b (`:2568`) owns and which needs a mint and
`R1`. **Note the scope precisely:** §15's two `G15` gates are *"A Dart-phase crash backs the patch
out"* and *"Two engines in one process run the same program version"* (`:2669-2670`).
Restart-required is **§8's** row, not §5's — §9's closing note (`:2340-2341`) is what ties the same
once-per-process guard to all three sections.

## Preconditions — check these before claiming anything

1. Read §5 (`PARITY.md:2098`) and §14b (`:2568`) in full, so `G15`'s clauses are not re-queued here.
2. Verify the already-fixed correction *at the cited location*, per the correction rule:
   `grep -n "correctly refuse" selfhost/engine/route_b/probes/assert_installed_release.sh` →
   **no match** (exit 1); `sed -n '63,72p'` shows the corrected text, which now says the updater
   does **not** refuse. §5's instruction to *"fix that comment where it sits"* (`:2159-2160`) is
   stale — the fix already landed.
3. Verify the server scoping seam yourself:
   `sed -n '1968,1996p' packages/code_push_server/lib/src/api.dart` → `releaseByVersion` at
   **`:1970`**, `if (patch == null || patch.releaseId != release.id) return …` at **`:1989`**, and
   `if (patch.number <= clientPatch)` at **`:1995`**.
4. Verify no test pins it. **`grep -n "releaseId" test/api_test.dart` returns 72 hits** — helpers,
   `seedApp`'s record type at `:75`, artifact URLs — so it is a noisy grep, not a negative one, and
   it settles nothing. Read the `/patches/check` tests at `:942`, `:1001`, `:1447` and look for one
   that seeds **two** releases on one app and checks from the *older* `release_version`. A negative
   grep is not coverage.
5. §17 claims: `R2`, `R9`, `R10` free. Wired device only. `cps-android` must be running — as
   grounded it is not.

## Steps

1. **Reclassify, with citations, before booking anything.** Three edits in §5:
   * *"NOT VALIDATED Patch-from-older-release rejection matrix (both)"* (`:2138`) → the normal
     delivery path is closed by construction: the server resolves the release from the device's own
     `release_version` (`api.dart:1970`) and refuses to hand over a patch belonging to another
     release (`:1989`). What remains unvalidated is only the hand-packed case, which is already
     covered by the KNOWN GAP row *"A wrong-release patch is downloaded, installed, promoted and
     **reported as a successful install** before anything refuses it"* (iOS, `:2124`) — not the row
     physically adjacent to it. **Removes a two-platform device gate.**
   * *"BUILT … refused inside the patcher — host tests only"* (`:2128`; the gate is
     `ios_patcher.dart:222` calling `_verifyReleaseIsPatchable`, defined `:796-811`) →
     **DEFERRED**, with the reason: the gate only fires for a release carrying Route B provenance
     (`ios_patcher.dart:219-221`), and every preserved release records a healthy patchable-site
     count — `grep -hE "^patchable" selfhost/evidence/releases/*/RECORDED` gives **7,141** for
     releases 24–30, **7,142** for 31 and **7,144** for 32. Validating the refusal through the
     product path needs a cell minted deliberately without patchable call sites. Not worth a mint;
     say so instead of leaving it looking cheap.
   * Retire the "fix that comment" instruction (precondition 2), keeping the finding.
   *Check:* each edited row carries file:line and each removed device gate says why.
2. **Add the missing server regression test.** One test in
   `packages/code_push_server/test/api_test.dart`: two releases on one app, an active patch on the
   newer, a `/patches/check` from a device reporting the older `release_version` → `patch_available:
   false`. *Check:* `cd packages/code_push_server && dart test -x integration`. This is the coverage
   that makes step 1's reclassification a **BUILT** row rather than an assertion.
3. **Android device row 1 — multiple sequential patches.** §5 records three-on-one-release as
   device-proven on iOS only (`:2137`). Publish three consecutive Android patches against one
   release and read each. **[MUTATES `R9` release history, device install]** *Check:* the device
   reports patch 3 after the third, and a relaunch keeps it.
4. **Android device row 2 — corrupt patch in transit.** Publish a patch, then corrupt the served
   artifact bytes, then let the device fetch it. Identify the store first — `store.verify` is called
   at `api.dart:1737` and `:1810`; that is what hashes the bytes and therefore what has to be
   corrupted for the test to mean anything. **[MUTATES a published artifact — do this against a
   throwaway release, never one another goal's evidence cites]** *Check:* the app runs the pristine
   release and the updater does not loop the bad patch forever.
5. **Record what each row is now**, and do not let either device row's success be read as closing
   §15's failure-matrix gate — `G15` owns two gates carved out of it.

## Precommitted outcomes

Reused from §5's own established mechanisms where they exist; new rows marked.

| observation | meaning |
|---|---|
| step 2's test fails before the fix and passes after | `api.dart:1989` is real and now pinned. **Server finding**; earns **BUILT** for the older-release row |
| step 2's test passes *without* any change | good — the behaviour was already correct and merely uncovered. Record it as coverage added, not behaviour fixed |
| three sequential Android patches all observed | **device finding.** Extends §5's PARTIAL row to Android. Earns **PROVEN** for that row on Android only |
| patch 3 observed but patch 2 was skipped | `patch.number <= clientPatch` (`api.dart:1995`) means a device may jump. Sequential *delivery* is not sequential *application* — that is a distinct claim, do not merge them |
| corrupt patch: app runs the pristine release | the in-transit refusal degrades correctly. **Device finding**, and it does **not** also close corrupt-at-rest, which §5 records as a KNOWN GAP (`:2136`: refused silently forever, no tombstone, retried every boot) |
| corrupt patch: app runs the *patched* value anyway | the corruption did not reach the device — the CDN or control plane served a cached good copy. **Harness finding**, not a safety result. Re-do it or report it as unrun |
| corrupt patch: app fails to launch | the worst outcome and the reason the row exists. Report immediately; it contradicts §5's *"every failure path degrades to the pristine release"* (`:2100-2101`) |

## Exit criteria

* **BUILT** — step 1's reclassification lands with citations, and step 2's test is green.
* **PROVEN** — steps 3 and 4 each observed on `R2` with evidence, recorded per-row and per-platform.
* **NOT RUNNABLE** — step 4 is NOT RUNNABLE if the only way to corrupt the artifact is to mutate a
  release another goal's evidence cites. Cut a throwaway release first; do not borrow one.

## Evidence to record

* `selfhost/evidence/lifecycle/android/<release>/`: for step 3, the three patch numbers and the
  device's report after each plus one relaunch; for step 4, the sha256 of the artifact before and
  after corruption, the device's launch log, and the updater's own report.
* Identity facts: release version, patch numbers, platform `android` + arch, device `CPH2551`, the
  commit carrying the server test, and — for step 1 — the file:line each reclassified row cites.

## Commit shape

```bash
git add selfhost/PARITY.md \
        packages/code_push_server/test/api_test.dart
git commit  # fix(selfhost): G5 — the older-release row is closed by source, and now pinned by a test
```
Then a second commit for the device rows carrying `selfhost/evidence/lifecycle/...`, the §5 row
updates and the `R2`/`R9` claim rows with tree health — set on start, **cleared on stop even
mid-goal**. Explicit paths only.

## Do not

* Do not book `R1` for anything in this order. Every remaining iOS row here is either `G15`'s, a
  KNOWN GAP, or DEFERRED.
* Do not "fix" `assert_installed_release.sh`'s comment. It is already correct (`grep "correctly
  refuse"` returns nothing); editing it back would re-introduce the wrong claim §5 caught.
* Do not treat corrupt-in-transit passing as evidence about corrupt-at-rest. §5 separates them and
  the at-rest row is a gap, not an untested case.
* Do not upgrade the patcher-refusal row because its unit tests pass — the tail rule (`:3252-3258`)
  names *"unit tests pass"* first in the list of things that do not earn PROVEN.

## Open questions

* **Where does step 4 corrupt the bytes** — the control plane's artifact store, or the CDN cache?
  The store is what the device actually fetches from and is the honest test; the CDN is easier and
  proves less. Recommendation: the store, on a throwaway release. Note that
  `PLATFORM_MATRIX.md`'s own citation for `store.verify` (`api.dart:523`) is **stale** — the calls
  are at `:1737` and `:1810`. Do not inherit the wrong anchor.

---
---

# (b) G13 — the sealed independence run. Last, and alone.

> One sealed run, on a *current* release, that passes the iOS **code**-patch stage — the claim
> today's sealed proof does not make, because both of its iOS patch invocations used
> `--assets-only` until the stage added on 2026-08-13.

| field | value |
|---|---|
| status | **NOT VALIDATED** — §13's last row (`PARITY.md:2495`), *"The sealed run itself, on a current release."* Its code-patch stage is **BUILT 2026-08-13, NOT YET RUN** (`:2494`); §13's three gates are **not all green** (see preconditions) |
| owns | `R11` **sealed CDN — host-global**, plus `R1`, `R6` (or its clone), `R8`, and `R2`+`R9` if the Android leg runs, and `R12` for the one artifact only the Linux box can build |
| excludes | **everything.** §16 hard rule 5 (`:2747-2749`): *"`G13` runs alone. `R11` is host-global; sealing the CDN fails everyone else's builds. Last in a batch, never concurrent."* This is structural: `upstream/sealed.caddy` answers every cold fetch with `respond "sealed: refusing upstream fetch for {uri}" 502`, so another lane's build does not slow down, it fails |
| blocked by | §13's three gates, of which **two are red right now**: the ownership audit for the cell in use, and the pub seed. The third (a code-patch stage) is BUILT. **Plus one the draft of this page originally missed: the fixture version must be bumped** — see precondition 5 |
| unblocks | §13's ability to claim more than *"PROVEN FOR THE AUDITED CELLS / UNAUDITED FOR THE CELLS IN USE"* (`:2517`) |
| device needed | `R1` iPhone (and `R2` if the Android leg runs in the same sealed window) |
| mint needed | no — but the **audit follows whichever cell the other gates minted**, which is why this goes last |
| est. shape | one full session, exclusive; plus a separate `R12` errand beforehand that does not contend |

## Why this is the piece it is

It is the only order here that takes the machine. `R11` is host-global, and the queue already ranks
§13 fifth *"despite being nearly done"* because it does not constrain Route B's capability. Its
prerequisites are also the only ones in this set that **move backwards when someone else
succeeds**: gate 1 is *"the ownership audit is green for the Route B / iOS cell actually in use"*,
and a new mint resets it. That has already happened — `ba4e1c02` minted
`4df8f9b6139b67d2cfe9f6aa8212372cade36278`, and the audit for that cell reports **missing-required 5
/ unprotected 2** where the previously audited cell `881e4129…` reports **1 / 0** (both run
read-only during this grounding; numbers below). Running this before the language/safety gates stop
minting is paying for an audit twice — and `PARITY.md:3077` says three more device gates are queued
against that very cell.

It does **not** include minting anything, and it does not include fixing the harness's stage order —
but it **does** now include one harness edit as step 0, because the precommitted table below
predicts the run fails without it.

## Preconditions — check these before claiming anything

1. **Nobody else is working.** `git log --oneline -5`, `git status --porcelain`, and §17's claims
   table: **every** row must read free. Sealing while another lane builds destroys that lane's run,
   not just its schedule.
2. **Claim `R11` in a commit before sealing**, with tree health stated (GREEN vs RED/mid-edit).
   `R11` cannot be detected — an unclaimed resource looks exactly like an available one (§17:2843).
3. **Gate 1 — the audit, for the cell actually in use.** Resolve the cell by hash, **and by reading
   the comment block above the entry** — `tail` alone will mislead you:
   ```bash
   grep -n "^[0-9a-f]\{40\} " selfhost/cdn/experimental_hashes.map | tail -3
   selfhost/cdn/audit_overlay.sh --hash <cell> --cell macos-ios; echo "exit=$?"
   ```
   That `tail -3` returns `881e4129…` (`:200`), `11e56957…` (`:208`) and `4df8f9b6…` (`:215`) — but
   **`11e56957` is the G15 iOS *engine*, not a compiler cell** (`:202-207`). Auditing it as
   `macos-ios` is a category error. Expect `exit=0` and no findings. Grounded, measured:
   * `881e4129…` → **1 missing-required, 0 unprotected**: `patch-linux-x64.zip`
     (`artifact_policy.conf:85`, *"built on the Linux box"*).
   * `4df8f9b6…` → **5 missing-required + 2 unprotected**, and the two categories are not the same
     set: `sky_engine.zip` and `flutter_gpu.zip` are **both** missing-required **and** unprotected;
     `artifacts_manifest.yaml`, `patch-darwin-x64.zip` and `patch-linux-x64.zip` are
     missing-required only.
4. **Gate 2 — the seed matches the fixture.** `grep pubspec_lock_sha
   selfhost/fixtures/airgap/SEED.txt` vs `shasum -a 256
   selfhost/fixtures/airgap_app/pubspec.lock`. Grounded: `a66687bc…` vs `205f237f…` — **drifted, as
   §13 records** (`:2492`).
5. **The fixture version must be bumped, and this is load-bearing.** `app_release_version()`
   (`airgap_acceptance.sh:244-246`) derives `--release-version` from `pubspec.yaml`, which reads
   `32.0.0+1` — and **release 32 already exists on `cps-ios` with patches 1 and 2**
   (`selfhost/evidence/releases/32/` holds `patch1.routeb` and `patch2.routeb`). Stage `ios` would
   re-cut `32.0.0+1` and be refused by `UNIQUE(app_id, version)` (`repository.dart:393`). Bump to
   `33.0.0+1` **and commit it before sealing** — an uncommitted version bump is §17's own
   device-gate-in-flight tell (`:2818-2824`) and will make every other worker back off `R1`/`R3`/`R6`
   for the wrong reason.
6. **Gate 3 — the code-patch stage exists.** `grep -n "ios-code-patch" selfhost/scripts/airgap_acceptance.sh`
   → `:672`, dispatching `ios_code_patch` (`:476`). Read its six ordered gates in the comment block
   at `:420-456` before running.
7. **Endpoint agreement.** `cat selfhost/fixtures/airgap/endpoint.stamp` (grounded:
   `http://10.0.0.7:18080`) must equal the fixture's `base_url` **and** the container's
   `PUBLIC_BASE_URL`, or `ios_release_patch` refuses — two separate checks at
   `airgap_acceptance.sh:542-562`. `base_url` is baked into `flutter_assets`: run
   `prepare_ios_endpoint.sh --mode lan` **before** the build.
8. Device wired: `ioreg -p IOUSB | grep -i iphone`. Never a wirelessly-paired device.

## Steps

0. **Fix the `code_patch` expectation first, as its own commit.** `assert_beacon_code` is called
   with an expected code-patch number of `1` (`airgap_acceptance.sh:531`), but stage `ios` publishes
   an assets-only patch first (`:596-597`), which consumes patch number 1 against that release — the
   stage's own assertion confirms it (`assert_beacon patched PATCHED-AIRGAP 1`, `:604`). `code_patch`
   is the server-side patch number (`fixtures/airgap_app/lib/main.dart:260`,
   `runtime.patchNumber?.toString()`), so the code patch is number **2**. Fix the expectation before
   the sealed window opens, not inside it.
1. **Close gate 1, and note that only ONE of its artifacts needs `R12`.**
   * **1a — Mac-side, no `R12`, does not take `R11`.** For `4df8f9b6…`: publish `sky_engine.zip` and
     `flutter_gpu.zip` (both missing *and* unprotected), cross-build `patch-darwin-x64.zip`
     natively, and emit `artifacts_manifest.yaml` with `audit_overlay.sh --emit-manifest` (`:49`).
     §13 records all four as Mac work already done once for `881e4129` (`:2486`).
   * **1b — the one Linux-only artifact, on `R12`.** `patch-linux-x64.zip`
     (`artifact_policy.conf:85`). `R12` is additive capacity nobody schedules against, so this can
     happen days earlier and does not take `R11`.
   **[MUTATES the CDN overlay + requires a CDN reload]** For both: **publish bytes first, then
   protect the path** — the audit's own FIX ORDER note, printed verbatim beside every UNPROTECTED
   finding: *"protecting an absent artifact 404s every build against this hash."* *Check:*
   `audit_overlay.sh --hash <cell> --cell macos-ios` exits 0.
2. **Re-run the fixture preparation, unsealed, immediately before sealing.** **[MUTATES `R6` and
   the shared pub seed]** `selfhost/scripts/prepare_airgap_fixture.sh` — it network-resolves into
   the seed (`:194-219`), so it *cannot* run after the seal. §13 (`:2540-2543`): *"Run it
   immediately before the next sealed attempt, then re-check `SEED.txt` against the fixture's
   `pubspec.lock`."* *Check:* the two sha256s from precondition 4 now match.
3. **Warm run, unsealed.** Full `airgap_acceptance.sh --ios` (and `--android` if that leg is in
   scope) with the CDN in normal mode, so every real dependency is pulled through the mirror.
   *Check:* it passes, and `verify_warm.sh` is meaningful only after this.
4. **Seal.** **[MUTATES `R11` — host-global; every other build on this machine now fails]**
   ```bash
   docker compose -f selfhost/cdn/docker-compose.cdn.yaml \
                  -f selfhost/cdn/docker-compose.cdn.sealed.yaml up -d
   ```
   The override remounts `upstream/sealed.caddy` over `/etc/caddy/upstream_gcs.caddy`
   (`docker-compose.cdn.sealed.yaml:22`, replacing `upstream/enabled.caddy` from
   `docker-compose.cdn.yaml:69`) and recreates `cdn-cache`, so Caddy re-reads its config.
   *Check:* a deliberate cold fetch returns the greppable `sealed: refusing upstream fetch` 502.
5. **Run the payload under the enforcement wrapper.**
   ```bash
   sudo -v && selfhost/scripts/airgap_run.sh -- \
     selfhost/scripts/airgap_acceptance.sh --ios --app <fixture-or-clone>
   ```
   Stages run in the order at `airgap_acceptance.sh:664-673`:
   `control-plane-durable` → `cli-revision` → `bootstrap` → `ios` → `ios-code-patch` →
   `post-checks`. **[MUTATES `R8` release history and the device install]**
6. **Post-checks, and read them.** `verify_warm.sh` (or `AIRGAP_VERIFY_ARGS="--log-file …"` for a
   remote leg — supported at `verify_warm.sh:43`, passed through at `airgap_acceptance.sh:625`) must
   report zero refusals *that a stage needed*. A refusal list on a passing build means the build
   quietly did without something — read it, do not bank it.
7. **Unseal, and clear the claim.** **[MUTATES `R11`]** `docker compose -f
   selfhost/cdn/docker-compose.cdn.yaml up -d` restores `upstream/enabled.caddy`. Clear `R11`,
   `R1`, `R6`, `R8` in the same commit as the evidence. A stale row here costs someone a whole
   build.

## Precommitted outcomes

§13's *"three gates before this section may claim more"* (`PARITY.md:2519`) is the outcome table for
the *claim*, reused verbatim:

| | gate |
|---|---|
| ☐ | The **ownership audit is green** for the Route B / iOS cell actually in use — not only for the historically audited `70974f81` |
| ☐ | The **air-gap fixture and its pub seed are current** with each other |
| ☐ | The **sealed harness actually exercises iOS code patching** — today both its iOS patch invocations pass `--assets-only` |

Gate 3 is now BUILT (`airgap_acceptance.sh:672`); it becomes green only when the stage *runs*.

Outcomes for the run itself:

| observation | meaning |
|---|---|
| all stages pass, `verify_warm.sh` reports zero needed refusals | independence PROVEN for a current release **including a code patch**. The strongest result available here |
| all stages pass, `verify_warm.sh` lists refusals | the build did without something it wanted. **Host finding**, and it caps the claim — read the list before writing a status |
| stage `ios` fails cutting the release, duplicate version | precondition 5 was skipped. Release `32.0.0+1` already exists with two patches; `repository.dart:393` refused it. **Harness/bookkeeping finding, not a Route B verdict.** Bump, commit, re-run |
| `ios-code-patch` fails on *"expected code_patch=1"* | **harness bookkeeping, NOT a Route B failure**, and step 0 exists to prevent it. Stage `ios` publishes an assets-only patch first (`:596-597`), consuming patch number 1, so the code patch is number **2** while `assert_beacon_code` demands 1 (`:531`). Fix the expectation, re-run; do not record a Route B verdict from it |
| `ios-code-patch` fails at gate 3 (`assert_result_consumed.sh --fixture-signature`, `:499`) | the release's `value()` body was foldable — the call's result is discarded at the call site. **Producer/host finding.** The harness comment at `:434-455` records six device runs and five overturned attributions spent on exactly this |
| `ios-code-patch` fails at gate 5 (`AIRGAP_EXPECT_UUID`, `:523-530`) | the installed `.ipa` is the patch build's, not the release's. This is *"the strongest false positive available here"* — a pass here would have shown the patched value for the wrong reason |
| `bootstrap` dies on `fatal: no path specified` | `AIRGAP_REPO` is unset while running a copy from `/tmp` (`airgap_acceptance.sh:50-67`). Harness finding |
| a stage passes but `cli-revision` warned STALE CLI | the wrong binary was tested. `SHOREBIRD_ROOT` (`:33`) is its own checkout, `cli_revision_check` is `:114` and the warning is `:131`; a pass proves nothing about this repo's CLI |
| another lane reports a build failure during the window | expected and caused by you. `R11` is host-global — this is not evidence about their goal |

## Exit criteria

* **BUILT** — already met for the harness: the code-patch stage exists and fails closed through six
  ordered gates (`:420-456`). Nothing in this order may re-earn BUILT.
* **PROVEN** — the sealed run completes on a **current** release with `stage ios-code-patch`
  passing and `verify_warm.sh` clean, on `R1`, with the audit green for the cell that release was
  cut against. **Unreachable until step 0 lands**, because the precommitted table above predicts the
  stage fails on its `code_patch` expectation otherwise.
* **NOT RUNNABLE rather than unrun** if gate 1 is red for the cell in use and its missing artifacts
  need `R12` — then this order has not failed, it has not started. Say that, and do not seal.

## Evidence to record

* `selfhost/evidence/releases/<n>/`: the preserved set as it actually exists on disk —
  `App`, `LC_UUID`, `RECORDED`, `patchN.routeb`, `patchN.routeb.trace`, `verdict.txt`, plus
  whatever the run generates (release 32 also carries `dynamic_interface.yaml`,
  `patchN.replacement.dart`, `patch2.capabilities.json`). `ios_code_patch` writes the base set via
  `probes/preserve_release_evidence.sh` (`airgap_acceptance.sh:488`).
* `selfhost/evidence/releases/<n>/sealed/`: the full `audit_overlay.sh` output for the cell, the
  `verify_warm.sh` output, the beacon lines for baseline and code-patched, and the compose
  invocation used to seal.
* Identity facts, all of them, per the tail rule: engine/cell hash (grounded candidates
  `881e4129…` / `4df8f9b6…`; `11e56957…` is an engine, not a cell), release version, patch number,
  platform + device (iPhone 7 / iOS 15.8.8), probe names (`assert_result_consumed.sh`,
  `verify_patchable_release.sh`, `assert_installed_release.sh`), and the commit containing the run.

## Commit shape

```bash
# the bookkeeping fix, before the window opens
git add selfhost/scripts/airgap_acceptance.sh
git commit  # fix(selfhost): the code-patch stage expects patch 2, because stage ios consumes patch 1

# the version bump, committed so it is not mistaken for a gate in flight
git add selfhost/fixtures/airgap_app/pubspec.yaml
git commit  # chore(selfhost): fixture to 33.0.0+1 — release 32 is spent (two patches)

# claim BEFORE sealing
git add selfhost/PARITY.md
git commit  # chore(selfhost): claim R11 + R1 + R6 + R8 for the sealed G13 run — tree health GREEN

# after the run
git add selfhost/evidence/releases/<n> selfhost/PARITY.md
git commit  # feat(selfhost): G13 — the sealed run, on a current release, with a code patch
```
The final commit must carry §13's row updates, the three-gate table, and the §17 claim rows
**cleared**. Never `-A`, never `commit -a` — another worker's edits may be sitting unstaged.

## Do not

* Do not seal without a claim commit. `R11` cannot be detected and the failure mode is other
  people's builds breaking with no explanation.
* Do not run this concurrently with anything, including something "small" and hardware-free. The
  sealed mirror refuses cold fetches host-wide.
* Do not inherit §13's *"4 findings to 1"* as the current audit state. That is `881e4129…`; the
  cell in use may be newer, and `4df8f9b6…` audits at **5 missing-required + 2 unprotected**.
* Do not audit `11e56957…` as a compiler cell. It is the G15 iOS **engine**
  (`experimental_hashes.map:202-208`).
* Do not refresh the seed as maintenance. §13 (`:2537`): *"Do not refresh the seed today"* — it
  churns `R6` for no result unless the sealed run is happening now.
* Do not protect an artifact path before publishing its bytes — the audit prints the FIX ORDER note
  beside every UNPROTECTED finding for exactly this reason.
* Do not let `AIRGAP_SKIP_DEVICE` into this run. It publishes an assets-only patch and returns
  (`airgap_acceptance.sh:582-588`), and *"PASS from this stage means publication succeeded, nothing
  more."*

## Open questions

* **Does the Android leg belong in the same sealed window?** Including it proves both legs under one
  seal but pulls in `R2`, `R9`, `R12` and the reverse-tunnel `verify_warm.sh --log-file` topology
  (`verify_warm.sh:25-30`). Recommendation: iOS only for the first pass — the code-patch stage is
  the new claim and Android's sealed pass already exists (2026-08-06). Note `cps-android` is not
  running as grounded, which makes iOS-only the cheap default anyway.
* **How many patches will this release carry, and does the beacon assertion need to be a range?**
  Step 0 hard-codes 2. If a future stage inserts another patch before `ios-code-patch`, the same
  bug returns. Recommendation: fix the number now, and file deriving it from the server's patch list
  as the durable follow-up rather than doing it inside the sealed window.