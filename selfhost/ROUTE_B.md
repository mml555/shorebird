<!-- cspell:words killgate dynmod tearoff dartaotruntime disqualifiers APFS DNDEBUG packageable overengineer -->
<!-- cspell:words sshkey publickey -->

# Route B — iOS Dart code push. Start here.

**Read this first if you are picking up Route B.** It is the plan of record.
Background lives in [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) (evidence chain) and
[`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md) (the staged plan this
executes). [`HANDOFF.md`](HANDOFF.md) is the working log — useful, long, and
not required reading before you start.

## The capability statement, unchanged

> **Android Dart code push and iOS asset push are complete and independent.
> iOS Dart code push has a selected, de-risked architecture, but the production
> compiler/runtime integration has not been built yet.**

Selected is not built. Two kill-gate spikes passed and Route B was chosen on
that evidence; the harness proved the *mechanism* and produced no shippable
path. Do not let a passing spike be reported as a working feature.

## What you are building, in one shape change

Route B is **not** building a Dart interpreter. Vanilla Dart 3.12.2 already
contains everything that would have meant reproducing Shorebird's private fork,
behind the `dart_dynamic_modules` GN flag: bytecode execution, `InterpretCall`,
`Function::AttachBytecode`, and the runtime ability to redirect a `Function`
into interpreted bytecode.

Route B is the **binding and dispatch layer** that lets a normal AOT Shorebird
app opt *specific* calls into that machinery. Today an AOT call says:

```
call this compiled machine-code target
```

A patchable call has to say:

```
call this Dart Function object, through its current entry point
```

Normally that entry point *is* the AOT implementation, so nothing changes and
nothing is slower except the call sequence itself. After a patch:

```
AttachBytecode(Function X, newBytecode)
  -> Function X now enters the interpreter
  -> existing callers start running patched Dart
```

No rewriting of executable pages. No new VM. No second runtime. That is the
whole idea; everything below is making it safe, general, packageable,
measurable, and compatible with the existing updater lifecycle.

## The first success criterion — keep it almost stupidly small

Do not aim at "arbitrary Dart patches anywhere". Aim at this:

> A real release on an iPhone contains **one** patchable Dart function.
> `shorebird patch` changes that function. The existing updater receives the
> patch. `AttachBytecode` activates it. **The UI visibly changes.** Rollback
> restores the original AOT behavior.

When that loop survives release → patch → rollback, Route B is real. Widening
the supported surface comes after, deliberately, from an inventory of call
forms — not before.

## What is already proven (do not re-litigate)

| question | answer | where |
|---|---|---|
| Interpreter present in a precompiled runtime | **Yes** — 48 `Interpreter` symbols + `_InterpretCall` in `dartaotruntime` | `engine/killgate/` |
| An AOT function's body replaceable at runtime | **Yes** — `AttachBytecode`, `IsInterpreted` 0 → 1 | Spike B |
| Interpreter executes the replacement | **Yes** — returned `NEW` via `DartEntry::InvokeFunction` | Spike B |
| Symbol binding at load time | **Yes** — under `vm:entry-point` or the dynamic interface; +0.93 % snapshot on the gate program | Spike B |
| Call site locatable and rewritable | **Yes** — 1 of 2,237 global-pool slots | Spike A |
| Entering the interpreter *from* an AOT call site | **No** — this is the work | [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) |

Two routes were tried and ruled out for concrete reasons, both recorded in
`IOS_CODE_PUSH.md`: supplying the descriptor at the call site is necessary but
not sufficient (`InterpretCall` also wants the `Function` in `FUNCTION_REG`,
which on arm64 is carrying an argument), and leaving calls unlinked would
require `CallStaticFunction`, which patches the call site — writing executable
memory, illegal on iOS.

## Five things to build, then four to prove

The work is five real pieces. The remaining steps are validation, and they are
deliberately last: each is cheap once the mechanism exists and expensive to
discover after shipping.

### 1. Patchable call emission — the core VM/compiler change

For functions chosen as patchable, arm64 call generation must stop baking in a
direct AOT target and instead emit a sequence carrying enough identity to
dispatch through the `Function`. It has to line up with the existing
`InterpretCall` calling convention. File:line below.

**This is the first real engineering problem.** Everything else waits on it.

### 2. Make the necessary symbols survive AOT

Patch bytecode has to refer to things already in the app and SDK, so release
compilation must retain what a future patch might bind to rather than
tree-shaking it away. This is where `dart_dynamic_modules` and the
frontend/SDK setup matter.

**Spike B already proved this model works** via the dynamic interface, at
+0.93 % snapshot on the gate program. This is productizing, not researching.

### 3. Stable target identities — the binder

The CLI and server need a deterministic answer to *"this bytecode belongs to
which function in the installed release?"*, and the runtime cannot lean on
addresses or incidental object-pool positions.

**Do not overengineer this.** The identity contract only has to be stable
between *a specific release* and patches built for that release. A universal
Dart ABI is not the goal and would be a much larger project.

### 4. Package and activate the patch

A **versioned container**, not a filename convention — the spike's `*.vmcode`
naming is bring-up scaffolding and must not become the contract. Roughly:

```
format version
release compatibility identity
target functions
bytecode payload(s)
metadata / hashes
```

Then the updater: download → validate against the installed release → bind
targets → `AttachBytecode` → activate transactionally → preserve rollback.
This is where Route B meets the existing Shorebird lifecycle rather than
inventing a parallel one.

### 5. Make `shorebird patch` produce it

The point at which this becomes a feature instead of a VM experiment:

```
shorebird release   ->  patchable AOT application
  (change Dart)
shorebird patch     ->  bytecode payload + target bindings
                          -> existing updater
                             -> AttachBytecode
                                -> new Dart behavior
```

### Then prove it

6. **Host integration tests.**
7. **Real-app size and frame-time benchmark.** ← veto
8. **Physical-iPhone gate** — release, Dart behavior actually changes, sane
   patch coverage, rollback. ← veto
9. **Sealed independence regression for iOS code patches.**

Either veto can still kill the approach, which is why they are gates and not
chores.

## The design decision to make before writing code

**Define what "patchable" means in the first implementation, narrowly:**

> Static Dart calls, explicitly compiled in Route-B patchable mode.

Do not start by covering every invocation shape — instance calls, dynamic
dispatch, closures, tear-offs, getters/setters, constructors, FFI. The first
job is proving one path end to end:

```
AOT caller -> Function-based patchable dispatch -> attached bytecode
```

Once that survives release/patch/rollback, inventory the call forms and expand
on purpose. Every widening before then multiplies the ways the first proof can
fail for reasons unrelated to the mechanism.

### Where to work

| file | why |
|---|---|
| `runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc:598` `EmitOptimizedStaticCall` | already carries `arguments_descriptor`; the descriptor-loading change goes here |
| `…:397` `GenerateStaticDartCall` | the two existing forms (PC-relative vs pool-mediated) to model the third on |
| `…/flow_graph_compiler.cc:3535` `CanPcRelativeCall` | `precompiled_mode && !force_indirect_calls && same_loading_unit` — the switch between them |
| `runtime/vm/compiler/stub_code_compiler_arm64.cc:3137` `GenerateInterpretCallStub` | the register contract to satisfy (`R0` Function, `R4` descriptor) |

**Release-time consequence to settle early:** an app must be *built* patchable.
`--force_indirect_calls` alone costs ~4 % snapshot size (measured: 838,560 →
871,520 bytes on a toy program); the new mode will cost a little more. A patch
cannot retrofit this onto an already-shipped app, exactly as Shorebird's layout
pinning cannot.

## The rig you are inheriting

The infrastructure track is **closed**. You should not need to do rig work to
start, and if you find yourself doing it, check whether it is already solved.

| | |
|---|---|
| iOS engine | `70974f81…` — our own, vanilla Dart + `engine/000x` patches, device-verified |
| Android engine | `760e3fab…` — ditto, full device lifecycle proven |
| iOS build host | this Mac, `/Volumes/build/ios-engine` (external SSD, APFS, **no spaces in the path** — depot_tools/gclient/GN break on them) |
| **Route B tree** | `/Volumes/build/route-b/flutter` — **created 2026-08-09**, its own checkout as required below. APFS clone of the iOS tree + the killgate patch; `dart_dynamic_modules = true` |
| Android build host | Hermes VPS, `ssh -i sshkey20.120.104.70.pem -p 13549 jewgo@20.120.104.70`, `/data/shorebird-engine` — the `-i` is **not optional**, and without it you get `Permission denied (publickey)`, which reads like a dead box |
| Control planes | `cps-ios` :18080, `cps-android` :18081 |
| Rig state | `~/shorebird-rig/{control-plane,config,secrets}` — see [`fixtures/CONTROL_PLANE_DATA.md`](fixtures/CONTROL_PLANE_DATA.md) |
| Acceptance fixture | [`fixtures/airgap_app`](fixtures/airgap_app) — committed, reproducible |
| Mirror | `selfhost/cdn`, with sealed and TLS modes |

Commands worth knowing before you touch a build:

```bash
selfhost/engine/dart_patches.sh --dest <dart-checkout> --verify   # ALWAYS first
selfhost/cdn/audit_overlay.sh --hash <h> --cell <macos-ios|linux-android>
selfhost/scripts/prepare_ios_endpoint.sh --mode lan
selfhost/scripts/prepare_airgap_fixture.sh --leg ios --app-id <id>
```

## Before Step 1 — one thing left

Items 2 and 3 were done on 2026-08-09 and are kept below as the record of what
exists and what the baseline is. **Only item 1 is outstanding, it needs
physical hands on the phone, and it does not block Step 1.**

### 1. Check the iPhone Local Network setting, once — STILL OPEN

Settings → Privacy & Security → Local Network → *Airgap Probe*. If it resolves
the device→control-plane gap, good. **If it does not, record the result and move
on exactly as planned** — device networking gets dealt with again at the
physical-device gate, and it is not a reason to delay Step 1.

### 2. ~~Create a DEDICATED Route B Dart checkout~~ — DONE 2026-08-09

**`/Volumes/build/route-b/flutter`.** Reproduced by
[`engine/route_b/create_checkout.sh`](engine/route_b/create_checkout.sh), built
by [`engine/route_b/build_host.sh`](engine/route_b/build_host.sh).

Why it had to be its own tree, kept because it is the reason not to "simplify"
this later: Route B needs `dart_dynamic_modules = true`, the SDK changes, *and*
VM/compiler changes at once. The killgate SDK edits touch
`sdk/lib/_internal/vm/lib/internal_patch.dart` and `sdk/lib/internal/internal.dart`,
which compile into `platform_strong.dill` **regardless of the GN flag**, so
mixing them into an iOS engine build fails the AOT step with
`Unexpected tag 4 (Field)` — a message that names nothing useful. Sharing a
checkout here is precisely the ambient-state trap the previous session spent
itself removing.

The clone is an **APFS copy-on-write clone** (`cp -Rc`): 43 GB in 84 seconds
for **zero** additional bytes, versus a multi-hour `gclient sync`. Blocks stay
shared until one side writes, so the two trees diverge only where you edit
them. The cloned `out/` is dropped rather than kept — it carries the source
tree's absolute paths and the wrong GN config.

State as created, verified by content rather than by exit code:

| | |
|---|---|
| flutter revision | `c15ef6379` (the pinned `flutter_revision`) |
| Dart patches | `0001` / `0004` / `0005` / `0006` — `--verify` green before *and* after |
| killgate patch | `0001-attach-bytecode-native.patch` applied; all four sentinels present |
| engine-side patches | inherited by the clone (`shorebird_patch_assets_path`, `PatchCarriesCode`) |
| GN | `dart_dynamic_modules = true`, `target_cpu = "arm64"`, Dart from source |

Still true and still the rule: run `dart_patches.sh --dest <checkout> --verify`
on **every** tree you build from, and after any `gclient sync`.

### 3. Re-run the rig preflight

Not because the infrastructure needs revalidation — it is closed and guarded —
but so you know you are starting from the recorded baseline:

```bash
selfhost/cdn/audit_overlay.sh --hash 70974f811d448da19a927c581678ef1dbd33605c --cell macos-ios
selfhost/cdn/audit_overlay.sh --hash 760e3fabffbf31b4e86919a0ef47d6ce5f182991 --cell linux-android
selfhost/scripts/prepare_ios_endpoint.sh --mode lan
selfhost/engine/dart_patches.sh \
  --dest /Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart --verify
```

**Baseline recorded 2026-08-09**, so you have something to compare against:
both cells **AUDIT CLEAN** (macos-ios 13 owned-built, linux-android 18
owned-built, 0 missing-required on each); `dart_patches.sh --verify` green on
both the iOS tree and the Route B tree; `cps-ios` :18080 and `cps-android`
:18081 up and healthy; iPhone 7 (`8cb4bc98…`, iOS 15.8.8) and Android
`3f72a543` attached; Hermes reachable with `hermes-gateway` active and 373 GB
free on `/data`; `/Volumes/build` mounted with 371 GB free.

Then start Step 1.

## Traps that will bite you

These are not hypotheticals; each one cost real time.

1. **The killgate rig and the iOS-engine rig cannot share one Dart checkout.**
   *(Already acted on — `/Volumes/build/route-b` exists. Kept so nobody
   "consolidates" the two trees later to save disk they are not actually
   spending: the clone is copy-on-write.)*
   `engine/killgate/0001-attach-bytecode-native.patch` modifies
   `sdk/lib/_internal/vm/lib/internal_patch.dart` and `sdk/lib/internal/internal.dart`
   — **SDK sources**, which compile into `platform_strong.dill` regardless of
   the GN flag. Mixing them into an iOS engine build fails the AOT step with
   `Unexpected tag 4 (Field)`, which names nothing useful. Route B needs
   `dart_dynamic_modules = true` *and* those edits, so **give it its own
   checkout** and run `dart_patches.sh --verify` on both.

2. **Experimental instrumentation does not stay in the production tree.** Spike
   A's `--dump_global_object_pool_to` sat in the shared Dart source and made
   every out-dir built from that tree carry it. Reverted 2026-08-07. Keep the
   patch file, not the working-tree edit.

3. **`gclient sync` silently discards `0004`/`0005`/`0006`.** `managed: False`
   protects the flutter checkout's git state, not the DEPS-managed subtrees.
   Recovery is `dart_patches.sh --apply`; the point is to run `--verify` after
   *any* sync, before wasting a build.

4. **The engine hash is sha1 of the Flutter binary only.** A `gen_snapshot`-only
   change republishes under the *same* hash — delete `bin/cache/engine.stamp`,
   `engine_stamp.stamp` and `bin/cache/artifacts/engine/ios-release` or the
   build silently reuses the old compiler.

5. **Snapshot and kernel formats are welded to the tree that produced them.**
   The whole host toolchain must share one tree *and* one GN config:
   `frontend_server_aot` → kernel → `gen_snapshot` → snapshot, against the
   platform dill. A mixed set installs fine and dies at launch with
   `Wrong full snapshot version`.

6. **"It built" proves nothing about a fork/backend pairing.** A mismatched
   frontend/backend compiles cleanly and only fails on the device, which is why
   `dart_sdk_compatibility.dart` is an identity check rather than a probe.

7. **A fast loop exists — use it.** No Xcode, no device, no server:
   `gen_snapshot --deterministic --snapshot_kind=app-aot-assembly
   --assembly=/tmp/out.S app.dill` reproduces a compiler crash in 0.24 s, and
   `ninja -C out/host_debug_arm64 -j8 gen_snapshot` rebuilds in ~80 s. The
   debug host build prints a full stack and the crashing function's CFG.

8. **`ASSERT` is compiled out** in `gen_snapshot` (`-DNDEBUG`) *and* in the
   `host_debug_arm64` build (`dart_runtime_mode=develop`). A VM invariant you
   are relying on may be silently violated. Turn the relevant `ASSERT` into
   `OS::PrintErr` + `Profiler::DumpStackTrace(false)` rather than trusting it.

## The one open non-Route-B item

**iOS device → control-plane reach is blocked** by device Local Network
permission state. The iPhone sends nothing to `cps-ios` — neither the Dart
beacon nor the native updater — on either transport, while the app renders
correctly. Next step is one device setting, tried once: Settings → Privacy &
Security → Local Network → *Airgap Probe*.

**This lands on Route B**, because step 9 needs reliable iPhone communication
regardless. If the setting does not resolve it, harden the device rig as part
of that step rather than as separate infrastructure work. Full reasoning:
[`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md).

## What not to do

- **Do not start Track C (hot restart).** It adds a second runtime lifecycle
  axis before Route B's activation/rollback model exists. It layers on top of
  Route B, not beside it.
- **Do not chase the TFA root cause** as a prerequisite. It is a real
  compiler-correctness project ([`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md)) and
  the four compensating patches are device-verified. Deleting them is a
  cleanup, not a blocker.
- **Do not reopen the infrastructure track.** Artifact ownership, the mirror,
  the fixture and the rig state are closed and guarded. If a guard fires, it is
  telling you something true.
- **Do not widen the sealed-run claim to "no network."** The criterion is
  *nothing closed is required*. GitHub, pub.dev and Apple's signing
  infrastructure are all permitted; none of them serves a Shorebird artifact.
- **Do not build a second interpreter.** The one in vanilla Dart is the one.
- **Do not try to make every AOT call patchable immediately.** See the design
  decision above; breadth before the first working loop is how this explodes.
- **Do not invent writable-executable-page patching on iOS.** It is illegal
  there, and it is the reason the pool-rewrite and unlinked-call routes were
  ruled out.
- **Do not pursue Route A / object-pool relinking.** That decision is made.
- **Do not change the infrastructure or mirror architecture.** Closed and
  guarded; a firing guard is telling you something true.
