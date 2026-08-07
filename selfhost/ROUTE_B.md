<!-- cspell:words killgate dynmod tearoff dartaotruntime disqualifiers APFS DNDEBUG -->

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

## What you are building

A **binder**, not an interpreter. Vanilla Dart 3.12.2 already ships the
interpreter, the `InterpretCall` stub and `Function::AttachBytecode`, all behind
the `dart_dynamic_modules` GN flag. That is the part that would have meant
reproducing Shorebird's private fork, and it is not needed.

What is missing is one compiler feature. AOT's static-call convention passes
**neither the callee `Function` nor an arguments descriptor**, because it never
expects the callee to change. So a patchable call has to be *emitted
differently at release time*: keep the callee `Function` in a pool slot, load it
into `FUNCTION_REG`, load the descriptor, branch through
`Function::entry_point_`.

Everything that form touches at runtime is **data** — a pool slot and a field
read — so it is iOS-legal, no executable page is written. Patching then reduces
to `AttachBytecode` repointing `entry_point_`, with no pool rewrite at all.

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

## The ten steps

Ordered so the cheap disqualifiers come before the expensive integration.

1. **arm64 patchable call emission** — the compiler feature above.
2. **Dynamic-interface retention** — retain and bind app + SDK symbols using
   the mechanism Spike B proved.
3. **Stable target identity** — how a patch names the function it replaces,
   surviving recompilation.
4. **Versioned payload format** — an explicit type/header. **Not** the
   provisional `*.vmcode` filename trick, which is bring-up scaffolding and
   must not become the contract.
5. **CLI packaging** — produce and upload the payload.
6. **Transactional updater/runtime activation** — apply, roll back, survive a
   boot crash.
7. **Host integration tests.**
8. **Real-app size and frame-time benchmark.** ← veto
9. **Physical-iPhone code-patch/rollback gate** — release, Dart behavior
   actually changes, sane patch coverage, rollback. ← veto
10. **Sealed independence regression for iOS code patches.**

Steps 8 and 9 are deliberately late: they are cheap once the mode exists and
expensive to discover after shipping. Either can still kill the approach.

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
| Android build host | Hermes VPS, `ssh -p 13549 jewgo@20.120.104.70`, `/data/shorebird-engine` |
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

## Traps that will bite you

These are not hypotheticals; each one cost real time.

1. **The killgate rig and the iOS-engine rig cannot share one Dart checkout.**
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
