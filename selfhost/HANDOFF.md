<!-- cspell:words dartsdk prebuilts bidiff vmcode aot daemonized crashprobe jewgo azureuser sshkey serverinfo jank -->
<!-- cspell:words APFS CODEPATCH PRECOMPILER Werror caffeinate dartaotruntime SEGVs Specializer diskutil dumpsys flowgraph iface killgate libdart nodm nofail precompiler unapply -->
<!-- cspell:words tearoff DNDEBUG SEGV LINKEDIT ourengine noinstall SELTOTAL hosttest unrun closurizing closurized closurize closurization bodyless pids footgun mtimes repointed rbtest Devirtualization genkernel misparse -->
<!-- cspell:words airgap justlaunch noninteractive SIGTRAP dynmod absolutized DEFAULTPATH SIGPIPE PIPESTATUS -->
<!-- cspell:words SBRBPTCH inspectable janky premain representability routeb reconstructibility -->

# Handoff — engine improvements (as of 2026-08-07)

## 2026-08-13, 15:55 — two sessions took H2 at once. Read this before trusting `41758dd3`'s message

**The headline, because it will mislead somebody otherwise: `41758dd3`'s commit
message is wrong about its own diffstat.** It says the overlay's `project.pbxproj`
is "NOT DONE … the next session authors the transform". The commit *contains* that
file (1217 lines) and the `derive_overlay.py` that produced it (164 lines). Both
were written by a second session and were sitting unstaged when `41758dd3` staged
broadly. **A session that believes the message writes a second transform over a
working one.** Corrected in place in `plans/H2-flavored-ios-fixture.md`.

**What happened, on the clock.** Two sessions worked `H2` simultaneously, neither
aware of the other, because the fixture is NEW: it has no `R-id`, so §17's claims
table could not have shown it held, and `git status` showed one untracked directory
that each session read as its own.

| 15:41:59 | session B's `flutter create` populates `flavored_app/` seconds after session A writes `pubspec.yaml` |
| 15:44:18 | B writes `ios_overlay/BASELINE.project.pbxproj.sha256` — the sha A had computed one minute earlier |
| 15:46:02 | A writes `derive_overlay.py`; 15:46:11 it emits the overlay `project.pbxproj` |
| 15:46:32 | **B commits `41758dd3`**, sweeping in A's two files, and reports them as not done |
| 15:47:22 | A writes its `Foo/Bar.xcconfig`, **clobbering B's committed versions** |
| 15:53 | A restores B's xcconfigs byte-exact from `HEAD`, verifies the overlay, and stops |

Nothing was lost, and again only by luck of ordering — the same conclusion as the
2026-08-11 entry and the negative-control entry above it. Three instances now.

**The generalisable part is new, though.** §17's protections are keyed to the claims
table, and **a resource that does not exist yet cannot be claimed**. Both prior
instances were about *staging* discipline; this one is about *identity*: the very
first commit that creates a fixture is the one with no way to reserve it. The cheap
fix is a claims row for the path, written before the first file, even with no `R-id`.

**What is now established about H2** (host only, no device, no mint, no release):

* The overlay is structurally valid and **Xcode resolves it** — `xcodebuild -list`
  shows nine configurations (`Debug`/`Release`/`Profile` × plain, `-Foo`, `-Bar`)
  and schemes `Bar`/`Foo`/`Runner`, run against a scratch copy so the shared fixture
  was untouched. **BUILT for structural validity only** — it is a project-file
  query, not a build, and says nothing about the flavor reaching the compiler.
* ~~**Step 7's paths are wrong as written.** The committed xcconfigs set
  `PRODUCT_NAME = flavored_probe_foo`/`_bar`, and `application_package.dart:188-190`
  derives the artifact path from it, so the arms are at `flavored_probe_foo.app`,
  not `Runner.app`.~~ — **REFUTED BY MEASUREMENT 2026-08-14, and it is the inverse
  of what this said.** Three cold `flutter build ios --release --flavor <arm>` runs
  put the bundle at `build/ios/iphoneos/Runner.app` every time;
  `flavored_probe_foo.app` never exists. The `PRODUCT_NAME = "$(TARGET_NAME)"` form
  in `ios_overlay/Runner.xcodeproj/project.pbxproj` — **18 occurrences**, 9
  configurations × 2 targets — wins over the xcconfig, so `PRODUCT_NAME` is inert
  here and the path is a constant. The reasoning above was sound about
  `application_package.dart` and wrong about which value reaches it. **Anything
  telling an operator to look for a per-arm bundle path is a false-RED generator**,
  which is how this was caught. Provenance in
  `fixtures/flavored_app/ios_overlay/BASELINE.txt`. The no-token `default-flavor` arm resolves to the SAME path as
  `--flavor foo` (`flutter_command.dart:1503-1505`, `flavor = cliFlavor ??
  defaultFlavor`), so those two arms differ in what they prove, not in what they
  produce.
* ~~Still absent: `prepare_flavored_fixture.sh`, and every one of step 7's builds.~~
  — **BOTH LANDED 2026-08-14.** The script is at `selfhost/scripts/` (`f7a9ef9f`) and
  step 7's host arms ran. Note two sessions wrote that script independently within the
  hour; `f7a9ef9f` is canonical and the duplicate's non-overlapping coverage was
  salvaged separately. See §17's fix-round claims row for why.

**Resources:** none claimed, none held, none released — this session took no device,
no mint, no container, no release and no fixture version bump. `flavored_app/` is
left exactly as `41758dd3` committed it, with the two xcconfigs restored to B's
authorship.

## 2026-08-13, 15:21 — G4.2's patch half, and two corrections worth more than it

Session ran `selfhost/plans/` as an autonomous board. One piece landed: **H2 steps 5
and 6** (`9ca65dd0`), which is `BUILT`, host only. No resource was claimed: no device,
no mint, no container, no release, no fixture version bump — so there is nothing to
clear in §17's table, and it is left exactly as found.

**What is now true.** `g42_flavor_flow.sh` reports 13/13 and its row 4 pins the fix
instead of asserting the gap `25f8a3b8` closed; the patch side resolves the flavor, so
`--flavor foo` patching a `--flavor foo` release is no longer refused. Both counts and
the negative control are in `evidence/g42_flavored_fixture/g42_flavor_flow.txt`.

**Two things the next worker needs, and neither is about flavors.**

1. **The installed CLI does not carry the flavor fix.** `~/.shorebird` is pinned at
   `ba4e1c02`; the fix landed after it (`de11eecf`/`4fb03725`), and
   `grep -c _resolvedFlavor ~/.shorebird/…/patch/ios_patcher.dart` is **0**. H2's
   "already satisfied" section said the opposite and is corrected in place. **Re-sync
   before any flavored patch arm** or the matching case refuses from the stale CLI —
   release 34's failure mode, and it looks like a fixture defect at the terminal.

2. **Never run a negative control by editing in place in this tree.** A fix was
   commented out for ~60 seconds to prove its tests fail without it; another worker
   committed inside that window and captured the *disabled* state plus four tests,
   three of which failed against it (`de11eecf`), which `4fb03725` then repaired.
   Nothing was lost, and only because the window was short. Now house rule 9 in
   `plans/README.md`: use a scratch worktree, or land the fix and revert in a
   throwaway. **A deliberately-broken file looks exactly like a mistake.**

**What remains of H2**: steps 1-4, 7 and 9 — `selfhost/fixtures/flavored_app` and
`selfhost/scripts/prepare_flavored_fixture.sh` are both still ABSENT, so `--flavor`
cannot build in this repo and **no device arm of `G4.2` is constructible**. That is a
prerequisite gap, not a failed gate.

## If you are picking this up: read [`ROUTE_B.md`](ROUTE_B.md), not this file

The infrastructure track is **closed**. The remaining project is Route B — iOS
Dart code push — and [`ROUTE_B.md`](ROUTE_B.md) is its plan of record: the one
call-shape change it comes down to, the five pieces to build, a deliberately
tiny first success criterion, where to work down to file:line, the three things
to do before Step 1, and the traps that will bite. It assumes nothing.

Route B in a sentence: vanilla Dart already has the interpreter, `InterpretCall`
and `AttachBytecode` behind `dart_dynamic_modules`; what is missing is a call
that dispatches **through the `Function`** instead of to a baked-in AOT target,
so `AttachBytecode` can redirect it later. No new VM, no writable code pages.

**This file is a 1,800-line dated working log.** It is worth reading for the
evidence chains and the debugging traps, and it is *not* required before you
start. The section below is the current state; everything after it is history.

| you want | read |
|---|---|
| to start Route B | [`ROUTE_B.md`](ROUTE_B.md) |
| the iOS code-push evidence chain | [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) |
| what still depends on upstream | [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) |
| rig state: data, config, secrets | [`fixtures/CONTROL_PLANE_DATA.md`](fixtures/CONTROL_PLANE_DATA.md) |
| the acceptance fixture | [`fixtures/airgap_app/README.md`](fixtures/airgap_app/README.md) |
| why the compiler carries four patches | [`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md) |

## Current state — 2026-08-07. READ THIS SECTION BEFORE ANY OTHER

Everything below this section is a dated working log, kept because the evidence
chains and the traps are worth reading. **Where it disagrees with this section,
this section wins.** Several older passages describe problems that are now
solved; they are marked where they matter, but do not go re-opening a question
because a 2026-08-04 paragraph phrases it as open.

### The capability statement (authoritative — do not restate it more warmly)

> **Android Dart code push and iOS asset push are complete and independent. The
> entire iOS Dart code-push path — PRODUCER INCLUDED — is proven on physical
> hardware: `shorebird release ios` -> one-line source edit -> `shorebird patch
> ios` -> control plane -> updater download -> inflate -> hash check -> install
> -> lifecycle promotion -> native pre-main activation -> patched Dart running
> -> relaunch still patched -> rollback to pristine AOT, with no Dart-side
> cooperation and nothing manual in between, at +4.5 % size and +0.3 % median
> frame time with zero added jank. The limit is the REPLACEMENT BODY'S REFERENCE
> CLOSURE: every reference must resolve inside the release's declared retention —
> literals, the receiver's own members including release-private instance state
> granted through G3.6b/P2, retained public app symbols, and named SDK members in
> the release's dynamic interface. Release 31, 2026-08-13, proved both ends on an
> iPhone 7 from byte-identical installed release bytes: `=> 'NEW-CTL'` and
> `=> _secret`. This does not establish arbitrary dependency reach; see
> [`ROUTE_B.md`](ROUTE_B.md)'s frozen surface for what the producer refuses by
> design.**

*The mechanism is proven; arbitrary dependency reach is not.* Both are true at
once and they are different claims -- do not let "iOS code push works" become
"any iOS patch works".

> **Superseded, 2026-08-13.** This statement previously ended *"it may reference
> nothing outside itself, `dart:core` included. A body calling `DateTime.now()`
> fails in the bytecode loader (Probe A0)"*, and the line above it read *"the
> runtime is proven; the producer is not"*. Both were true when written and both
> were overtaken: A0 closed on device (release `15.0.0+1`, `PARITY.md` §3), the
> producer is device-proven, and release 31 closed the private path. The caveat
> was RE-AIMED at the boundary that is actually live rather than dropped, which is
> the precedent `PARITY.md`'s documentation-drift section sets for exactly this.

On 2026-08-10, on an iPhone 7, in this order: the 4a gate (baseline OLD,
attached NEW, detached OLD, one process, no restart), then seam 6 (the same
redirect performed natively before `main`, from a build with no Dart-side attach
path), then the full ten-step delivery sequence on release 9.0.0+1 -- fresh
release OLD, control plane publishes, the real updater downloads and inflates
and installs, relaunch reads NEW, relaunch again still NEW from persisted
lifecycle state, rollback, relaunch reads pristine OLD.

Both vetoes closed the same day: +4.5 % size and, over five alternating paired
runs, +0.3 % median frame time with 0 janky frames in 3,000 per arm.

The producer exists and is proven on device (2026-08-11, release 10.0.0+1, patch
2): `shorebird patch ios` resolves the release's own compiler cell, runs
coverage, compiles the replacement body, packs the container and ships it
through the ordinary artifact path. What is NOT proven is any replacement body
that references something outside itself — see "Probe A0" below.

### Route B state, 2026-08-10 — what is proven, what is next

**Runtime: complete, on hardware. Do not touch it, and do not re-verify it.**
After runtime has been proven, assume producer / provenance /
release-construction first when something fails.

| layer | state |
|---|---|
| patchable call emission | shipped, `--patchable_static_calls`, both vetoes closed |
| symbol retention, target identity | done |
| SBRBPTCH container, apply, rollback | done |
| control plane -> updater -> inflate -> install | **proven on device** |
| content sniffing (container never reaches the snapshot loader) | **proven on device** |
| native pre-main activation, build-ID validated | **proven on device** |
| persistence across relaunch, rollback to pristine AOT | **proven on device** |
| **`shorebird patch` producing the container** | **NOT BUILT** |

**Producer: the invariants landed before the code that needs them.**

| guard | where |
|---|---|
| releases are patchable by construction *and* the shipped binary is verified | `ios_releaser.dart`, `route_b.dart` |
| a code patch is refused against a non-patchable release | `ios_patcher.dart` |
| a Route B release can never fall back to the private linker | `ios_patcher.dart` |
| the compiler ships as one engine-scoped cell (runtime + snapshot + platform dill) | `route_b/publish_route_b_compiler.sh` |
| the cell is audited for reconstructibility, not presence | `route_b/audit_route_b_compiler.sh` |
| one resolution, one engine cell, no ambient fallbacks | `route_b_compiler.dart` |
| the release records the engine that built it, and the patch reads it back | `route_b_provenance.dart`, `ios_releaser.dart` |
| the cell is fetched by the RELEASE's engine hash, never the machine's | `route_b_compiler_cache.dart`, `ios_patcher.dart` |
| coverage analysis is version-matched to the release's frontend, not the machine's | `route_b/coverage/analyze_coverage.dart` (ships in the cell) |
| the ported analysis is differentially checked against the untouched host tools | `route_b/coverage/parity.sh` — 8/8 |
| the release uploads BOTH kernels it owes, hashed, and the patch reads only those | `route_b_provenance.dart`, `ios_releaser.dart`, `ios_patcher.dart` |
| the second kernel is built by the RELEASE engine's frontend, from the cell | `route_b_release_kernels.dart`, cell artifact `route_b_gen_kernel.aot` |
| forwarded build inputs are checked, not promised | `RouteBReleaseKernelBuilder.agreesWith` |
| coverage runs before any compile, and a rejection takes the whole patch | `ios_patcher.dart` |
| the container and the release build ID are the CLI's own, deterministic | `route_b_container.dart` |
| the CLI's container AND artifact are byte-identical to the manually proven tools | `route_b/host_equivalence.sh` — 5/5 |
| Route B ships through the ordinary differ + upload; no separate publish tool | `ios_patcher.dart` |

#### Three failure signatures that cost real time, now detected

1. **`applied N/N targets` in the `.routeb` report, and `OLD` on screen.** The
   release was built without `--patchable_static_calls`; AOT emitted direct
   calls that never consult `Function.entry_point_`. The attach genuinely
   succeeded. Burned releases 7.0.0+1 and 8.0.0+1. Now detected from the shipped
   bytes on both the release and patch sides.
2. **A refusal with nothing to read.** No engine log line of any kind reaches
   `idevicesyslog` for a `--noninteractive` launch on this device, Flutter's own
   included. The engine now writes `<artifact>.routeb` beside the installed
   patch; pull it with `ios-deploy --download`.
3. **A compiler bundle that runs but is not the one we published.** A tampered
   snapshot still executed *and* still advertised `--target flutter`; only the
   hash caught it. Hashes and the capability probe are both required and neither
   substitutes for the other.
4. **A compiler cell from the wrong lineage, chosen by a check that passed.**
   The engine hash reaching `ios_patcher` came from
   `<flutterDir>/bin/internal/engine.version` — a mutable local file this repo's
   own scripts rewrite to switch experimental engines. Fifteen engine hashes
   share the one pinned Flutter revision, and `Release` records no engine, so
   nothing release-side could distinguish them. Closed 2026-08-10: the release
   now carries `route_b.json` in its supplement and the patch reads the hash out
   of those bytes.

#### Provenance milestone — CLOSED 2026-08-10

`resolveRouteBCompiler` is load-bearing, keyed on the release's own engine hash,
with no ambient fallback and no linker fallback. Detail and the evidence chain
in [`engine/route_b/README.md`](engine/route_b/README.md) — "Compiler-cell
selection".

Two consequences worth knowing before anything else:

- **Releases cut before 2026-08-10 are refused**, including `9.0.0+1`, the
  release the runtime was proven on. Filed as RELEASE-INCOMPATIBLE: nothing can
  be republished to fix it. Cut a new release.
- **A server-side `engine_revision` on the release is follow-on work.** The
  sidecar is the record today; the field is a wire-contract change gated by
  `compatibility.yaml`. Once both exist they must agree.

#### Coverage port — DONE, parity green 2026-08-10

Detail in [`engine/route_b/README.md`](engine/route_b/README.md) — "Coverage
analysis". Three things carry forward:

- **The analyzer ships in the compiler cell**, which is now four files.
  `package:kernel` is unobtainable outside an engine checkout (the pub copy is
  the dead pre-null-safety one; the vended SDK ships no `pkg/`), and the kernel
  binary format is versioned anyway — so the reader belongs to the release's
  toolchain. Rebuild ⇒ republish ⇒ audit, as before.
- **`conditional` is not decidable from a kernel.** A monomorphic instance call
  and a genuine dispatch-table call are byte-identical in the analysis: same
  bucket, same verdict, patch accepted. The reference behaves the same way and
  the port preserves it. Closing it needs per-call-site data from the release's
  `App` binary, which the patcher already downloads.
- **The parity harness was proven to fail**, not merely to pass — two injected
  divergences, both caught, both reverted.

#### Release-side prerequisites — DONE 2026-08-10

Both release kernels land in the supplement, hashed, and the patch side requires
and verifies both. The cell is six files: it also carries the release's own
`gen_kernel` and — a correction worth knowing — `flutter_platform_strong.dill`,
because `vm_platform.dill` is the **VM** platform and a real app is
`--target flutter`.

Two things the checks found rather than assumed:

- **A missing Dart plugin registrant** cost 59 non-accessor members in the
  import kernel. Flutter passes `--source`/`-Dflutter.dart_plugin_registrant`
  when the build generates one; that is now derived from the build's own file.
- **AOT materializes field accessors as procedures**, non-AOT does not, so 250
  `get:`/`set:` differences are structural and excluded from the agreement
  check — with a negative control proving the check still bites.

#### Producer branch — orchestration landed 2026-08-10

`ios_patcher` verifies the release package, resolves the six-file cell, checks
that the two release kernels describe the same program, runs coverage against
the release's own kernel, refuses the whole patch on any rejection, derives the
LC_UUID from the shipped bytes — and stops. Coverage runs BEFORE any compile so
a coverage rejection, a compiler failure and a container failure stay three
distinct problems.

The SBRBPTCH writer and the Mach-O build-ID reader are ported into the CLI
(`route_b_container.dart`); the host tools remain the reference. The format is
deterministic, so the host-equivalence gate can require exact SHA equality.

#### THE REMAINING GAP — read this before planning "just orchestration"

`Dart_RouteBActivatePatch` calls `LoadBytecode()`, takes the ONE `Function` it
returns, and attaches that function's bytecode to the target. So **one payload
is one function**, and the producer must generate a synthetic replacement
library per changed target. Both general alternatives are closed, measured:

- compiling the patched app's own entrypoint against `--import-dill` **crashes**
  (library collision, `kernel_generator_impl.dart:179`)
- compiling the whole app under an aliased package name compiles, but nothing
  selects a target out of a single loaded function

Unknowns that must be probed on the fixture before any general scheme:
class members cannot be redeclared in another library, private members resolve
per-library, and whether a top-level replacement can serve as an instance method
body is a RUNTIME question against a frozen runtime.

#### Producer, narrow path — DONE 2026-08-10

`shorebird patch`'s own producer compiles a replacement body and packs an
SBRBPTCH whose bytes are **identical** to the packer that produced the container
proven on hardware (`host_equivalence.sh`, 3/3). Exact SHA is fair: the format
has no timestamps and no ordering that depends on anything but the target list.

The analyzer is now `analysisVersion: 2` and reports a source span per changed
member (`Procedure.fileStartOffset` → `fileEndOffset`), which the producer
slices — from bytes, not from a Dart String — to build one single-declaration
library per target. That is the shape the runtime requires: `LoadBytecode()`
returns ONE Function and that is what gets attached.

**Claim it narrowly.** The complete automatic path works for the currently
supported replacement shape — a self-contained declaration. NOT "arbitrary Dart
functions can be patched."

#### Artifact layer — ANSWERED IN BYTES 2026-08-10

The updater inflates code artifacts against the running app's base — on iOS the
four Dart blobs behind `SnapshotsDataHandle` — which a container has nothing in
common with, and which the producer cannot reproduce without `analyze_snapshot
--dump_blobs`. So the artifact is diffed against a ONE-BYTE synthetic base,
making it pure literal inserts that never read the base.

`route_b_artifact` is `patch::make_patch(base, container)`, the same Rust crate
the CLI's `patch` executable wraps — and their outputs are **byte-for-byte
identical** (624 bytes). `ios_patcher` therefore uses `artifactManager.createDiff`
like every other platform, and **no separate publishing script remains in the
product path**.

`hash` = sha256(CONTAINER) because `check_hash()` runs against the inflated
result; `size` = bytes(ARTIFACT). Same split the linker path already used.

#### THE AUTOMATIC DEVICE GATE — PASSED 2026-08-11

iPhone 7, iOS 15.8.8, USB. Release `10.0.0+1`, patch 2, nothing manual between
the source edit and the device: OLD -> NEW -> relaunch NEW -> rollback ->
pristine OLD. Detail and screenshots in
[`engine/route_b/README.md`](engine/route_b/README.md).

**Say it exactly:**

> Current proven producer surface: a single-function replacement whose every
> reference resolves inside the release's declared retention — literals, the
> receiver's own members (public, and a release-private instance **read** granted
> through G3.6b/P2), retained public app symbols, and named SDK members in the
> release's dynamic interface.

*(Updated 2026-08-13. This blockquote previously read "whose body requires no
external symbol resolution", which was accurate for 2026-08-10 and was overtaken
by A0, rung A and release 31. It is quoted verbatim by whoever reads "say it
exactly", so a stale version of it propagates further than an ordinary line.)*

The ordinary defects (1 and 2 below) are now regression tests. Finding 3 is not
a defect — it is the next feature, and `ROUTE_B.md` carries the ladder.

Three defects only hardware could find:

1. the Route B scoped refs were never registered in production — every test
   injected them, so `read` threw on the first real release, after it had
   already verified 7,109 patchable call sites;
2. source spans are code-unit offsets, not bytes — three non-ASCII characters
   put the slice 6 bytes early and `dart2bytecode` refused with exit 254 and an
   empty stderr;
3. **Probe A0 answered NO** (below).

#### Probe A0 — `dart:core` references do not resolve

The fixture's real body calls `DateTime.now()`. Delivery, identity matching and
activation were all correct, and then:

```
bytecode_reader.cc:1172: error: Unable to find function DateTime.now
                                in Library:'dart:core' Class: DateTime
```

So the supported shape is narrower than "a self-contained declaration": a body
may reference NOTHING outside itself, `dart:core` included. The 4b milestone's
hand-written body was a bare literal, and the gate passed only once the patch's
body was reduced to the same form.

#### Next session, in order

1. **Probe A0 properly**: what does the bytecode loader resolve names against,
   and what retains them? `gen_dynamic_interface.dart` retains app libraries;
   nothing retains `dart:core` members by name. A retention/interface question,
   not a producer one, and it now precedes probes A-D.
2. **Then the rest of the ladder**, on device, in order: app-symbol reference,
   public instance method (the `this`/arg0 question), `this` access, private
   references.
3. **Sealed regression** for the narrow path, which is now a complete product
   path and worth locking down before it widens.

Rig notes. `~/.shorebird` is a clone of this repo and the CLI snapshot is keyed
on its git revision, so a code change needs
`git -C ~/.shorebird checkout <rev> && rm bin/cache/shorebird.stamp`; it is
currently on branch `device-gate` at the tip. Auth is
`SHOREBIRD_TOKEN=$(docker exec cps-ios env | sed -n 's/^API_KEY=//p')` — the
OAuth refresh token has expired. Reach the CDN over `http://localhost:8085`;
the 8443 TLS cert fails Dart's verification.

### The boundary that was crossed

**Independence is proven for the supported current flows.** Parity work is now a
separate iOS code-push project, not a continuation of this one.

The sealed air-gap acceptance run **PASSED on both platforms, 2026-08-06** —
from an empty `bin/cache`, isolated caches (`PUB_CACHE`, `GRADLE_USER_HOME`,
`XDG_CACHE_HOME`, `TMPDIR`), with the mirror refusing every upstream fetch:

| Leg | Engine | Release | Patch | Stages | Isolation |
|---|---|---|---|---|---|
| iOS (macOS) | `70974f81` | `34.0.0+1` | 1 | bootstrap / ios / post-checks **PASS** | **OK** |
| Android (Linux) | `760e3fab` | `1.5.0+1` | 1 | bootstrap / android / post-checks **PASS** | **OK** |

Zero blocking refusals. Everything refused was the harness's own probe or
`android-x86`, an ABI nothing here ships. **No `aot-tools.dill` refusal on
either leg** — the assets-only iOS path really does not ask for it.

The criterion is *"nothing CLOSED is required"*, **not "no network"**. GitHub and
pub.dev stayed reachable and are reported as such. Depending on open-source
infrastructure is fine; we mirror it for durability, not because reaching it is a
failure. Do not "strengthen" this test into a no-network one — that was
considered and rejected.

Harness: [`scripts/airgap_run.sh`](scripts/airgap_run.sh) driving
[`scripts/airgap_acceptance.sh`](scripts/airgap_acceptance.sh), post-checked by
[`cdn/verify_warm.sh`](cdn/verify_warm.sh).

### Independence inventory: 7 of 10 built

Full detail in [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md), which is
the tracker of record.

| Items | Status |
|---|---|
| 1 control plane, 2 Dart fork replacement, 3 prebuilt SDK, 4 CLI, 5 bundletool, 6 `patch` differ | **Built** ✅ |
| 10 `shorebirdtech/flutter` git | **Built ✅ for CLI bootstrap** — durable private mirror at `mml555/shorebird-flutter-mirror` (1779 refs, pushed 2026-08-06), and the restore is **verified**, not plausible. ◐ engine builds still want a reachable gclient remote |
| 7 `aot-tools.dill` / the linker | **In progress** ◐ — Route B steps 1–2 work on a host harness (2026-08-09); steps 3–5 and the iOS port not started |
| 8 engine artifact set, 9 GCS artifact manifest | **Mirrored** ◐ — the next work |

### Where the project actually is (2026-08-07)

> **Infrastructure independence is complete, with one outstanding physical-iOS
> device-network verification gap. Route B is the major engineering project.**

| claim | status |
|---|---|
| iOS artifact independence | **PASS** |
| iOS release → first frame on device | **PASS** |
| iOS device → control-plane reach | **PASS** — 2026-08-09, once Local Network was granted |
| iOS assets-patch application on device | **NOT VERIFIED** |
| Android full device lifecycle (release → Dart code patch → rollback) | **PASS** |

~~The iPhone sends nothing to `cps-ios`.~~ **RESOLVED 2026-08-09 — it was the
one device setting.** With Local Network granted to *Airgap Probe*, the fixture
launched over LAN produced `POST /api/v1/patches/check -> 200` and
`POST /patches/check -> 200` within a second of launch.

Two things worth carrying forward. `prepare_ios_endpoint.sh --mode lan` now
reports `device 10.0.0.227 reachable`, so the preflight is a usable signal
rather than a formality. And the Dart beacon's `GET /selfhost-beacon/state`
answers **403** — it reaches the server, so that is authorization, not
connectivity; do not read that 403 as the old symptom returning.

**Android does not carry the iOS device claim.** They are separate claims and
merging them would manufacture a green check the iOS leg has not earned.

### Order of work — infrastructure track CLOSED 2026-08-07

Every item is done. Kept as a record of what was closed, and in what order, so
nobody re-opens a finished question.

| # | item | outcome |
|---|---|---|
| 1 | Update this file | done |
| 2 | Independence items 8 and 9 | **both cells AUDIT CLEAN** — artifacts owned per cell, manifests correct, provenance emitted from policy |
| 3 | Linux `const_finder` | **built and owned**; proven to load under the fork SDK and reject stock |
| 4 | Android default-path acceptance | **PASS** — tree-shaking on, no Gradle workaround, release → Dart code patch → rollback on device |
| 5 | Durable acceptance fixture + pub seed | committed, reproducible, harness defaults to it |
| 6 | Rig state durability | data, config and **secrets** moved behind `rig_preflight` |
| 7 | Sealed two-platform regression | **as far as it can go** — blocked only by the iOS device gap below, which is not an infrastructure task |

**The remaining project is Route B.** Its plan of record is
[`ROUTE_B.md`](ROUTE_B.md); the ten steps live there rather than here so they
stay next to the file:line pointers and the rig facts.

**Do NOT start Track C (hot restart) yet.** It adds a second runtime lifecycle
axis before Route B's core code-patch lifecycle exists. Finish basic iOS code
patching first; hot restart layers onto a proven activation/rollback model. This
is a decision, not an oversight — see [Track C](#track-c--hot-restart).

### Android DEFAULT-PATH acceptance — PASSED 2026-08-07

One run closed **#15 and the Gradle insecure-mirror workaround together**, on
CPH2551 over USB, driven by
[`scripts/accept_android_default.sh`](scripts/accept_android_default.sh).
"Default path" is the claim: **no `--no-tree-shake-icons`, no Gradle init
script, no plain-HTTP mirror.**

| step | evidence |
|---|---|
| mirror over HTTPS, CA validation **enforced** (no `-k`) | `200` from the box |
| Gradle resolved over HTTPS with **no** init script | `Flutter assets will be downloaded from https://localhost:18443`, **zero** insecure-protocol errors |
| icon tree-shaking actually **executed** | `Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 1096 bytes (99.9%)` |
| const_finder served was **ours** | sha256 `0092a3d2…` recorded from the mirror *before* the build, = our fork build, ≠ stock |
| engine in the APK was **ours** | 0 occurrences of the stock revision string, 1 `dlc.assets` marker (specific to `760e3fab`) |
| release published | `1.6.0+1` |
| first frame | `CODEPATCH-V3 patch: null` |
| Dart **code** patch, default flags | `Published Patch 1` |
| patched Dart executing | `CODEPATCH-V4-DEFAULTPATH patch: 1` |
| rollback | back to `CODEPATCH-V3 patch: null` |
| audit after | **AUDIT CLEAN**, both cells |

Caches were cleared first (engine artifacts, stamps, Gradle `modules-2`) so
neither retired workaround could be silently reused. The init script is moved
to `/data/shorebird-engine/retired/`, not deleted, so the old behavior is
recoverable.

Three things that cost time and will again:

- **`shorebird patch` has no `--artifact` flag** (that is `release`-only).
  Passing it dumps usage and exits **64 with no error line**, which reads like
  a completely different failure. It also has no `--no-confirm`, hence `yes |`.
- **`yes |` makes the exit status 141** (SIGPIPE) even on success. Read
  `PIPESTATUS`, or a passing run looks failed.
- **`adb exec-out screencap -p` is corrupt on this device** — it prepends
  `[Warning] Multiple displays were found…` into the PNG stream. Write to
  `/sdcard` and `adb pull` instead.

### Live caveats carried forward

Two things are knowingly not clean. Neither blocks the current flows; both are
real.

1. **macOS host-level packet blocking was abandoned.** Tailscale reloads pf and
   flushes any anchor, so a host seal cannot be held there. The *mirror* seal
   carries the proof instead, and it is enforced inside the container regardless
   — which is the stronger place for it anyway. Do not retry the pf route
   expecting a different result.
2. ~~**Control-plane data lives in session scratchpads.**~~ **RESOLVED
   2026-08-07** — and with it the credentials. The ownership direction is now

       durable data + durable config + durable secrets -> disposable container

   not the reverse. 1.2 GB of rig data moved to `~/shorebird-rig/control-plane/`,
   `API_KEY`/`URL_SIGNING_SECRET` extracted to `~/shorebird-rig/secrets/*.env`
   (0600), non-secret settings to `~/shorebird-rig/config/*.env`.
   [`scripts/lib/rig_container.sh`](scripts/lib/rig_container.sh) is the only
   thing that creates a control plane, and `rig_preflight` validates every
   input **before** `docker rm` — so a missing or malformed input costs
   nothing. The acceptance run refuses to start if either rig's `/data` is in a
   scratch tree or has no durable secrets file.
   See [`fixtures/CONTROL_PLANE_DATA.md`](fixtures/CONTROL_PLANE_DATA.md).
3. **Engine builds still need a reachable gclient remote.** The durable Flutter
   mirror closes CLI bootstrap, not the engine build checkout.
4. ~~**The iOS Dart checkout carries the Spike A measurement patch.**~~
   **RESOLVED 2026-08-07 — reverted, and `dart_patches.sh --verify` is green
   on all four patches.**

   What it was: `runtime/vm/compiler/aot/precompiler.cc` carried **217**
   inserted lines where `0005` accounts for 99, the surplus being Spike A's
   `--dump_global_object_pool_to` instrumentation. An earlier note placed this
   in "the `_nodm` out-dir's gen_snapshot", which understated it — the edit was
   in the **shared Dart source**, so every out-dir built from that tree would
   have picked it up, `ios_release` included.

   Two things were wrong, not one, and only the first was the spike:

   - the spike patch, reverse-applied cleanly from
     [`engine/spike/0001-dump-global-object-pool.patch`](engine/spike);
   - `0005` *still* conflicted afterwards, by exactly **two cosmetic lines** —
     an empty `//` comment terminator and one blank line that the tree had and
     the checked-in patch did not. `0005` has been re-derived from the tree;
     the added lines are byte-identical once blanks are stripped, so nothing
     semantic moved.

   **Standing rule: no Mac engine or `gen_snapshot` rebuild unless
   `dart_patches.sh --verify` is green first.** Experimental instrumentation
   does not stay resident in the production build tree after a spike closes —
   the patch file and `engine/spike/` tooling are the record, and re-applying
   is one command.

   **Follow-up, 2026-08-09: the source revert left the artifact behind.** The
   2026-08-07 revert cleaned the tree but rebuilt nothing, so
   `out/host_release_arm64_nodm/gen_snapshot` still contained the
   `dump_global_object_pool_to` flag string two days later — and `_nodm` is
   exactly the out-dir `publish_ios_overlay.sh` reads `HOST_REL` from, whose
   `dart-sdk-darwin-arm64.zip` ships `dart-sdk/bin/utils/gen_snapshot`. The
   published overlay was checked and is **clean** (its copy is dated
   2026-08-05 02:01, before the instrumented build), so nothing leaked; the
   next publish would have leaked it. Rebuilt 2026-08-09 — 65 s, 2 targets,
   flag count 1 → 0. Every other `gen_snapshot` on the tree
   (`host_release_arm64`, `host_debug_arm64`, `ios_release`,
   `ios_release/clang_x64`) was already clean.

   **Second standing rule, from that: grep the artifact, not the source.** A
   green `--verify` says the tree is right; it says nothing about binaries
   built before it went green.

## 2026-08-04, later: Android proven on our own engine; iOS engine now builds

Three results that change the picture, all verified rather than argued:

1. **Android code push is proven end to end on OUR engine**, device-verified on
   CPH2551: release `0.6.0+1` built against `fc184af6` (served from our overlay),
   patch built by our own differ, applied on device, patched Dart executing
   (`CODEPATCH-V1 patch: 1`), then rolled back to `patch: null`. Proof the engine
   was ours and not stock: the APK's `libflutter.so` carries the Route B
   patch-assets marker, which stock has **zero** occurrences of, and lacks the
   `69f9831c` revision string that stock carries. Two fixes were needed and are
   checked in: `engine_stamp.json` must be in the overlay (Flutter 3.44 fetches
   it and a 404 is fatal), and `fc184af6` must be in `experimental_hashes.map`
   (else `sky_engine.zip` 404s, because the passthrough asks upstream for *our*
   revision).
2. **Our own iOS engine builds against vanilla Dart, and is published to the
   overlay** as `70974f81…` (`engine/publish_ios_overlay.sh`) together with the
   macOS host toolchain. (`5a6b0b09…` was the first attempt and is superseded;
   both are in `experimental_hashes.map` with the reason.) The published
   `artifacts.zip` now carries the fixed `gen_snapshot`
   ([`0004`](engine/0004-dart-tearoff-selector-guard.patch)). See
   [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) item 7 for what it took.
   Two private-fork dependencies had to be closed first: the
   `shorebird_use_interpreter` GN gate, and six `print_*_table_link_*_to`
   gen_snapshot flags their flutter_tools passes unconditionally on Apple targets.
   **A release now builds against it** (release `9.0.0+1`, 2026-08-04) and the
   engine boots on device, but **no app has run to first frame yet** — see
   [§ Status: it BUILDS, it does not yet RUN](#status-it-builds-it-does-not-yet-run).
   So shipped iOS releases still run on Shorebird's prebuilt engine.
3. **An assets-only patch was invisible to devices, and now is not.** The CLI
   could publish one and the server would store it, but nothing on the device
   ever asked for it: the native updater is only offered patches carrying code
   (deliberately — it would inflate an asset archive as a binary diff and
   tombstone the patch), so it reported "no patch", and `code_push_runtime` only
   fetched a bundle when the updater named a patch. Fixed in
   `code_push_runtime`: `PatchAssetStore.discoverAssetsOnlyPatch()` asks
   `patches/check` directly with `supported_patch_kinds: ['assets']`, and
   `CodePushRuntime` now reports `assetsPatchNumber` separately from
   `patchNumber` so "no patch" and "assets patched, code original" are
   distinguishable. **This was the actual gap between "the CLI can build an iOS
   patch without their linker" and "iOS code push works".**

   **Device-verified 2026-08-04** on iPhone9,1 / iOS 15.8.8, over the USB link:
   release `5.0.0+1` on Shorebird's prebuilt engine rendered
   `code patch: none` / `assets patch: 1` with the patched asset served, and the
   server log shows the whole chain — `POST /api/v1/patches/check` (the native
   updater, correctly offered nothing), `POST /patches/check` (our new discovery
   call), `POST /patches/assets`, then the bundle download. `code patch: none`
   beside `assets patch: 1` is the load-bearing detail: it proves the asset
   arrived through app-side discovery and not through the updater. Before this
   fix the same screen read `BAKED-INTO-RELEASE`.

   Useful tooling note: **`idevicescreenshot` works on iOS 15 with no extra
   setup**, so an on-device result can be captured rather than described. It is
   the only way to see a Flutter screen — Flutter draws to a canvas, so nothing
   in the view hierarchy or `dumpsys`-style output contains the text.

   Also fixed while proving it: **`--assets-only` now implies
   `--allow-asset-diffs`** (`commands/patch/patcher.dart`). The diff checker was
   warning "your app contains asset changes, which will not be included in the
   patch" on the one kind of patch whose entire payload *is* asset changes — a
   statement that is both false and self-contradictory. Worse than cosmetic: the
   warning ends in a `Continue anyway?` prompt, which has no answer under
   `--no-confirm` or in CI, so `--assets-only` failed outright unless
   `--allow-asset-diffs` was passed alongside it. Three tests cover it.

   Still open on the same theme: the CLI **downloads `aot-tools.dill` even for
   `--assets-only`**, during cache warm-up, and a download failure is fatal
   (`CacheUpdateFailure`) despite the artifact being declared `required => false`.
   It is never invoked — the build runs `gen_snapshot` for the diff check and no
   linker — but it still has to be fetchable, so an assets-only iOS patch is not
   yet fully independent of upstream at *cache* level even though it is at *use*
   level.

4. ~~**iOS on OUR engine does not work yet, and the reason is our Dart fork's base
   revision.**~~ **Superseded — read [§ Root cause, found](#root-cause-found-2026-08-04-late) below
   before anything else in this item.** The base revision was never the problem,
   the two "bugs" were one bug, and it is fixed. The text below is kept only
   because the elimination log refers to it.

   Two bugs found, both in the
   implicit-accessor-synthesized-from-a-Field path:

   - **Bug #1 (fixed):** `ReadParameterCovariance` (`runtime/vm/kernel.cc`) calls
     `ReadUntilFunctionNode` with no kind check. An implicit accessor's
     `kernel_offset` points at the **Field** node, so it aborts with the opaque
     `Unexpected tag 4 (Field)`. Every other caller guards this — the kind switch
     in `kernel_binary_flowgraph.cc`, the `PeekTag() == kField` branch in
     `scope_builder.cc` — this one did not. Fix + a much better
     `ReportUnexpectedTag` diagnostic are in
     [`engine/0003-dart-kernel-reader-fixes.patch`](engine/0003-dart-kernel-reader-fixes.patch).
     It needs a `final` field in a reachable package (for us `package:yaml`'s
     `YamlDocument.span`), which is exactly why `dart compile aot-snapshot` on
     hello-world succeeded while every Flutter release failed, and why Android
     never tripped it.
   - **Bug #2 (open):** with #1 fixed the compile gets further and SEGVs.
     A **debug** `gen_snapshot` (`out/host_debug_arm64/gen_snapshot`) is what makes
     this diagnosable at all — the release build prints one `si_addr` line and no
     stack. Trace: `Class::HasCompressedPointers()` ← `Slot::Get(const Field&,
     const ParsedFunction*)` ← `CallSpecializer::InlineImplicitInstanceGetter` ←
     `CompilerPass_ApplyClassIds`. A garbage owner `Class` while inlining an
     implicit instance getter.

   ~~**Two bugs in one narrow path is a tree problem.** Rebase onto the public
   vanilla tag `3.12.2` (`704629bc…`).~~ **Wrong on both counts — see below.**

## Root cause, found (2026-08-04, late)

**One bug, not two, and not in our base revision. Fixed in one line:**
[`engine/0004-dart-tearoff-selector-guard.patch`](engine/0004-dart-tearoff-selector-guard.patch).

**Do not do the rebase.** `refs/tags/3.12.2` is an *annotated* tag: `704629bc` is
the tag object and its target commit is `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`
— the commit our fork is already based on. `git ls-remote` shows no `^{}` peel
line for this tag (it does for `3.12.0`), which is what made one commit look like
two. `tools/VERSION` there reads `CHANNEL stable / 3.12.2 / PRERELEASE 0`, and
Shorebird's `DEPS` names the same SHA as `dart_revision`. Our Dart is vanilla
stable 3.12.2 plus the 57-line shim. A fresh clone would have produced a
byte-identical tree — a day for nothing.

### What was actually wrong

`dispatch_table_generator.cc:590`. A table selector is shared by every member with
the same name, so a **getter** selector is marked `torn_off` as soon as *any*
method of that name is torn off anywhere in the program. For a field's implicit
getter that path then runs

```
GetMethodExtractor(get:get:foo)
  → Function::ImplicitClosureFunction()
    → set_implicit_closure_function()
```

and `set_implicit_closure_function` **overwrites the accessor's `data_` slot —
which holds its `Field` — with the closure.** `object.cc:8762` asserts exactly
that this is illegal (`ASSERT(old_data.IsNull() || value.IsNull())`), but
`gen_snapshot` ships `-DNDEBUG`, so the assert is compiled out and the corruption
is silent. 349 members were hit in one app, 598 of them implicit getters.

Both "bugs" were that one event surfacing at different distances from it:

- "Unexpected tag 4 (Field)" — `ImplicitClosureFunction()` calls
  `ReadParameterCovariance` (`object.cc:11079`), whose `kernel_offset` for an
  implicit accessor points at the **Field** node.
- The SEGV — afterwards `accessor_field()` returns a `Function` (cid 7) where a
  `Field` (cid 11) is expected, so `Field::Owner()` reads garbage.

The fix skips the tear-off block for `IsImplicitGetterOrSetter()`. **Keep it that
narrow.** The first version guarded on `IsRegularFunction()` instead, which also
compiles and produces a working snapshot for `gen_snapshot`, but drops legitimate
tear-off entries for real getters/setters and method extractors — 349 sites in one
app. Both guards behave identically at runtime for the app below, so the broad one
was not what broke it, but there is no reason to carry the extra blast radius.

### Status: it BUILDS, it does not yet RUN

`shorebird release ios` completes on our own engine — first time ever. Verified on
release `9.0.0+1`, engine `70974f81…`:

- the `Flutter.framework` inside the IPA is **byte-identical** to
  `out/ios_release/.../Flutter` (compare bytes 1 MB–14 MB; the header and
  `__LINKEDIT` differ because Xcode re-signs);
- on device, our engine boots, loads `App.framework`, and **the Shorebird updater
  talks to our control plane**: `Sending patch check request … release_version:
  "9.0.0+1"` → `PatchCheckResponse { patch_available: false }` → `Reporting
  successful launch`.

Then it aborts before Dart user code runs:

```
[FATAL:flutter/lib/io/dart_io.cc(31)] Check failed: !CheckAndHandleError(locale_closure).
Unhandled exception:
#0 Object.noSuchMethod        (dart:core-patch/object_patch.dart:38)
#1 _objectNoSuchMethod        (dart:core-patch/object_patch.dart:88)
#2 new Map._fromLiteral       (dart:core-patch/map_patch.dart:19)
#3 new PlatformDispatcher._   (dart:ui/platform_dispatcher.dart:186)
#4 PlatformDispatcher._instance
#5 _getLocaleClosure          (dart:ui/hooks.dart)
```

`map_patch.dart:19` is `var map = LinkedHashMap<K, V>();` — constructing a plain
map literal fails dynamic dispatch. In AOT a missing dispatch-table entry lands on
the no-such-method stub, so **the dispatch table is the prime suspect**, but this
is *not* our guard's doing: the broad and narrow guards fail identically, and
Android already runs on our engine with the same vanilla `gen_snapshot`.

What is ruled out:

- **`dart_dynamic_modules`.** Built and ran both ways; identical failure. The
  invariant below that blames a dm mismatch for "Unexpected tag 4 (Field)" is
  **wrong** — a dm=true `gen_snapshot` consumes a dm=false frontend_server's dill
  without complaint, and the real cause of that error is the tear-off bug above.
- **Our frontend_server / platform dill / the kernel.** Stock `gen_snapshot`
  compiles our `app.dill` end to end (951 k lines of assembly).
- **The app, device, server and USB link.** All verified working on the stock
  engine, and the updater round-trip above happens on ours.
- **Swapping the stock `Flutter.framework` under our snapshot** to isolate
  engine-vs-snapshot. Impossible by construction: `Wrong full snapshot version,
  expected '839937ddd…' found '8889ac395…'`. That is invariant #1 doing its job.

Next diagnostics, in order of expected value:

#### RESOLVED 2026-08-05 — iOS code push runs end to end on our own engine

Device-verified on iPhone9,1 / iOS 15.8.8, engine `70974f81…`, release
`27.0.0+1`, patch `1`:

```
status: ok
code patch: none
assets patch: 1
assets/probe.json via PatchAssetBundle: {"origin":"PATCHED-ON-OUR-OWN-ENGINE"}
```

Release built on our engine → app runs to first frame → patch built by our CLI
with **no AOT linker** → served by our control plane → applied on device →
patched asset rendered. Server log shows the whole chain:
`POST /api/v1/patches/check` (native updater) → `POST /patches/check` (our
Dart-side discovery) → `POST /patches/assets` → `GET /download/…`. The shipped
`Flutter.framework` is byte-identical to `out/ios_release`'s and differs from
stock. No engine or SDK diagnostics are in the shipped artifacts.

**Four fixes, one theme.** The dill's TFA metadata — `call_count`, `torn_off`,
`has_tearoff_uses` — is a **lower bound** in our pipeline, and vanilla's AOT
compiler treats it as exact. Where that costs a dispatch-table row the call
becomes unresolvable at runtime, because AOT product snapshots carry no
`Class::functions()` for a name lookup to fall back on.

| # | Patch | Fix |
|---|---|---|
| 1 | [`0004`](engine/0004-dart-tearoff-selector-guard.patch) | Never closurize an implicit accessor — it overwrites the accessor's `Field` pointer |
| 2 | [`0004`](engine/0004-dart-tearoff-selector-guard.patch) | Drop the `IsUsed()` (`call_count > 0`) gate on selector rows |
| 3 | [`0004`](engine/0004-dart-tearoff-selector-guard.patch) + [`0005`](engine/0005-dart-precompiler-link-info-and-tearoffs.patch) | Build method extractors for **regular methods only**, ignoring `torn_off` / `has_tearoff_uses` |
| 4 | [`0006`](engine/0006-dart-no-dispatch-call-for-hash-slots.patch) | Never dispatch-call the `_HashVMBase` graph-intrinsic slot accessors |

Snapshot size cost: **+1.5 %**.

Two of these were self-inflicted and are worth remembering as *rules*, not
anecdotes:

- **Only a regular method can be torn off.** Letting getters and setters into
  the extractor path corrupts the table, because a setter's
  `getter_selector_id` names its *field's* getter — so the extractor for
  `set:_data` was written into `get:_data`'s row and `_table._data` started
  returning a fresh `(List<dynamic>) => void` closure on every read. That
  surfaced as a bogus `ConcurrentModificationError`, which is nothing like its
  cause. `tearoff_sid != sid` does **not** catch it: the two selectors really
  are different.
- **Don't exclude *all* recognized methods** from dispatch-table calls to fix
  the above — `_Array.[]` and `_Array.get:length` are recognized and do have
  bodies, and dropping their rows brings back the `Map._fromLiteral`
  `NoSuchMethodError`. Only the bodyless graph-intrinsic slot accessors must be
  excluded.

The underlying question — *why* TFA under-reports — is still open and still
lives in `pkg/vm/lib/transformations/type_flow/`. These four are compensations
that make the pipeline correct; a proper fix would let most of them be deleted.

##### Decision (2026-08-05): ship on these four; TFA is a separate project

**Do not block shipping on the `type_flow` root cause.** The engine is clean,
device-verified, and the size cost is 1.5 %. The architectural conclusion is
settled and should not be re-argued:

> TFA metadata is advisory / lower-bound data in this pipeline, but vanilla AOT
> relies on it as complete when constructing dispatch and tear-off behavior.

The four patches restore correctness at the compiler boundary, each on a
language-semantics rule rather than on metadata:

1. Protect implicit accessors from illegal closurization.
2. Preserve selector rows even when TFA reports zero use.
3. Generate extractors from language semantics — regular methods only — not
   from incomplete tear-off flags.
4. Exclude only bodyless graph-intrinsic accessors from dispatch calls.

The TFA work is its own compiler-correctness project with one success criterion:

> Explain why `call_count`, `torn_off` and `has_tearoff_uses` omit uses that are
> introduced or required downstream, then determine which compensating patches
> can safely be removed.

**These patches stay until a replacement passes the same bar**: clean rebuild
(no diagnostics in any shipped artifact), app to first frame, and an on-device
patch round-trip.

##### Root cause (2026-08-05): located, not yet fixed

Written up in full in [`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md); tooling kept in
[`engine/tools/`](engine/tools/). The headline:

**We pair Shorebird's forked `frontend_server` with our vanilla `gen_snapshot`,
and the two disagree about `vm.table-selector.metadata`.** TFA is not
under-reporting, and `frontend_server` as a *mode* is not at fault. Holding the
mode fixed and swapping only the frontend binary — same app, same platform dill,
same `flutter_tools` release argument list:

| frontend | `List.get:length` | `List.[]` | selectors | `call_count > 0` | records with `flags > 3` |
|---|---|---|---|---|---|
| stock (Shorebird fork) | **0** | **0** | 13641 | 1696 | **1023** |
| ours (vanilla + patches) | **200** | **413** | 13641 | 869 | **0** |

Both assign the same 13641 selector IDs; only the payload differs. Vanilla's own
binary layout fits the stock table better than any of six alternatives, so this
is not a misparse — the stock table genuinely carries 85 `call_count`s that
cannot be counts, 1023 records setting flag bits vanilla does not define, and
zero for hot core selectors. Their snapshot also exports
`TableSelectorAssigner._getSelectorHash`, which does not exist in vanilla.

**The fix is a frontend swap, not a compiler change.** We already build the
frontend that produces the clean column and simply do not ship it;
`bin/internal/update_dart_sdk.sh:131` fetches `dart-sdk-<host>.zip` from
`$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/flutter/<engine hash>/`, the
path the overlay CDN already intercepts.

**Done, 2026-08-05 — patches 2 and 3a are retired.** With our own frontend
installed, both platforms pass the full bar on device: clean rebuild, release
(iOS `29.0.0+1`, Android `0.7.0+1`), first frame, patch applied (assets on iOS,
**code** on Android), rollback. `0004` and `0005` are regenerated; the `IsUsed()`,
`torn_off` and `has_tearoff_uses` gates are all back to upstream.

What stays is not metadata-shaped at all: `IsRegularFunction()` and
`tearoff_sid != sid` in `0004`, and `0006`. A separate bug in *vanilla* is why
the first of those is load-bearing — `TableSelectorAssigner._selectorIdForMember`
returns the getter's selector id when asked for a setter's, because
`_getterMemberIds` is keyed by Kernel `Name`, which does not distinguish setters.

**The CLI now enforces the pairing.** `dart_sdk_compatibility.dart` compares
`bin/cache/dart-sdk/revision` against the engine in `bin/internal/engine.version`
and fails with the remediation before invoking Flutter, on both the release and
patch paths. It has to be an identity check rather than a probe: a mismatched
frontend/backend pair compiles cleanly and only fails on the device, so "it
built" proves nothing. Add a row to `expectedDartSdkRevisions` whenever a new
engine hash is published.

**Android was never fork-mixed**: the box's Flutter cache already carried our
`dart-sdk` (`4bd36869`), because it was bootstrapped with `engine.version`
already pointing at our hash. Only the Mac was mixed, and only because its cache
predates the overlay. Three traps sit between "published to the overlay" and
"actually used" — `update_dart_sdk.sh` is gated on the flutter-tool stamp, the
Shorebird CLI snapshot is version-locked to the Dart SDK, and `const_finder` is
version-locked to the frontend. All three are written up in
[`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md).

##### Test results attached to this work (2026-08-05)

`cd packages && very_good test -r`, then each failing package re-run standalone:

| Package | Result |
|---|---|
| `shorebird_cli` | **2164 passed, 1 skipped** (includes 6 new `DdSupport` tests) |
| `code_push_runtime`, `code_push_server`, `shorebird_code_push_client`, `shorebird_code_push_protocol`, `artifact_proxy`, `dex`, `jwt`, `scoped_deps`, `shorebird_ci`, `stripe_api`, `discord_gcp_alerts`, `flutter_version_resolver` | passed |
| `shorebird_build_trace` | 3 failures under `very_good test -r`, **48/48 pass standalone** — those tests spawn real subprocesses and assert on OS pids, so they are flaky under parallel package execution, not broken |
| `redis_client` | 6 failures — needs a live Redis, none running. Environmental |

`currentRunLogFile creates a log file in the logs directory` also failed only in
the parallel run and passes standalone. **So: no real failures.** If you want a
green single command, `redis_client` needs a Redis container and
`shorebird_build_trace` wants to run outside the parallel sweep.

##### The `--dd-max-bytes` footgun is gone

The CLI now decides this itself, by probing the **capability** rather than trying
to recognize a particular engine revision (so it keeps working for engines that
do not exist yet). `DdSupport.isSupportedBy` runs the cached `gen_snapshot` with
`--print_dd_function_identity_to=/dev/null --version`; the VM parses flags,
prints, and exits before compiling anything, so it costs one short-lived process
and writes nothing. A vanilla-Dart `gen_snapshot` exits non-zero, and
`Releaser.ddMaxBytes` then returns null — the release builds exactly as if
`--dd-max-bytes=0` had been passed, with the reason at `--verbose`.

- `lib/src/dd_support.dart`, wired into `Releaser.ddMaxBytes`.
- Only Apple releasers opt in, via `ddGenSnapshotArtifact` on
  `AppleReleaserMixin` (macOS overrides it with its own `gen_snapshot`).
  Flutter gates the DD pass on `usesLinker`, which is Apple-only.
- On any uncertainty — artifact path unresolvable, probe throws — it assumes
  **supported**, so behavior on stock engines is unchanged and we never silently
  turn DD off for the wrong reason.

##### Recreating the Dart checkout is now reproducible

[`engine/dart_patches.sh`](engine/dart_patches.sh) pins the base commit and owns
the series (`0001`, `0004`, `0005`, `0006`, `0008` — `0002` is the flutter tree,
`0003` is diagnostic-only). **Since `0008` (2026-08-14) the ORDER is load-bearing
rather than conventional:** it is the first Dart patch to touch a file another
patch already touches (`0005` also edits `runtime/vm/compiler/aot/precompiler.cc`),
so `0008` must be applied after `0005`, and an edit landing adjacent to `0005`'s
hunk context makes `0005` report `[CONFLICT]` even though nothing is wrong with
`0005`. Note the "four patches" wording elsewhere in this file refers to the TFA
**correctness** set (`0001`/`0004`/`0005`/`0006`) and is still accurate — `0008`
is a capability, not a TFA compensation:

```bash
selfhost/engine/dart_patches.sh --dest <dart-checkout> --verify   # default
selfhost/engine/dart_patches.sh --dest <dart-checkout> --apply
```

`--verify` checks actual file contents (`git apply --reverse --check`), so it
catches a missing hunk, and distinguishes *not applied* from *does not apply —
re-derive it*. It exits non-zero with a message saying an engine built from that
checkout is not the one the device proofs were made against. Run it before
trusting any rebuilt engine.

Note `gclient sync --no-history` leaves the tree shallow, so the pinned commit
is usually absent as an object even when the tree is right; the script downgrades
that to a warning and relies on the content checks. On a full clone it enforces
the base.

Verified in both directions on both hosts: the Mac's build tree reports all four
applied; the dart-fork source repo correctly reported three missing.

##### Before this ships to anyone but us

Not blockers on the engine, but real:

- ~~**`--dd-max-bytes=0` is mandatory**~~ — **fixed**, see above.
- **Android has not been re-verified against this compiler.** The four patches
  live in the shared Dart tree, so they change `gen_snapshot` for *every*
  target. The Android proof (`fc184af6`, release + patch + rollback on CPH2551)
  was produced by the **pre-fix** compiler. That engine hash is unchanged and
  keeps working, so nothing is broken today; the exposure is the *next* Android
  engine rebuild, which silently picks up all four changes.

  **RESOLVED 2026-08-05 — Android round-trip passes on the rebuilt compiler.**
  Engine `760e3fab` unchanged (already device-verified 2026-07-31); the only
  variable was the rebuilt host `gen_snapshot`. On CPH2551:

  | step | screen |
  |---|---|
  | release install | `CODEPATCH-V1 patch: null` |
  | patch apply | `CODEPATCH-V2 patch: 1` |
  | rollback | `CODEPATCH-V1 patch: null` |

  Server logged the whole chain on a **separate** Android instance
  (`cps-android`, port 18081) — `patches/check`, `__patch_install__` with
  `patch_number: 1`, then `withdraw?rollback=true`. The iOS rig on 18080 was
  never touched. Engine identity inside the APK confirmed by marker rather than
  hash (AGP strips the packaged `.so`): `dlc.assets` ×1 and `vmcode` ×2 are
  specific to `760e3fab`, and the stock `69f9831c` revision string is absent.

  Three setup facts worth keeping:

  - **Gradle 8+ refuses insecure Maven repos**, and Flutter's gradle plugin
    declares the repo itself, so the opt-in cannot live in the app. The mirror's
    HTTPS listener normally solves this, but it is down mid-migration to Caddy.
    Worked around with a **localhost-scoped** init script at
    `/data/gradle-home/init.d/selfhost-allow-insecure-mirror.gradle` — it can
    never loosen a real remote repo. Remove it once HTTPS is back.
  - **`760e3fab` is now self-contained.** The Jul 31 publish deliberately reused
    the host toolchain from the previous hash, so its overlay had no
    `flutter_patched_sdk.zip`; clearing `artifacts/engine/common` on the box
    turned that into a hard 404. Published ours from
    `out/host_debug/flutter_patched_sdk`. Never substitute upstream's copy.
  - The fresh server has no apps, and app ids are **server-generated**
    (`POST /api/v1/apps` ignores a requested id), so `rbtest`'s
    `shorebird.yaml` was repointed at a new id and `base_url` moved to 18081.
    Backup alongside it.

  **2026-08-05 earlier: the compiler change does NOT touch the Android engine
  binary.** Rebuilt `android_release_arm64` on the VPS after applying the patch
  series. ninja rebuilt **10 objects in 85 seconds** — all compiler-side — and
  the outputs say the rest plainly:

  | artifact | result |
  |---|---|
  | `artifacts.zip` (device engine), `symbols.zip` | **not rebuilt** (mtimes unchanged) |
  | `linux-x64.zip` (host `gen_snapshot`) | rebuilt |

  `libflutter.so` was never relinked, so `0004`/`0005`/`0006` are isolated to
  the AOT compiler on Android exactly as they are on iOS. What still needs
  device proof is therefore *apps compiled by the new `gen_snapshot`*, not a new
  engine.

  Also caught, and the reason `dart_patches.sh` earned its keep on day one: the
  VPS **build tree** (`src/flutter/engine/src/flutter/third_party/dart`) was
  unpatched — only the *fork source* at `src/dart-sdk` had been patched. Two
  different checkouts, one of which is what actually gets compiled. `--verify`
  found it in seconds; without it the rebuild would have silently produced the
  old compiler and "verified" nothing.

  **`fc184af6` is NOT the current Android engine — this section used to imply it
  was, and that is what made the Jul 31 rebuild look like a discrepancy.**
  `compatibility.yaml` has the real chain:

  | hash | is | device_verified |
  |---|---|---|
  | `fc184af6` | Route B asset resolver | ✅ 2026-07-30 |
  | `5b1a8965` | `fc184af6` + the `PatchCarriesCode()` guard | ✗ |
  | **`760e3fab`** | `5b1a8965` + the Rust updater's assets-patch support | ✅ **2026-07-31** |

  `760e3fab` is the current one and it is already device-verified on physical
  Android arm64: a patch with no code artifact at all was installed as
  `dlc.assets` and the app booted with it active. Build non-determinism is ruled
  out — two clean builds were proven byte-identical that day (blast radius 1 of
  7,366 objects), which is what makes the content-addressed naming meaningful.

  The VPS tree is exactly that source state, confirmed two ways: its
  `artifacts.zip` is **byte-identical** to the published `760e3fab` copy
  (`ecdcb458…`), and its `libflutter.so` sha256 begins
  `760e3fabffbf31b4e86919a0ef47d6ce5f182991` — the hash *is* the content.

  So the compiler change is cleanly isolable on Android: republish **only** the
  rebuilt `linux-x64.zip` under the unchanged `760e3fab`, exactly as iOS
  republished a new `gen_snapshot` under an unchanged `70974f81`. One variable.

  **Still to do for the device proof.** The build box's Dart tree is now patched and verified
  (`dart_patches.sh --dest /data/shorebird-engine/src/dart-sdk --verify` → all
  four applied on the pinned base), and CPH2551 is attached to the Mac over USB,
  so the device half is ready. What remains is the build itself, and it is not a
  quick job:

  - `20.120.104.70` has **4 cores**, and its `out/` directories are gone. Disk
    is no longer the constraint — the media archive was removed on 2026-08-05,
    so `/data` has **378 GB free** and `/mnt/spare` **195 GB**. Cores are: a
    full `android_release_arm64` build there is multi-hour on 4 of them. Run it
    detached (`screen -dmS … caffeinate -is …`), never as a harness background
    task. The Mac is ~2.5× faster if you accept the `gclient sync` hazard below.
  - Then: publish to the overlay under the new hash, add it to
    `experimental_hashes.map`, and run the same round-trip the original proof
    used — **release install → patch apply → rollback**, on the physical device,
    with `adb reverse tcp:18080 tcp:18080`.

  **Hazard if you build Android on the Mac instead** (10 cores and 371 GB free
  make it the better host, but its checkout has `android_tools/sdk` and **no
  NDK**, so it needs `target_os = ['android']` in `.gclient` plus a
  `gclient sync`): that sync resets `engine/src/flutter/third_party/dart` to the
  pinned fork commit `6b58bb3a` and therefore **silently discards `0004`,
  `0005` and `0006`**. `managed: False` protects the *flutter* checkout's git
  state, not the DEPS-managed subtrees. Recovery is one command now —
  `dart_patches.sh --dest … --apply` — and `--verify` is what catches it before
  you waste a build. Run verify after any `gclient sync`, always.
  - Until that passes, treat Android on a *rebuilt* engine as unverified. The
    existing `fc184af6` artifact stays valid on its own terms.
- The CLI still fetches `aot-tools.dill` during cache warm-up for
  `--assets-only`, so an iOS patch is independent at *use* level but not at
  *cache* level.
- ~~Leaked dev secrets~~ — **rotated 2026-08-05.** Both bootstrap credentials of
  the local `code_push_server` instances (`API_KEY` and `URL_SIGNING_SECRET`,
  each `openssl rand -hex 32` per `setup.sh`) had been echoed into session
  transcripts. Both were regenerated and `cps-ios` (:18080) and `cps-android`
  (:18081) recreated with the new values, data volumes preserved. Verified: the
  old key now returns **403**, the new key **200** on both, and the app records
  survived. The dead key was also scrubbed from the build box's
  `release_android_verify.sh` / `patch_android_verify.sh`, which now require
  `SHOREBIRD_TOKEN` from the environment rather than baking it in. Neither old
  value appears anywhere in the repo.

  These are dev-only bootstrap credentials for local instances; there is no
  production deployment holding them. If you ever stand one up, `setup.sh`
  generates fresh values and the published placeholders are rejected at startup.
- The engine patches, the `code_push_runtime` assets-only work and these docs
  are committed as `c4b708a4` on `feat/engine-improvements`. The Dart tree
  itself is **not** in git — reapply `0004`/`0005`/`0006` (and the `0002` GN
  bits) to `engine/src/flutter/third_party/dart` if that checkout is ever
  recreated.

#### How it got there (2026-08-05, ~02:00)

Startup now gets **much** further. Verified on release `18.0.0+1`:

| stage | before | now |
|---|---|---|
| `gen_snapshot` compiles the app | ✅ | ✅ |
| Dart isolate starts | ✗ abort in `DartIO::InitForIsolate` | ✅ |
| `main()` entered | ✗ | ✅ beacon `01` |
| `WidgetsFlutterBinding` ready | ✗ | ✅ beacon `02` |
| `runApp()` called | ✗ | ✅ beacon `03` |
| `CodePushRuntime.initialize` returns | ✗ | ✅ beacon `04` |
| first frame painted | ✗ | ✅ (see RESOLVED above) |

**The one remaining blocker** is a *spurious* `ConcurrentModificationError`:

```
Concurrent modification during iteration: _Map len:9
#0 _CompactEntriesIterator.moveNext (dart:_compact_hash:919)
```

thrown during the first widget build, and again (len:1) twice more. Nothing is
actually modifying the map — `_CompactIterator.moveNext` compares its captured
`_modificationCount` against `_map._modificationCount` and sees a mismatch that
should not exist, which is the signature of a field read landing on the wrong
slot. It does **not** reproduce in a plain Dart program: an equivalent
map-iteration test compiled by the *current* `gen_snapshot_product` and run under
`dartaotruntime` iterates keys/entries/values/`forEach` correctly
(`scratchpad/hosttest/iter.dart`). So it is specific to the Flutter dill.

Two techniques made this visible and are worth keeping:

- **Beacons.** App stderr is unreadable on this rig, but the control-plane log is
  not. `GET http://<host>/selfhost-beacon/<stage>` from Dart turns the server log
  into a progress trace; a 403/404 in the log is a success. This is what proved
  `main()` runs.
- **App-side error capture.** Flutter's own `FlutterError.reportError` runs the
  stack through `defaultStackFilter`, which on this engine dies with the same
  bogus `ConcurrentModificationError` and takes the real error with it. Setting
  `FlutterError.onError` in the app and beaconing
  `details.exceptionAsString()` is what surfaced the message at all.

Also worth knowing: `ios-deploy`'s lldb console only flushes the app's output
**when the process crashes**. A clean-running app looks completely silent. To read
anything from a non-crashing app, either beacon it out or make the failure fatal
(`FML_CHECK`) so the console flushes and a `.ips` crash report is written.

#### Traced to its mechanism

Chased with a VM diagnostic in `NoSuchMethodFromCallStub`. (`runtime_entry.cc` is
**not** in `VM_SNAPSHOT_FILES`, so it can be instrumented and the framework
hot-swapped into an already-signed bundle without invalidating the snapshot.)

```
SELFHOST NSM: target='get:length' receiver_class='_ImmutableList' cid=91
SELFHOST NSM: target='[]'         receiver_class='_ImmutableList' cid=91
  chain cid=91   _ImmutableList                              functions=0
  chain cid=2464 __ImmutableList&_Array&UnmodifiableListMixin functions=0
  chain cid=2463 _Array                                      functions=0
  chain cid=45   Object                                      functions=6
```

Those two are the `elements.length` and `elements[i]` in `Map._fromLiteral`.
Empty `functions()` arrays are **normal** in AOT — name lookup is not supposed to
be needed. The call reached a name lookup because the compiler never gave it a
dispatch-table entry:

```
SELFHOST SEL:  dart:core_List_get_length      sid=5195 call_count=0 offset=-1
SELFHOST CALL: iface=dart:core_List_get_length sid=-1  offset=-1 null=1
SELFHOST SELTOTAL: selectors=13675 with_calls=1695 torn_off=597
```

`GetSelector()` returns null when `call_count == 0`, and
`AotCallSpecializer::TryReplaceWithDispatchTableCall` then leaves the call alone.
Its own `#if defined(DEBUG)` branch says why: *"Target functions were removed by
tree shaking. This call is dead code, or the receiver is always null."*
**The compiler concluded this call can never execute. It executes.**

Full chain: our dill's TFA table-selector metadata reports zero call sites for
`get:length` / `[]` → no dispatch-table entry → the call survives as a switchable
call → at runtime the receiver is an `_ImmutableList` (the *const* element list
the VM's `BuildMapLiteral` passes when every entry is constant) → AOT cannot
resolve by name → `NoSuchMethodError`. The metadata is not globally empty (1695
of 13675 selectors do have calls), so this is specific, not wholesale.

Ruled out along the way:

- **Our `gen_snapshot`, and the assembly path in general.** A plain Dart program
  with map literals, compiled by our `gen_snapshot_product` as **both**
  `app-aot-elf` and `app-aot-assembly` (the latter assembled with clang into a
  dylib and run under our `dartaotruntime`), prints the right answer. Recipe in
  `scratchpad/hosttest/`; rebuild it, it is a seconds-long loop. Note the
  `host_debug_arm64` `gen_snapshot` cannot be used for this — its output trips
  `Flag dedup_instructions is false in snapshot` in a product runtime.
- **Our precompiler patch.** The link-info stub loop is a pure insertion before
  `ClassFinalizer::SortClasses()`; control flow around class-id sorting is
  untouched (`precompiler.cc` ~line 549).
- **The tear-off guard.** `_Array.get:length` is a plain `GetterFunction`, which
  the narrow guard never touches, and broad and narrow fail alike.

Next diagnostics, in order of expected value:

1. ~~**Why does TFA report `call_count == 0` for these selectors?**~~
   **Answered 2026-08-05 — see [`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md).** Not
   the entry-point-pragma theory guessed here: `Map._fromLiteral`'s body *is*
   analyzed and the two call sites *are* left virtual. The table is written by
   Shorebird's forked frontend and read by our vanilla backend, and the two
   disagree about what the fields mean.
2. ~~**Compare against a dill from the stock frontend_server.**~~ **Run
   2026-08-05** via [`engine/tools/fe_ab.sh`](engine/tools/fe_ab.sh) — that is
   the experiment the answer above rests on.
3. Stock's snapshot of our dill is **44 % larger** (951 k vs 662 k lines of
   assembly), so their fork very likely retains far more and would mask exactly
   this class of bug. Worth confirming — it means "stock compiles it" is *not*
   evidence that a dill is sound, which weakens the cross-test used above.

Trap found while attempting #2: **Shorebird's published host artifacts for the
pinned revision are internally inconsistent.** `dart-sdk-darwin-arm64.zip`
(`dart-sdk/revision` = `db98bdaa`) carries a `dartaotruntime` expecting snapshot
version `839937ddd…`, while the `frontend_server_aot.dart.snapshot` in the same
revision's `darwin-arm64/artifacts.zip` reports `ace654289…` — so running their
frontend_server under their `dartaotruntime` fails immediately with `Wrong full
snapshot version`. Whatever `flutter` does to run frontend_server, it is not that
pairing; work out what before retrying.

Reproducing takes ~10 min: `release_ios_ourengine.sh`-style build, then
`ios-deploy --bundle Payload/Runner.app --noinstall --debug` for the console.
**Use `--export-method development`** — an ad-hoc IPA has `get-task-allow: false`
and lldb cannot attach, which is the difference between a stack trace and a white
screen. And note the engine hash is sha1 of the **Flutter binary only**, so a
`gen_snapshot`-only change republishes under the same hash: delete
`bin/cache/engine.stamp`, `engine_stamp.stamp` and
`bin/cache/artifacts/engine/ios-release` or the build silently reuses the old
compiler.

A trick worth reusing: to test an engine change without a full release cycle,
rebuild just `Flutter.framework`, copy the binary into an existing
`Payload/Runner.app/Frameworks/Flutter.framework/`, re-sign each framework and
then the app with `codesign -f -s <identity> --entitlements <extracted>`, and
reinstall. ~3 minutes instead of ~15. Safe as long as the change does not touch
`VM_SNAPSHOT_FILES`. Also: `FML_CHECK`'s own message is lost to `abort()` on iOS —
log the condition with `FML_LOG(ERROR)` first or you will see the check fire with
no reason attached.

**The bug-#1 patch is retired.** With the guard in place, reverse-applying
`0003` changes nothing: same exit 0, and the two snapshots differ only in the 20
lines encoding `gen_snapshot`'s own build hash. `0003` is now diagnostic-only.
That also retires the carried gap about it mis-reporting covariance for a
covariant field's implicit setter.

### The fast loop that found it (use this)

No Xcode, no device, no server. **0.24 s to reproduce, ~80 s per rebuild:**

```bash
GS=/Volumes/build/ios-engine/flutter/engine/src/out/host_debug_arm64/gen_snapshot
$GS --deterministic --snapshot_kind=app-aot-assembly --assembly=/tmp/out.S app.dill
# rebuild after an edit:
ninja -C /Volumes/build/ios-engine/flutter/engine/src/out/host_debug_arm64 -j8 gen_snapshot
```

`app.dill` is any Flutter app's, from `.dart_tool/flutter_build/*/app.dill`.
`out/host_debug_arm64` prints a full stack and the crashing function's CFG; note
it is `is_debug=false` / `dart_runtime_mode=develop`, so **`ASSERT` is compiled
out there too** — that is why the illegal write went unseen. When a VM invariant
is suspect, turn the relevant `ASSERT` into an `OS::PrintErr` +
`Profiler::DumpStackTrace(false)` rather than trusting that asserts would have
caught it.

The decisive experiment was cheaper than any of it: run **stock**
`gen_snapshot_arm64` (from Shorebird's `ios-release/artifacts.zip`) on *our*
`app.dill`. It succeeded, which cleared our frontend_server, our platform dill and
the kernel in a single command and pointed straight at our binary. Do this first
next time.

### Two more upstream dependencies this surfaced

- **The DD two-pass build.** `flutter_tools` runs it whenever `usesLinker`, and it
  needs `gen_snapshot --print_dd_function_identity_to` plus `analyze_snapshot
  --compute_dd_table` / `--compute_dd_slot_mapping` / `--dd_caller_links` /
  `--dd_table_data` / `--dd_function_identity` — all private to their fork, and
  *every* failure inside the pass is fatal. Pass **`--dd-max-bytes=0`** to
  `shorebird release ios`; DD only improves the link percentage of iOS *code*
  patches, which need the linker we do not have. (`--dd-max-bytes` defaults to
  `10000`, so it is on unless you turn it off.)
- Stubbing flags is not always enough. The six `print_*_table_link_*_to` flags
  work as stubs because nothing reads what they write; DD does not, because
  `analyze_snapshot` has to consume the output.

Corrections to what this file said before: `experimental_hashes.map` is **not**
checked in empty (it had two passthrough aliases before today, and now names our
Route B engine); the Metal-toolchain hazard is **not** ANGLE-specific — it applies
to any Metal compilation, including Impeller on iOS; and an earlier claim of mine
that "there is no public Dart revision to rebase onto" was **wrong** — I had tested
Shorebird's private SHA instead of looking for vanilla's release tags.

**[Track E](#track-e--ios-code-push-the-binder) is not next — items 8 and 9 are.**
See the order of work at the top of this file. The iOS code-push kill gate
**passed** on 2026-08-04 — interpreted patch execution is proven in a precompiled
runtime, on our own engine, with no access to Shorebird's private Dart fork — and
an earlier version of this paragraph called what remains "one well-defined
compiler feature". **That was an understatement**: the call-emission mode is step
1 of ten, and the other nine are production work, not research. Read
[`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) for the full evidence chain before
starting any of it.

Also new: [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) is the single
tracker for every remaining dependency on upstream Shorebird (7 of 10 items now
built, not merely mirrored).

Background: [`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md) is the staged plan
these tracks execute. ([`FORK_REBUILD.md`](FORK_REBUILD.md) is earlier scoping it
supersedes.) [`AOT_LINKER_FEASIBILITY.md`](AOT_LINKER_FEASIBILITY.md) sizes the
linker work by reading the Dart SDK.

Working notes for whoever picks this up next. Product documentation lives in
[`ENGINE_IMPROVEMENTS.md`](ENGINE_IMPROVEMENTS.md) (front door),
[`ENGINE_BUILD.md`](ENGINE_BUILD.md) (evidence + constraints) and
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) (roadmap + layer analysis).
This file is the "where to put your hands" version.

## The one thing to internalize first

**`main` and the supported pin are untouched, and must stay that way.** Everything
*shipped* still runs on Shorebird's prebuilt engine, and `compatibility.yaml` is
byte-identical to `main`.

What is **no longer** true, despite what this section used to say:
`experimental_hashes.map` is not checked in empty — its own header comment still
claims it is, and that comment is wrong. As of 2026-08-06 it carries **seven**
entries, and they are not interchangeable:

| Hash | What it is |
|---|---|
| `760e3fab` | **the current Android engine**, device-verified 2026-07-31 |
| `70974f81` | **the current iOS engine**, device-verified 2026-08-05 |
| `fc184af6` | Route B Android, device-verified 2026-07-30, superseded but still valid on its own terms |
| `5b1a8965` | `fc184af6` + the `PatchCarriesCode()` guard; never device-verified |
| `9f4d3942` | `70974f81` built with `dart_dynamic_modules=true` — Track E's config, **not** the shipping one |
| `70b2e762`, `bbddaa6e` | **DIAGNOSTIC engines. Do not ship.** Both make any unhandled Dart exception fatal |

(`5a6b0b09…`, which this section used to name as our iOS engine, is superseded and
is no longer in the map at all.)

The mirror is therefore not a pure passthrough cache: for those hashes it serves
our overlay and 404s a miss instead of falling back to stock. That is deliberate
and is what makes the device proofs meaningful, but it means **the map, not the
pin, is the switch to check** when you want to know whether a build used our
engine — and *which* engine. Verify the pin before and after any change:

```bash
python3 - <<'PY'
import subprocess, yaml
def load(r): return yaml.safe_load(subprocess.run(
    ['git','show',f'{r}:selfhost/compatibility.yaml'],capture_output=True,text=True,check=True).stdout)
m,b = load('main'), load('HEAD')
print('pin identical:', m['shorebird']==b['shorebird'],
      '| independence identical:', m['independence']==b['independence'])
PY
```

Branch: `feat/engine-improvements`, off `main` and now pushed to `fork`
(`mml555/shorebird`) — it is no longer single-copy on one Mac.

## Where each track stands

### Track A — crash reporting

**Done:** ingestion + retention, and retention is now actually wired.

| Piece | Where |
|---|---|
| `crash_reports` table | `code_push_server/lib/src/repository.dart`, migration **8** in `_migrations` |
| `insertCrashReport`, `crashReports` | same file, "Crash reports" section |
| `POST /crashes` (device, unauthenticated) | `lib/src/api.dart` → `_crashesReport` |
| `GET /api/v1/apps/{id}/crashes` (authed) | same file → `_getCrashes` |
| Symbol retention | `shorebird_cli/lib/src/code_push_client_wrapper.dart` → `createPatchSymbolArtifact`, tag `symbolsArch` |
| Symbol **source** | `commands/patch/patcher.dart` → `debugSymbolsDirectory()` |
| Packaging + upload | `patch_command.dart` → `_packageSidecars`, then `publishPatch(sidecars: …)` |

Retention has **no flag of its own**: `--split-debug-info` is the opt-in, since
that is what makes any patcher emit symbols at all. It is uniform across
platforms — Flutter writes symbols there on Android, and the Apple patchers point
gen_snapshot's `--save-debugging-info` at the same directory.

One subtlety worth not re-discovering: the patch command **injects**
`--split-debug-info` itself when it has to enable `--obfuscate` to match the
release, so `debugSymbolsDirectory()` also reads `extraBuildArgs`. Reading
`argResults` alone would retain nothing for obfuscated patches — the ones that
most need symbolication.

Sidecars are **not fatal**: a patch whose symbols could not be packaged is still
a valid patch, so failures warn and degrade to "not retained" rather than
throwing away a completed build.

**Symbolication is done** — `lib/src/symbolication.dart`, surfaced as
`GET /api/v1/apps/{id}/crashes?symbolicate=true` adding a `stack_symbolicated`
field beside the raw `stack`.

An earlier version of this file said Android needs `llvm-symbolizer` and Apple
needs `atos` or a Mac worker. **That was wrong**, and it would have bought a
whole Mac-worker architecture for nothing. What the CLI retains is Dart's own
`--split-debug-info` output, which is what `flutter symbolize` reads via
`package:native_stack_traces` — pure Dart, handling the ELF form (Android) and
the Mach-O form (Apple). One implementation covers every platform inside the
Linux container. `atos` would only matter for native Objective-C/C++ frames out
of a dSYM, and a Dart crash handler does not produce those.

Things worth not re-deciding:

- **Read-time, not ingest-time.** Ingest must stay unfailable, and symbols are
  routinely uploaded *after* a crash arrives, so an ingest-time attempt would
  permanently miss.
- **Opt-in via `?symbolicate=true`.** Resolving costs a fetch, unzip and DWARF
  parse per distinct patch in the page. Off by default also keeps the response
  byte-identical for existing callers.
- **Never guess the symbol file.** Match the arch by `-<token>.symbols` suffix,
  not `contains`: `arm` is a prefix of `arm64`, so a `contains` match hands
  arm64 symbols to an arm32 crash and resolves every frame to a wrong address —
  a failure that looks like success. With several entries and no arch match the
  code returns null on purpose.
- Parsed symbol sets are cached (bounded, small — a parsed set is large in
  memory), with a negative cache so a broken artifact is not re-parsed per
  request.

**Verified end to end on device, 2026-07-30.** An obfuscated release +
obfuscated patch on Android arm64 (CPH2551), crashed from a patched code path,
reported by `code_push_runtime`, and resolved by
`GET /api/v1/apps/{id}/crashes?symbolicate=true`:

```
raw:  #00 abs 000000775284f067 virt 00000000001a6067 _kDartIsolateSnapshotInstructions+0xcef27
sym:  #0  patchedCrashProbeThrow (…/crashprobe/lib/main.dart:36:3)
      #1  CrashProbeHome.build.<anonymous closure> (…/crashprobe/lib/main.dart:75:32)
```

Two things that make this more than "a name appeared":

- **The line number proves which symbol set was used.** The probe function sat
  at line 27 in the release and line 36 in the patch. The resolved frame says
  **36**, so the server joined on the *patch's* retained symbols — the join the
  whole design rests on — rather than the release's.
- **Arch selection was exercised for real.** The retained zip held all three
  ABIs, and `app.android-x64.symbols` is listed *first*. A first-entry or
  `contains('arm')` match would have resolved every frame against the wrong ABI
  and looked like success. The `-arm64.symbols` suffix match picked correctly.

Reproduce with an app depending on `code_push_runtime`: obfuscated
`shorebird release android --obfuscate --split-debug-info=<dir>`, then plain
`shorebird patch android` (obfuscation and `--split-debug-info` are inherited
automatically), crash from patched code, then read the crashes endpoint with
`?symbolicate=true`. **The crash must happen while a patch is running** —
reporting is deliberately not installed on an unpatched release, so a crash
before the patch applies is not a bug.

**Do not make `POST /crashes` fail.** It always answers `200 {stored: bool}` and
swallows malformed input on purpose — the client is an app that just died, and
making it fight 4xx/5xx is a second failure on top of the first. There is a test
named `garbage never fails the reporter` guarding this.

### Track B — assets in patches

**Done:** the whole CLI half — Android (device-verified end to end) and Apple.

| Piece | Where |
|---|---|
| `POST /patches/assets` (device, unauthenticated, signed URL) | `code_push_server/lib/src/api.dart` → `_patchesAssets` |
| Upload path | `shorebird_cli/.../code_push_client_wrapper.dart` → `createPatchAssetArtifact`, tag `assetsArch` |
| `--assets` flag (opt-in) | `patch_command.dart`, next to `allow-asset-diffs`; getter `includeAssets` |
| Asset source hook | `commands/patch/patcher.dart` → `assetsDirectory()`, `null` by default |
| Android implementation | `android_patcher.dart` → `base/assets/flutter_assets/**` from the AAB cached by `buildPatchArtifact`, via `ArtifactManager.extractAndroidFlutterAssetsFromAab` |
| Apple implementation | `ios_patcher.dart` / `macos_patcher.dart` → `ArtifactManager.findFlutterAssetsDirectory` over the built bundle |
| Packaging + upload | shares Track A's `_packageSidecars` / `publishPatch(sidecars: …)` |

Decisions made while wiring it, so you do not re-litigate them:

- **Full `flutter_assets` overlay, not a delta.** Simpler and correct; the plan
  always allowed "replace the whole tree for patch N". Delta is an optimization,
  and the changed-file detection to drive one already exists if you want it:
  `archive_analysis/archive_differ.dart` → `assetsFileSetDiff()` /
  `containsPotentiallyBreakingAssetDiffs()`, surfaced as
  `DiffStatus.hasAssetChanges` by `patch_diff_checker.dart`.
- **The AAB is the source, not a build intermediate.** Those are the bytes the
  release would have shipped, already through Flutter's asset pipeline; an
  intermediate directory can hold another variant's assets.
- **Apple's location is searched, not hardcoded.** iOS keeps it at
  `Frameworks/App.framework/flutter_assets`; macOS, verified against a real
  build, at
  `Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets` —
  **not** `App.framework/Resources/...`, which is only a symlink to it. (The
  unit test originally asserted the symlink path and passed without that path
  existing; building for real is what caught it.) The search is breadth-first so
  a plugin framework vendoring its own `flutter_assets` cannot win over the
  app's shallower copy, and it does **not follow symlinks** — a macOS framework
  is a web of them, and a cycle in any embedded framework would otherwise hang
  `shorebird patch` with no output.
- Zipped with `Directory.zipToTempFile()` from
  `lib/src/archive/directory_archive.dart`. **Use this, not a new helper** — it
  zips with `includeDirName: false`, so entries are relative to the directory,
  which is what an overlay unpacked over an asset root needs. (I wrote a
  duplicate on `ArtifactManager` before finding it, and removed it.)

**The app-side package is done**: [`packages/code_push_runtime`](../packages/code_push_runtime).
It reads the running patch number via `shorebird_code_push` (depended on from
pub, since the source is a separate upstream repo), fetches `POST
/patches/assets`, caches, and exposes a `PatchAssetBundle` preferring the bundle
and falling back to `rootBundle`. It also carries the **crash reporter**, since it
needed the same two things — the patch number and an HTTP client to this control
plane — and without it nothing fed symbolication.

**Crash reporting is deliberately scoped to patches.** The handlers are not
installed at all on an unpatched release. This is not a crash reporting product
and must not grow into one: an app on a plain release already has whatever
reporter it chose, and a report from one could never be symbolicated here anyway,
because symbols are retained per patch. The question it answers is the narrow one
code push creates — "did the patch I shipped break something?" Resist the
temptation to "complete" this by retaining release symbols; that was considered
and rejected as scope, not overlooked.

Standalone package, **not a workspace member**, for the same reason as
`code_push_server`: the workspace root resolves with the Dart SDK, and adding a
Flutter package would force every package to resolve through Flutter. Test with
`cd packages/code_push_runtime && flutter test`.

Invariants it exists to enforce, all tested:

- **Cache keyed by patch number, served only for the running patch**, and every
  other patch's bundle deleted as soon as a different one runs. Eviction is
  unconditional, so a rollback to a patch with *no* assets still drops the newer
  bundle.
- **Published only when complete** — staging dir, completion marker, one rename.
  A payload that is not a zip decodes to an *empty* archive rather than throwing,
  so zero extracted files is treated as failure; without that check a corrupt
  download became a cached bundle that looked complete and was never retried.
  (A test caught exactly this.)
- **Overlay, not replacement.** A key the bundle lacks falls back to the
  compiled-in asset.
- **Chained error handlers.** `FlutterError.onError` and
  `PlatformDispatcher.onError` wrap whatever was there, so Crashlytics and
  debug's red screen both survive, and the previous handled-verdict is preserved
  rather than defaulted.
- **Release version is injected** (`readReleaseVersion`). Flutter does not bundle
  the app version anywhere reachable on every platform — `version.json` is *not*
  in `flutter_assets`, which I checked against a real AAB — and taking a
  platform-channel dependency to find it would make the package untestable.

### Track D — engine-level patch assets (Route B) — PROVEN, fonts included

Device-verified 2026-07-30 on Android arm64. **All three engine-only cases changed
in a single launch**, which is the complete claim:

| Case | From APK | From overlay |
|---|---|---|
| `rootBundle` (no `DefaultAssetBundle`) | `APK-baked` | `ENGINE-OVERLAY-patch-1` |
| Declared font (`family: Probe`) | Courier New | Comic Sans |
| Declared shader (`shaders/probe.frag`) | blue | red |

Fonts and shaders never pass through an app-side `AssetBundle`, so those two are
what Route A structurally cannot reach at any price.

**Shader gotcha:** anything under `shaders:` is compiled to `iplr` at build time.
The replacement must ALSO be declared under `shaders:`; shipping it as a plain
asset means swapping raw GLSL over compiled bytes, which reads as "shaders do not
work" rather than "the test was wrong". Sizes give it away (243 vs 1220 bytes). Engine hash
`fc184af6509a93eaf6fc068c6820639b324175a8` (rebuild of `dabf1837…` plus the
resolver), published to the local overlay and served by the mirror.

| Piece | Where |
|---|---|
| `Settings::shorebird_patch_assets_path` | `engine/src/flutter/common/settings.h` |
| Path derivation | `shell/common/shorebird/shorebird.cc` → `PatchAssetsPathForPatch()` |
| **The hook that matters** | `shell/platform/android/android_shell_holder.cc`, registered BEFORE the APK provider |
| Embedder-generic hook (unused on Android) | `shell/common/run_configuration.cc` |

Three traps, all of which cost real time:

1. **Android does not call `RunConfiguration::InferFromSettings`.** A resolver
   added there does nothing. LTO strips the function and the log string vanishes
   from `libflutter.so`, which is the only reason it was caught.
2. **The Android patch dir has no app id**:
   `<files>/shorebird_updater/patches/<N>/`. Derive from the patch file's
   dirname, never rebuild the path from `app_storage_path`.
3. **Gradle refuses the HTTP mirror.** See the mirror note below; this blocks any
   release built against the mirror, not just experimental engines.

`FML_LOG(INFO)` does **not** appear in logcat on a release build, so do not rely
on it to confirm the hook. Grep the linked `libflutter.so` for the literal, and
prove the behavior on device.

#### Reproducing the Route B rig

Assembling this was most of the work. The pieces and why each is needed:

1. **Build on the box, publish to the Mac.** `build.sh --cell android-arm64`, then
   `overlay_publish.sh --hash <sha> --root <staged>`. The Mac holds the mirror, so
   either stage the built zips there (128 MB) or run publish where the mirror is
   reachable. Host artifacts (`dart-sdk-*.zip`, `flutter_patched_sdk_product.zip`,
   `linux-x64/artifacts.zip`) can be reused from a previous hash **only** if the
   change is engine-C++-only; they are VM-coupled otherwise.
2. **`overlay_publish.sh` does not publish everything.** It omits
   `linux-x64/artifacts.zip` (gen_snapshot, impellerc) and the Maven
   `maven-metadata.xml`. Add both by hand; the known-good set is 17 files.
3. **Releases must run on Linux.** Our `gen_snapshot` is linux-x64 only, and the
   mirror 404s (deliberately) on host artifacts we did not build, so a release
   from the Mac cannot work. Use `release_on_box.sh` / `release_routeb.sh`.
4. **Tunnels.** The box reaches the Mac's control plane and mirror over `ssh -R`.
   Watch for stale forwards: one was still pointing at an old server and produced
   a confusing "Could not find app with id".
5. **One URL must satisfy box and device.** `PUBLIC_BASE_URL` is embedded
   absolutely in upload/download URLs, so the port the box uses must also be the
   port the device reaches via `adb reverse`.
6. **The upstream CLI on the box has neither `--no-confirm` nor
   `--flutter-version` on `patch`.** Pipe `yes` instead.
7. **Getting an overlay onto the device.** A release build is not debuggable, so
   `adb run-as` cannot write into app-private storage. The app writes its own
   overlay instead (Phase 2 replaces this with real delivery).
8. **The Android patch dir has no app-id component**
   (`<files>/shorebird_updater/patches/<N>/`), while the desktop API inserts one
   (`.../shorebird_updater/<app_id>/patches/<N>/`). Derive from the patch file's
   dirname; never rebuild the path from `app_storage_path`.

### Track E — iOS code push (the binder)

**Status: mechanism PROVEN in a harness; production integration NOT BUILT.**
Route B was selected 2026-08-05 on the strength of two passing kill-gate spikes,
and selection is where it stopped. Full evidence and reasoning:
[`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md). Harness and result:
[`engine/killgate/`](engine/killgate).

**Start it only after independence items 8 and 9 are closed**, and treat it as a
new greenfield project with its own milestones rather than a continuation of this
branch's debugging work. The ten steps are listed in the order of work at the top
of this file; the two that can still veto the whole approach — the real-app
size/frame-time benchmark and the hot-path-patching product question — are steps 8
and 9 deliberately, because they are cheap to run once the mode exists and
expensive to discover after shipping.

The premise this track overturned: we assumed iOS code push required reproducing
Shorebird's private Dart fork, because it needs an interpreter for patched code.
**It does not.** Vanilla Dart 3.12.2 already ships the interpreter, the
`InterpretCall` stub, and `Function::AttachBytecode` — all behind the
`dart_dynamic_modules` GN flag, which defaults off. It is a build-config flip, not
new VM code.

What has been demonstrated on a real build (macOS arm64, release AOT):

| Question | Result |
|---|---|
| Interpreter present in a precompiled runtime | **Yes** — 48 `Interpreter` symbols + `_InterpretCall` in `dartaotruntime` |
| An AOT function's body replaceable at runtime | **Yes** — `AttachBytecode`, `IsInterpreted` 0 → 1 |
| Interpreter executes the replacement | **Yes** — returned `NEW` via `DartEntry::InvokeFunction` |
| Call site locatable and rewritable | **Yes** — found 1 of 2,237 global-pool slots |
| Entering the interpreter *from* an AOT call site | **No** — see below |

#### The remaining work, precisely

AOT's static-call convention passes **neither the callee `Function` nor an
arguments descriptor**, because it never expects the callee to change. Two routes
were tried and both are ruled out for concrete reasons (details in
`IOS_CODE_PUSH.md`):

- Supplying the descriptor at the call site is **necessary but not sufficient** —
  `InterpretCall` also wants the `Function` in `FUNCTION_REG`, which on arm64 is
  carrying an argument. The fault merely moved (`0x…186f` → `0x7`).
- Leaving calls **unlinked** so they resolve through the `Function` would work in
  principle, but `CallStaticFunction` is JIT machinery that patches the call site
  — i.e. writes executable memory. Illegal on iOS.

**So the next task is a new call-emission mode**, gated on `DART_DYNAMIC_MODULES`,
for functions we want replaceable: keep the callee `Function` in a pool slot, load
it into `FUNCTION_REG`, load the descriptor, branch through
`Function::entry_point_`. Everything it touches at runtime is **data** (a pool slot
and a field read), so it is iOS-legal — and patching then reduces to
`AttachBytecode` repointing `entry_point_`, needing no pool rewrite at all.

Where to work:
- `runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc:598`
  `EmitOptimizedStaticCall` — already carries `arguments_descriptor`; our
  descriptor-loading change is here.
- `…:397` `GenerateStaticDartCall` — the two existing forms (PC-relative vs
  pool-mediated) to model the third on.
- `…/flow_graph_compiler.cc:3535` `CanPcRelativeCall` — `precompiled_mode &&
  !force_indirect_calls && same_loading_unit`, the switch between them.
- `runtime/vm/compiler/stub_code_compiler_arm64.cc:3137`
  `GenerateInterpretCallStub` — the register contract to satisfy (`R0` Function,
  `R4` descriptor).

**Release-time consequence to settle early:** an app must be *built* patchable.
`--force_indirect_calls` alone costs ~4% snapshot size (measured: 838,560 →
871,520 bytes on a toy program); the new mode will cost a little more. A patch
cannot retrofit this onto an app already shipped, exactly as Shorebird's layout
pinning cannot be retrofitted.

#### The macOS build rig (new, and the thing to reuse)

Everything lives on the external SSD at `/Volumes/build` — **APFS, deliberately
named without spaces**, because `depot_tools`/`gclient`/GN break on paths
containing them.

```
/Volumes/build/ios-engine/
  depot_tools/     # pinned, DEPOT_TOOLS_UPDATE=0
  flutter/         # shorebirdtech/flutter @ c15ef63794 (the pinned flutter_revision)
  dart-sdk/        # OUR fork: vanilla d684a576 + the 57-line shim, served over file://
```

Scripts, all in [`engine/killgate/`](engine/killgate):
- `build_host_for_gate.sh` — waits for the sync, applies our engine patches,
  configures and builds. **Read its comments before changing flags**; three of
  them encode failures that cost real time.
- `0001-attach-bytecode-native.patch` — the SDK side (176 insertions, 5 files):
  the `attachBytecodeToFunction` native, its registration, the `dart:_internal`
  declaration, the pool rewrite, and the descriptor-loading compiler change.
- `run.sh` — runs the gate. Honors `GEN_SNAPSHOT_FLAGS`
  (e.g. `--force_indirect_calls`). Refuses to run unless
  `dart_dynamic_modules = true` is actually in `args.gn`.

Build invocation that works:

```bash
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
cd /Volumes/build/ios-engine/flutter/engine/src
./flutter/tools/gn --runtime-mode=release --mac-cpu arm64 \
    --no-prebuilt-dart-sdk --dart-dynamic-modules
ninja -C out/host_release_arm64 -j8 \
    gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill
```

Four things in that command are load-bearing, each learned the hard way:
1. **`--mac-cpu arm64`** — `tools/gn` defaults it to `x64` even on Apple silicon
   (`tools/gn:971`), which makes the Rust updater target `x86_64-apple-darwin` and
   fail with `can't find crate for 'core'`. It also changes the output directory
   to `out/host_release_arm64`.
2. **`--no-prebuilt-dart-sdk`** — mandatory for us. DEPS pulls a prebuilt macOS
   Dart SDK from `gs://shorebird-dart-sdk-prebuilt`, which is private and 401s.
   `.gclient` also sets `custom_vars: {download_dart_sdk: False}` to skip it. It is
   the **only** private bucket in DEPS; everything else is public.
3. **Named targets, not the default all-targets** — the default pulls in ANGLE,
   whose Metal shader compilation fails on Xcode 26 without a separately
   downloaded Metal Toolchain. Named targets are 1,549 vs 11,462 and skip it.
4. **`--dart-dynamic-modules`** — the whole point. Verify it reached
   `out/host_release_arm64/args.gn`; a silently dropped GN arg wastes hours.

First full build: ~8 minutes. Incremental after a runtime edit: ~1 minute.

#### Gate gotchas that will bite again

- **`dart2bytecode` takes source, not a `.dill`.** Feed it a `.dill` and it tries
  to tokenize the binary as Dart and dies while reporting the error (an OOM inside
  the diagnostic). Real usage: `dart2bytecode --platform vm_platform.dill
  [--import-dill host.dill] input.dart`.
- **Use `gen_kernel.dart`, not `dart compile kernel`,** when the library URI
  matters: the latter takes a file path and rejects a `package:` URI, but the URI
  recorded in the snapshot is what the native looks up at runtime.
- **AOT drops library dictionaries**, so runtime name lookup fails until the target
  carries `@pragma('vm:entry-point')`. That is a *gate* limitation only — a real
  linker identifies targets from the snapshot's tables at build time.
- **Keep a test replacement body self-contained.** The first one called `print()`
  and died in `bytecode_reader.cc:1172` with `Unable to find function print in
  Library:'dart:core'` — that is the *binding* problem, and letting it in makes a
  binding failure look like an execution failure.
- **`--import-dill` crashes the CFE** when handed an AOT (tree-shaken) kernel:
  `DillExtensionBuilder`, null check on null. Probably wants a non-AOT kernel.
  Unresolved, and it matters — `--import-dill` is upstream's channel for compiling
  a module against a host program, so binding work will hit it.

### Track C — hot restart

**Not started, and deliberately deferred (2026-08-06).** Do not begin it before
iOS Dart code push works. It introduces a second runtime lifecycle axis, and
Route B's core code-patch lifecycle — activation, rollback, crash recovery — does
not exist yet to layer it onto. Sequencing it after Route B means it inherits a
proven activation/rollback model instead of inventing one in parallel.

When it does start: needs the engine build loop, so agree the design before
touching Rust or C++ — a wrong guess costs a multi-hour rebuild to discover.

Shape from `EXPERIMENTAL_ENGINE.md`: updater grows `readyToApply` alongside
`restartRequired`; engine reloads the root isolate from the new `.vmcode`
in-process; cold restart stays the fallback; boot-crash rollback must still hold.
Both halves live in shared code (`shell/common/shorebird/`,
`vendor/updater/library/src/`), so it is iOS-ready by construction even though
iOS cannot run it yet.

## The mirror cannot serve a release over plain HTTP any more

`FLUTTER_STORAGE_BASE_URL=http://…` makes Flutter's Gradle plugin add an `http`
Maven repository, and Gradle 8+ refuses insecure repositories without an explicit
opt-in. The failure is `:app:mergeReleaseAssets` → "Using insecure protocols with
repositories, without explicit opt-in, is unsupported", before any Flutter
artifact is fetched.

**This is not specific to experimental engines** — it applies to the documented
CDN-mirror setup with a current Flutter/AGP, so it will bite ordinary mirror users.

**Fixed, and verified:** [`cdn/tls/`](cdn/tls) adds an optional HTTPS listener.

```bash
selfhost/cdn/tls/generate.sh localhost          # local CA + SAN'd server cert
# point tls_listen.conf at listen-enabled.conf in docker-compose.cdn.yaml
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache
selfhost/cdn/tls/trust.sh                        # on every machine that BUILDS
export FLUTTER_STORAGE_BASE_URL=https://localhost:8443
```

`trust.sh` installs into **two** stores, and missing either gives a misleading
error rather than a clear one: Gradle runs on the JVM and reads the JDK's
`cacerts` (`PKIX path building failed`), while Dart/Flutter tooling reads the OS
store (`CERTIFICATE_VERIFY_FAILED`).

Verified on the Linux build host with the `FlutterPlugin.kt` insecure-protocol
patch **reverted**: a release built over https succeeded. Off by default, so an
existing deployment is unaffected until it opts in.

The escape hatch remains if TLS is impractical: patch the vended
`packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt` to set
`isAllowInsecureProtocol = true`. That has to be redone on every build host and
after every Flutter bump, which is why HTTPS is the real fix.

## Invariants that cost real debugging time

Do not re-learn these:

1. **Snapshot and kernel formats are welded to the tree that produced them.**
   `VM_SNAPSHOT_FILES` in Dart's `tools/make_version.py` includes two of the three
   files our fork patches. A mixed artifact set installs fine and then dies at
   launch with `Wrong full snapshot version`. The whole host toolchain must come
   from our tree.

   **Stronger than that, learned on iOS 2026-08-04: same tree is not enough —
   the whole host toolchain must share the same GN CONFIG and the same applied
   patches.** The chain is
   `frontend_server_aot` → kernel → `gen_snapshot` → snapshot, against the
   platform dill in `flutter_patched_sdk_product`. Break it anywhere and the iOS
   AOT step dies with

   ```
   Error (Xcode): Unexpected tag 4 (Field) in ?, expected a procedure,
   a constructor, a local function or a function node
   ```

   which names nothing useful. Two distinct causes produced that identical
   message, hours apart:

   - ~~**Different `dart_dynamic_modules`.**~~ **Disproved 2026-08-04 (late).** A
     `dart_dynamic_modules=true` `gen_snapshot` consumes a dill from a
     `dart_dynamic_modules=false` frontend_server and platform dill without
     complaint — built and ran both ways, identical behavior. The real cause of
     this error is the tear-off bug in [§ Root cause,
     found](#root-cause-found-2026-08-04-late). Keeping the whole toolchain on one
     GN config is still right on principle, and `out/host_release_arm64_nodm`
     exists for that, but it was not the bug and chasing it cost hours.
   - **Track E's SDK edits leaking into the platform dill.** The killgate patch
     modifies `sdk/lib/_internal/vm/lib/internal_patch.dart` and
     `sdk/lib/internal/internal.dart`, which are *SDK sources* and therefore
     compile into `platform_strong.dill` no matter what the GN flag says —
     `strings platform_strong.dill | grep attachBytecodeToFunction` returns 7
     hits. Those changes are designed for `dart_dynamic_modules = true`.

   **So the killgate rig and the iOS-engine rig cannot share one Dart checkout.**
   Give each its own, or unapply
   [`engine/killgate/0001-attach-bytecode-native.patch`](engine/killgate)
   before building an iOS engine. Check with `git status` in
   `engine/src/flutter/third_party/dart` before trusting any iOS artifact.

   A corollary worth knowing: a change to `runtime/vm/compiler/aot/precompiler.cc`
   can compile clean in `out/ios_release` and still break a host build, because
   that file is also compiled into the JIT variant (`libdart_compiler_jit`) where
   `DART_PRECOMPILER` is off. `-Werror=unused-function` on a helper whose only
   call site is inside the guard is the failure mode. Build a host target too
   before believing an `ios_release`-only success.
2. **Clearing an artifact cache swaps the Dart under an already-compiled tool
   snapshot**, which then fails as `Wrong full snapshot version` *on the host* —
   looks like an engine fault, is not. Recompile the CLI/flutter tool snapshots.
3. **`--no-tree-shake-icons` is mandatory** on a self-built engine. `const_finder`
   is a kernel snapshot stamped with its builder's SDK hash. Shorebird hit this
   too: `font_subset` is commented out of their own `linux_build.sh`
   (flutter#164531).
4. **Maven POMs cannot be proxy-rewritten.** Gradle validates the version inside
   the `.pom` body, so every module must be materialized locally under the
   experimental hash — including ABIs we did not build.
5. **`PUBLIC_BASE_URL` is embedded absolutely** in upload/download URLs. One URL
   must satisfy both the build host and the device; `http://localhost:18080` plus
   an ssh reverse tunnel (box) and `adb reverse` (device) does.

   **On iOS there is no `adb reverse`, but you do not need Wi-Fi either: use the
   USB link.** A tethered iPhone appears as an ordinary macOS network interface
   with IPv4 link-local on both ends, so the phone can reach a server on the Mac
   over the cable. Find it with:

   ```bash
   ifconfig | awk '/^[a-z0-9]+:/{i=$1} /inet 169\.254\./{print i, $2}'   # Mac side
   arp -a -i <iface>            # the phone shows up as <name>.local
   ```

   On 2026-08-04 that was `en17`, Mac `169.254.189.3`, phone `169.254.145.84`,
   ~1 ms round trip. Set `PUBLIC_BASE_URL` and the app's `shorebird.yaml`
   `base_url` to the **Mac's** link-local address and everything works with Wi-Fi
   off — which also satisfies the wired-only testing rule.

   Two caveats: the link-local address can change when the device reconnects, and
   `base_url` is baked into `flutter_assets`, so a changed address means a new
   release build. Check the address before building, not after.
6. **`arch` is free-form end to end.** It has now absorbed three artifact kinds
   (code, `assets`, `symbols`) with no schema, protocol, or client change. Reach
   for it before adding columns.
7. **Anything under `vendor/flutter` needs `git add -f`.** Flutter's own nested
   `.gitignore` files silently drop tracked files — that is how 20 files,
   including a whole GN target, went missing from the snapshot.

## Live environment (may need reverting)

- **Rig state as of 2026-08-05, left warm on purpose.** The Apple `DdSupport`
  validation it was staged for is **done** (see Pending actions), and the same
  warm rig then carried the sealed acceptance run — keep it warm for items 8
  and 9, which need the mirror and both build hosts:
  - Mac `bin/cache/dart-sdk` is **ours** (`6b58bb3a`). That is the fix, not
    residue — do not "restore" it. The CLI guard now enforces it.
  - `bin/internal/engine.version` **is back at stock `69f9831c`**, so any build
    against our engine must set it (the release scripts do this from `HASH`).
  - Overlay is current for both `70974f81` (iOS, incl. our `dart-sdk-darwin-arm64`
    and the injected `const_finder`) and `760e3fab` (Android). CDN container up.
  - iPhone 7 attached over USB; Android CPH2551 attached with
    `adb reverse tcp:18081 tcp:18081`.
  - The ssh reverse tunnel to the Linux box is **closed**; reopen with
    `-R 8085:localhost:8085 -R 18081:localhost:18081` before an Android build.
  - Linux box `out/` dirs survive and carry the retired-patch tree.

- **macOS build host (new, 2026-08-03/04):** this Mac — 10 cores, 64 GB RAM,
  Xcode 26.6. It is the **only** host that can build iOS/macOS engines, and it is
  where Track E happens. All build state is on an external SSD at
  **`/Volumes/build`** (1 TB APFS, ~390 GB free with media restored). Two hazards:
  - **Keep the SSD plugged in directly, not through a hub.** It detached mid-write
    once while behind a VIA Labs hub, taking a transfer and a build with it. The
    telltale was a `USB Billboard Device` from the same vendor with the SSD absent
    entirely. Direct-attached it has been stable. `diskutil verifyVolume` after any
    detach — the one time it happened, APFS came back clean, but do not assume.
  - **Never run a long job as a harness background task.** Harness cleanup killed
    these jobs twice. Use a detached screen:
    `screen -dmS <name> bash -c 'caffeinate -is ./script.sh'`. `caffeinate`
    prevents idle sleep, which is the other thing that killed one.
- **Media on the SSD — THIS IS NOW THE ONLY COPY. Do not delete it.**
  `/Volumes/build/media` holds 513 GB (2,055 files).

  **CORRECTION 2026-08-09: there is no historical integrity baseline.** This
  entry used to say the media was "MD5-verified byte-identical" on 2026-08-04,
  which reads like something you can verify against today. You cannot: the
  hashes were never retained — not here, not in the repo, not on disk. What the
  surviving evidence supports is **path and byte-size equality** in August,
  which is what the deletion decision below was actually made on. Treat any
  content-integrity claim about the August state as unproven, and note that
  APFS does not checksum user data, so the filesystem never held that proof
  either.

  **Partial exception, found 2026-08-09: 202 files DO have a historical
  baseline.** Eight `.sfv` manifests written by hkSFV on 2010-04-12, against
  files dated 2007, ship inside the Full House directories and carry a CRC32
  per file. `media_backup.py sfv` verified **202 of 202 OK, zero mismatches** —
  content unchanged across sixteen years, both SSD detaches and the August
  event included. That is real evidence and it is also only ~10% of the tree;
  it says nothing about the other 1,853 files.

  `scripts/media_backup.py` is built around what remains provable: `manifest`
  reads every byte (so I/O errors surface, and a NEW baseline is established
  going forward), `decode` runs a full ffmpeg pass to catch truncated streams
  that read back cleanly, and `verify` proves a copy matches its source. A
  decode failure is recorded as *suspicious*, not as drive damage — some of
  these files may have been malformed long before the drive misbehaved. On 2026-08-05 both server copies were deleted
  to free the build box, so the earlier note here — "the SSD copy is disposable
  if space is needed" — is **inverted and must not be followed**.

  Before deleting, every server file was matched against the SSD by path and
  byte size: `/data/ssd-backup` (338 GB, 1545 files, `tv`) and
  `/mnt/spare/ssd-backup` (176 GB, 510 files, `movie` + `tv`) were **disjoint
  halves**, not copies of each other, and all 2055 files were present on the SSD
  with zero discrepancies. That freed `/data` 40 GB → 378 GB and `/mnt/spare`
  19 GB → 195 GB.

  The consequence: this media has no second copy anywhere, and it lives on an
  external SSD that has already detached mid-write once (see the hub hazard
  above). If it matters, give it a real backup.

  Note `/mnt/spare` is the old 220 GB `/data` disk, now in `/etc/fstab` with
  `nofail` (backup at `/etc/fstab.bak-20260803`).
- **Build host:** Hermes VPS `20.120.104.70`. **SSH is on port 13549 as user
  `jewgo`**, not 22 as `azureuser` — port 22 is filtered, so the box looks dead
  if you assume the default (`ssh -i sshkey20.120.104.70.pem -p 13549
  jewgo@20.120.104.70`; also recorded in [`../serverinfo.md`](../serverinfo.md)).
  Confirmed reachable 2026-07-30: 4 cores, 82 GB RAM, `/data` 380 GB free,
  `hermes-gateway` active. Everything under
  `/data/shorebird-engine/` — never touch `/data/hermes`, and check
  `systemctl --user is-active hermes-gateway` after anything invasive. Note the
  previous `out/` build directories are **gone**; `src/flutter` (29 GB) and
  `src/dart-sdk` (500 MB) remain. Contains
  the engine checkout, our Dart fork, `out/{android_release_arm64,host_release,host_debug}`,
  a patched CLI at v1.6.115, and the test app.
- **Local containers up:** `code_push_server` (1.2.0, host 8080), `cdn-cache`,
  `artifact-proxy`, and **`cps-phase4`** — the 1.3.0 image on host 18080 with its
  data under the session scratchpad, which is the rig the Phase 4 verification
  ran against. `cps-e2e` was stopped to free port 18080; restart it if you want
  the older asset-patch rig back. Device access is
  `adb reverse tcp:18080 tcp:18080`, so `PUBLIC_BASE_URL=http://localhost:18080`
  is one URL that satisfies both the Mac and the phone.
- **`PUBLIC_BASE_URL=http://localhost:18080`** in `packages/code_push_server/.env`
  (was the LAN IP), plus an `adb reverse tcp:18080 tcp:8080` mapping and a
  daemonized ssh reverse tunnel. Revert to a LAN IP for normal device testing.
- The Mac's vended Flutter `engine.version` **has been reverted** to Shorebird's
  `69f9831c`. Confirm it stayed that way.

## Pending actions (things that are prepared but NOT done)

- ~~**Exercise the `DdSupport` auto-disable on a real Apple build.**~~
  **DONE 2026-08-05 — and the validation caught a real probe bug**, which is
  exactly why it ran before any air-gap work. The original probe
  (`--print_dd_function_identity_to=/dev/null --version`) was structurally
  inert: `gen_snapshot` prints its version and exits 0 **before validating any
  other flag** — verified live, an arbitrary bogus flag also exits 0 — so the
  probe reported "supported" on our vanilla gen_snapshot and the release
  proceeded with DD enabled (failure signature 2, caught at line 40 of the
  first run's log). The probe was redesigned to reach VM flag *validation*:
  compile a file that cannot exist
  (`--snapshot_kind=app-aot-assembly --assembly=/dev/null
  /nonexistent-dd-support-probe.dill`) and decide on the stderr marker —
  vanilla dies with `Unrecognized flags: print_dd_function_identity_to`,
  Shorebird's fork with `Unable to read file` — because **both exit non-zero**
  and the exit code alone is useless. See `dd_support.dart` + its 7 tests.

  With the fixed probe, the full pass condition was met on release `30.0.0+1`
  (engine `70974f81…`, default `--dd-max-bytes`, `--verbose`): probe exited
  255 with the unrecognized-flags marker → the auto-disable `logger.detail`
  line appeared → `SHOREBIRD_DD_MAX_BYTES` never set → supplement dir has the
  six ct/dt/ft stub link files and **zero `App.dd_*`** → app reached first
  frame on the iPhone 7 (screenshot evidence; `--justlaunch`'s
  lldb-detach SIGTRAP on iOS 15 is a launcher artifact — use
  `--noninteractive` and screenshot while attached).

  Environment notes from the same run: Xcode had lost its iOS platform
  component ("iOS 26.5 is not installed") — `xcodebuild -downloadPlatform iOS`
  repairs it. A device→control-plane scare resolved as a non-issue: launches
  via `ios-deploy --justlaunch` die on lldb detach (SIGTRAP in
  `lldb_image_notifier`) before the updater's network calls fire, which looks
  exactly like a dead link. A held-attach launch (`--noninteractive`, kill
  after ~15 s) produced the full chain server-side — the app's
  `/selfhost-beacon/*` diagnostics and `POST /patches/check → 200` from
  release `30.0.0+1` over `169.254.189.3:18080`. The USB link-local pair is
  healthy (phone at `169.254.145.84` on en17, 0% ping loss).

- **Track E's next step: the new call-emission mode.** Specified above with
  file:line pointers. It is arm64 codegen work, not research — but it is
  **sequenced after independence items 8 and 9** (see the order of work at the
  top of this file), so "nothing blocks it" is a statement about readiness, not
  priority. The `dartaotruntime`/`gen_snapshot` in
  `/Volumes/build/ios-engine/.../out/host_release_arm64` already carry the native,
  the pool rewrite and the descriptor change, so the edit/build/test loop is ~1
  minute.

  **2026-08-05: this is now the selected default route.** Both kill-gate
  spikes passed the same day (Spike B binding — `engine/killgate/README.md`;
  Spike A pool identity — `engine/spike/README.md`), and the plan's rubric
  selects Route B on a both-pass, subject to two vetoes owned by this
  milestone: a real-app size/frame-time benchmark of the emission mode +
  retention, and the hot-path-patching product question. ~~Note the `_nodm`
  out-dir's gen_snapshot currently carries the spike-only
  `--dump_global_object_pool_to` flag.~~ **RESOLVED 2026-08-09 — rebuilt, 65 s,
  2 targets; the flag string is gone.** The general lesson is worth more than
  the fix: reverting the *source* on 2026-08-07 did not clean the *artifact*,
  and `_nodm` is the tree `publish_ios_overlay.sh` takes `HOST_REL` from, whose
  `dart-sdk-darwin-arm64.zip` ships `dart-sdk/bin/utils/gen_snapshot`. Nothing
  instrumented was ever published — the overlay's copy predates the spike and
  greps clean — but the next publish from that out-dir would have laundered it
  in. **After reverting an experimental patch, rebuild every out-dir that
  publishes, and grep the artifact, not the source.**
- **The SDK changes exist only on the SSD**, captured as
  `engine/killgate/0001-attach-bytecode-native.patch` (176 insertions, 5 files).
  The checkout itself is **not** in git — reapply the patch to
  `engine/src/flutter/third_party/dart` if the checkout is ever recreated.
- ~~**`--import-dill` CFE crash is unresolved**~~ **RESOLVED as a workaround
  that generalizes — and the binding crux is DEAD (Spike B, 2026-08-05).**
  Feeding `--import-dill` a `--no-aot --no-link-platform` pre-AOT kernel (the
  dynmod recipe) compiled all six spike variants. Load-time resolution works
  when retention is declared: app symbols under `vm:entry-point` OR the
  dynamic interface; `dart:core print` (the canonical `bytecode_reader.cc:1172`
  failure) under `gen_kernel --dynamic-interface` — which accepted a
  `dart:core` entry. Bound bodies execute via `DartEntry::InvokeFunction`,
  including interpreter→host and interpreter→SDK calls. Retention tax on the
  gate program: +0.93% snapshot. See `engine/killgate/README.md` §Spike B and
  `engine/killgate/binding/`. Remaining Route B work is the call-emission
  mode (unchanged), platform-dill hygiene, iOS port, integration.
- ~~**iOS device verification of assets-only patches has not been run.**~~
  **DONE — twice, and it is the load-bearing iOS result.** Device-verified
  2026-08-04 on Shorebird's prebuilt engine (release `5.0.0+1`), then again
  2026-08-05 **on our own engine** (`70974f81`, release `27.0.0+1`), and a third
  time inside the sealed acceptance run (release `34.0.0+1`). The CLI skips the
  linker for `--assets-only` (`ios_patcher.dart` / `ios_framework_patcher.dart`),
  which is what makes an iOS patch producible without `aot-tools.dill`. See the
  RESOLVED sections above for the evidence chains.
- ~~**Serve the `patch` differ from the overlay.**~~ **DONE 2026-08-05.**
  `patch-darwin-arm64.zip`, `patch-darwin-x64.zip` (cross-compiled,
  Rosetta-verified) and `patch-linux-x64.zip` (built on the Linux box) now sit
  in the overlay for the pinned rev and every mapped experimental hash, and
  `overlay_publish.sh` / `publish_ios_overlay.sh` invoke
  `publish_patch_tool.sh` automatically so future publishes carry the host's
  zip. The Caddyfile's `@must_be_local` now owns the Flow-B path space for
  experimental hashes (patch zips, `aot-tools.dill` — loud 404 by design,
  the CLI warns and continues — and `artifacts_manifest.yaml`).
  `patch-windows-x64.zip` stays mirrored (recorded gap). Also fixed:
  `publish_patch_tool.sh` broke on relative `--overlay` paths (zip ran from a
  temp dir); `DEST_DIR` is now absolutized.
- ~~`code_push_server` 1.3.0 is prepped but unpublished.~~ **Published
  2026-07-30** from tag `code_push_server-v1.3.0`: multi-arch (amd64 + arm64)
  at `ghcr.io/mml555/code-push-server:1.3.0`, pulled and booted healthy, and it
  is the image the Phase 4 verification above ran against. Both compose pins
  resolve. Note the tag points at `feat/engine-improvements`, not `main`, so a
  later merge should not re-cut it.
- **State left on the build box** (deliberately, so the rig reproduces): the CDN
  mirror's CA is trusted in its JDK `cacerts` and OS store, and
  `FlutterPlugin.kt` is reverted to stock (correct now that HTTPS works). Undo
  commands are printed by `cdn/tls/trust.sh`.
- Two scratch test apps are installed on the Android device, and their sources
  live under `/data/shorebird-engine/` on the build box. Nothing depends on them.

## Loose ends

- ~~Release `1.0.1+2` is stranded in `draft` on the local server.~~ **Stale as of
  2026-08-09 — that release no longer exists.** It lived on the disposable
  `cps-e2e`/host-8080 rig, which the durable `cps-ios`/`cps-android` pair
  replaced. A scan of every app on both rigs finds exactly one draft, and it is
  the already-documented one: **`1.1.0+1` (release id 40) on `cps-ios`,
  app `airgap-fixture`**, recorded as abandoned in
  [`fixtures/airgap_app/README.md`](fixtures/airgap_app/README.md). It stays
  documented rather than deleted **on purpose** — the control plane exposes no
  release-delete endpoint, and reaching past the API into the database to
  remove a row is a worse precedent than a recorded gap in the numbering. Do
  not "finish the cleanup" by editing the database.
- `overlay_publish.sh` now **has** run end to end (exit 0, 2026-07-30). One gap:
  it re-fetches the Maven modules for the ABIs we did not build from
  `--mirror` (default `localhost:8085`), so it must run somewhere the CDN mirror
  is reachable. From the build box that needs a reverse tunnel to the Mac; without
  it those modules are skipped and the mirror will 404 on them (deliberately, per
  `@must_be_local` in Caddyfile). The Mac's overlay already holds them for
  `dabf1837…` from the original hand-publish.
- **The overlay is backed up in two places, both verified.** 775 MB, sha256
  `b5fc5633c509f64660701e4654d8dfcd839ce023667f7d9dce7125b0420d9b5f`, holding
  both device-verified engines (`dabf1837…` and the Route B `fc184af6…`):
  - `~/shorebird-backups/engine-overlay-dabf1837-fc184af6.tar` on the Mac
  - `/data/shorebird-engine/backups/` on the build box — checksum re-verified
    after transfer, so this one survives losing the Mac entirely.

  Restore with `tar -xf engine-overlay-dabf1837-fc184af6.tar -C selfhost/cdn/`.
  This matters because of the next point: these artifacts cannot be regenerated,
  so losing them means re-proving every Route B claim on device.
- ~~**The engine build is not reproducible.**~~ **Retracted 2026-07-31 — it is.**
  Two clean `android-arm64` builds produced a byte-identical `libflutter.so`
  (`ff98f93c…`) with **0 of 7,366 objects differing**. `gen_snapshot`, the Rust
  updater, and a relink from identical objects are all reproducible too. Scripts
  are checked in as `selfhost/engine/{gs,rust,link,object}_determinism.sh`;
  ~40 minutes per full build on the box.

  **So you _can_ validate an engine change by diffing against a known-good
  artifact**, and the old advice to batch changes rather than iterate is void.

  The earlier observation (same size, unchanged `.data.rel.ro`, differing
  `.text` and `.rodata`) cannot be explained retroactively — that source state
  is gone, so a not-quite-clean rebuild and a tree differing in some generated
  file are equally consistent with it. Two limits on the new result: both builds
  ran on the same host at the same paths, so this is repeatability rather than
  cross-machine reproducibility, and it says nothing about builds straddling a
  `gclient sync`.
- The self-built APK is **arm64-only in practice** — arm/x64 slices pair our
  `libapp.so` with the stock engine.
- ~~A dev API key was printed into a session transcript.~~ Rotated 2026-08-05
  along with `URL_SIGNING_SECRET`; see the rotation note above.
- ~~Branches `feat/experimental-engine-farm` and `feat/asset-patches` are fully
  merged into this one and can be deleted.~~ **Deleted 2026-08-09** after
  confirming both had zero commits absent from `feat/engine-improvements`.

## Verifying your work

**Run CI's commands, not approximations of them — rewritten 2026-08-13, and the
rewrite is the point.** This block used to say `dart analyze lib test # expect 86
issues` for the CLI and listed **no `dart format` check for it at all**. Both
were wrong in the direction that hides failures: CI runs `--fatal-warnings`, so
counting *infos* cannot see a warning, and a gate absent from the runbook is a
gate nobody checks. The CLI's format gate was RED from 2026-08-10 and its
analyze gate RED from 2026-08-11; both went three days unnoticed while this
block reported healthy. Expected counts are recorded below as of 2026-08-13, but
**the exit code is the gate — a count is a corroborating reading, not the test.**

```bash
# code_push_server — CI: .github/workflows/code_push_server.yaml:43,46,58
cd packages/code_push_server && dart format --output=none --set-exit-if-changed . \
  && dart analyze --fatal-infos --fatal-warnings \
  && dart test -x integration                    # expect exit 0; 291 pass

# shorebird_cli — CI: .github/actions/dart_package/action.yaml:61,66
#   (analyze_directories defaults to "lib test", :28-30), reached via
#   .github/workflows/main.yaml:159-164
cd packages/shorebird_cli && dart format --output=none --set-exit-if-changed . \
  && dart analyze --fatal-warnings lib test \
  && dart test -r failures-only                  # expect exit 0; 2514 pass, 2 skipped
#   ^ LOCAL ANALYZE IS A PRE-FLIGHT, NOT THE GATE — it runs a DIFFERENT ruleset
#     than CI. Local Dart is 3.12.2; setup-dart@v1 gives CI latest stable (3.13.0
#     on 2026-08-14), and rules the older SDK does not have cannot fire locally.
#     Measured, not assumed: evidence/analyzer-sdk-gap/

# spelling — CI: .github/workflows/main.yaml:30 -> VGV spell_check.yml@v1, whose
#   modified_files_only defaults to TRUE and is not overridden. CI's gate is
#   INCREMENTAL, so this is the local equivalent, not an approximation of it.
selfhost/scripts/cspell_touched.sh              # exit 0; no NEW findings on added lines
selfhost/scripts/cspell_touched.sh --self-test  # the gate's negative control, 6/6
#   ^ A LOCAL PRE-FLIGHT, WEAKER THAN CI, and measured rather than assumed:
#     cspell_touched.sh checks the lines you ADDED. CI's incremental cspell job
#     checks ENTIRE CHANGED FILES. So local green does NOT imply incremental-CI
#     green — a file you edit drags its inherited findings into CI's check.
#     Established by fork run 31986647895, which reported cspell.config.yaml's
#     pre-existing `sendemail` on a line this lane never touched.
npx cspell --dot --no-progress --no-summary selfhost packages/code_push_server/lib
#   ^ the DECLARED full-tree scope. --dot is load-bearing: without it cspell does
#     not traverse dot-named files and engine/.gclient.template goes unchecked.
#     Proven both halves by scripts/cspell_scope_control.sh.
```

> **The spelling line above was WRONG until 2026-08-16, and the way it was wrong
> is the same way this block was wrong in 2026-08-13.** It read
> `npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib`,
> presented as CI's command. **CI has never run it.** The live job is incremental —
> changed files only — and it is **green**. Run tree-wide, that command reports
> **1,770 findings across 153 files**, so it cannot separate a regression from the
> inherited floor; a gate that is red before your change is not a gate. The
> baseline is recorded in [`evidence/cspell/`](evidence/cspell/README.md), along
> with what promoting it back to a real tree-wide gate would require — including a
> negative control, because reaching zero proves the count moved, not that
> anything is watching it.
>
> **The general lesson, since this is the second time in this block:** an
> approximation of CI's command fails in whichever direction nobody checked. In
> 2026-08-13 it hid two RED gates by counting infos instead of exit codes. Here it
> invented a gate CI never had, and its permanent redness trained readers to skip
> it. Cite the workflow file and line, or do not present it as CI's.

`shorebird_cli` still carries **237 analyzer infos inherited from `main`** — that
is the baseline, so compare against it rather than trying to reach zero. But
infos are exactly the noise the two RED gates hid in: `--fatal-warnings` is what
separates the inherited floor from a fork-introduced regression, which is why the
count is no longer the check. Repo conventions: semantic-commit PR titles, inline
`cspell:words` for one or two files and the global config beyond that, prefer new
commits over amending.
