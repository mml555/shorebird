<!-- cspell:words dylib entitlement entitlements vmmap Mach mobileprovision precompiled interpretable -->
<!-- cspell:words mprotect specializer -->
<!-- cspell:words Shidduch -->
<!-- "Shidduch" names an unrelated app whose distribution profile happens to sit on
     the audit host; it appears once, in OPEN-1, to say what was NOT used. -->

# iOS App Store technical compliance — Route B

**Audited 2026-08-23.** This file is the **frozen technical-compliance invariant**
for Route B. It exists so the question does not have to be re-derived: it records
what was audited, against which exact artifacts, by what method, and what would
force a re-audit.

**What this document is not.** It is not a prediction of an App Review outcome, a
reading of the Review Guidelines, or legal advice. It is a mechanical description
of what the shipped binaries do, stated so that someone who does read the
guidelines can apply them to facts rather than to a summary.

---

## 1. THE INVARIANT

> **Route B downloads interpretable data and executes it only through native code
> that is already present in the signed application.**

Stated as the four properties that make it true, each mechanically checked below:

| # | property | how it is enforced |
|---|---|---|
| **I1** | The downloaded artifact is **never handed to any loader** — not the VM snapshot loader, not `dlopen`, not `application_library_paths` | a sniff on the container's own bytes, ahead of every path that could load it |
| **I2** | The downloaded bytes are mapped **`PROT_READ` only**, then copied into the ordinary Dart heap | `fml::FileMapping::CreateReadOnly` + `malloc` + `ExternalTypedData` |
| **I3** | Execution enters a **stub that was compiled into the signed binary** — the pre-existing `InterpretCall` | `AttachBytecode` ends in `SetInstructions(StubCode::InterpretCall())`, **unmodified upstream Dart** |
| **I4** | **No code is generated at runtime.** Our compiler changes are AOT-time (how the release is built); the device-side additions add no codegen, no mapping, no protection change | the fork's whole runtime delta is auditable and small — §5 |

---

## 2. THE AUDITED ARTIFACT SET — bound, not assumed

Toolchain correctness here is *relational*: every member can be individually
correct while the set is invalid. So the set is named, and each binding is
verified against the bytes that shipped.

| member | value | how it was bound |
|---|---|---|
| **engine cell** | `2c4443cedd654fad8eebd877bbc215edbdd11615` | registered in `cdn/experimental_hashes.map`; the measurement-mode combination (`MEASUREMENT_MODE.md`) |
| **Flutter fork** | `mml555/shorebird-flutter@route-b` HEAD `2c7b8c3ea5`, Route B engine commit `afcbada4b0` over `c15ef63794` (engine `69f9831c`) | checkout `/Volumes/build/route-b/flutter` |
| **Dart SDK fork** | `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c` — *"Route B: Dart SDK support, bytecode producer, and the target->pool instrument"*, over `6b58bb3a72e` (snapshot size accessors), over vanilla `d684a576a6a` (**Version 3.12.2**) | see the byte-level binding below |
| **`dart_sdk_verification_hash`** | `"9e8c898a4d"` in `out/ios_release/args.gn:53` | a **pinned GN arg**, not derived — the SDK hash is configuration |
| **updater** | `f729f958e9be` | present in the shipped engine bytes alongside `ACK_EVENT` and `REQUEUE_FAILED` |
| **specimen** | release 108 / `1.8.0+1`, patch 1, `Payload/Runner.app`, signed **2026-08-20 22:02:54**, `dev.selfhost.killswitchProbe`, team `SK85S6YZP9` | `codesign --verify --deep --strict` → *valid on disk*, *satisfies its Designated Requirement* |

### The Dart-SDK binding, done on bytes rather than on a build log

The shipped `Flutter.framework/Flutter` carries the version string:

    3.12.2 (stable) (Tue Aug 18 16:48:02 2026 -0400) on "ios_arm64"

and `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c` has commit date **exactly**
`Tue Aug 18 16:48:02 2026 -0400`. Marker counts in that same binary:
`f729f958e9be` ×1, `ACK_EVENT` ×1, `REQUEUE_FAILED` ×1, `ROUTEB:` ×8,
`InterpretCall` ×1.

**Why bytes and not the log.** Two real revision-stamp defects were found by
exactly this method — `git` is absent from the ninja action's PATH, and
`.git/HEAD` does not change when a commit lands on a branch. Either produces an
artifact whose stamp silently reads `unknown`, which is indistinguishable, in any
downstream data, from *"the thing you are looking for does not exist"*.

**One coherence note, recorded because it is the kind of thing that bites.**
`out/host_release_arm64_nodm/args.gn` was built at
`dart_sdk_verification_hash = "6b58bb3a72"` — a **different** SDK revision from
the iOS build's `9e8c898a4d`. That is the no-dynamic-modules host build and does
not enter the app, but a mixed set is exactly how an installation becomes invalid
while every artifact in it looks fine.

---

## 3. THE EXECUTION PATH, PROVEN STEP BY STEP

Anchors are against the **shipped checkout**, not the `.patch` files that produce
it, and not `engine/spike/` — which is the abandoned AOT-linker route and ships
nothing.

    downloaded container on disk (patches/{N}/dlc.vmcode)
      │
      │  shell/common/shorebird/shorebird.cc:675
      │     route_b::SniffFile(active_path) == kOk
      │     ─► I1: a Route B container NEVER reaches the VM snapshot loader and is
      │        never inserted into application_library_paths. The sniff is on the
      │        BYTES, because the lifecycle installs every code artifact under the
      │        same `.vmcode` filename, so the name carries no information.
      │
      │  shell/common/shorebird/shorebird.cc:310  InstallRouteBActivationHook
      │  shell/common/shorebird/shorebird.cc:325  fml::FileMapping::CreateReadOnly(path)
      │     ─► I2: fml/mapping.cc:26-42 passes Protection::kRead only;
      │        fml/platform/posix/mapping_posix.cc:26 maps PROT_READ.
      │        PROT_EXEC appears in that file ONLY under Protection::kExecute
      │        (:33), which this path never requests.
      │
      │  shell/common/shorebird/shorebird.cc:333  route_b::Parse(...)
      │     container = "SBRBPTCH" + uint32 version + uint32 headerLen +
      │                 JSON header + concatenated BYTECODE blobs
      │     (format: packages/shorebird_cli/lib/src/route_b_container.dart)
      │     ─► no Mach-O, no dylib, no snapshot. The specimen's patch 1 is
      │        863 bytes total.
      │
      │  shell/common/shorebird/shorebird.cc:457  Dart_RouteBActivatePatchTraced(...)
      ▼
    runtime/lib/object.cc:998   Dart_RouteBActivatePatchTraced  (:990 is the
                                four-argument Dart_RouteBActivatePatch, a
                                delegating wrapper)
      │  :1062  RouteBActivatePatchImpl
      │  :1085  malloc(payload_length) + memcpy
      │  :1089  ExternalTypedData::New(kExternalTypedDataUint8ArrayCid, …)
      │     ─► I2: ordinary heap data owned by a Dart object. The embedder's
      │        read-only mapping cannot back it, because the loader keeps a
      │        reference beyond the call.
      │
      │  :1100  bytecode::BytecodeLoader loader(thread, typed_data);
      │  :1101  loaded = loader.LoadBytecode();          ← upstream Dart
      │  :1106  ResolvePatchTarget(...)                  ← ours (resolution only)
      │  :1120  loaded.GetBytecode()                     ← upstream Dart
      │  :1162  RouteBSaveOriginalCode (ours: remembers the release's own Code)
      │  :1163  target.AttachBytecode(bc)
      ▼
    runtime/vm/object.cc:8413   Function::AttachBytecode   ← UPSTREAM, UNMODIFIED
      │  :8421  set_ic_data_array_or_bytecode(value.ptr())
      │  :8424  SetInstructions(StubCode::InterpretCall())
      ▼
    I3: the function's entry point is now the address of the InterpretCall stub
        inside the signed engine image. Execution of the downloaded bytecode
        happens in runtime/vm/interpreter.cc — UPSTREAM DART, UNMODIFIED, and
        NOT in this fork's diff at all.

**Rollback** uses `runtime/vm/object.cc:8433 RestoreCodeFromBytecode` (ours, 13
lines) which calls `SetInstructions(original)` — putting back the `Code` object
**the release itself shipped**. Nothing new is created; upstream's
`ClearBytecode` is unusable here because it routes through `ClearCode`, which is
`UNREACHABLE` under `DART_PRECOMPILED_RUNTIME`.

**Build configuration** (`out/ios_release/args.gn`): `dart_dynamic_modules = true`
— the upstream Dart bytecode/interpreter support this rests on — and
`shorebird_use_interpreter = false`, i.e. upstream Shorebird's own interpreter
switch is off. Route B uses the standard upstream mechanism, not a bespoke one.

---

## 4. THE SIGNED-BUNDLE AUDIT

Against `Payload/Runner.app` of the release-108 specimen.

| check | result |
|---|---|
| entitlements, complete list | `application-identifier`, `com.apple.developer.team-identifier`, `get-task-allow` — **and nothing else** |
| `com.apple.security.cs.allow-jit` | **ABSENT** |
| `dynamic-codesigning` | **ABSENT** |
| `get-task-allow` | **PRESENT — `true`.** See OPEN-1: this specimen is development-signed |
| provisioning profile | *"iOS Team Provisioning Profile: \*"*, with `ProvisionedDevices` — a **development** profile, team *Jewgo LLC*, expiring 2027-07-31 |
| Mach-O files in the bundle | exactly **three**: `Runner`, `Frameworks/Flutter.framework/Flutter`, `Frameworks/App.framework/App`. No downloaded binary is ever added — a patch adds `dlc.vmcode` under the app's data container, which nothing loads (I1) |
| private Apple frameworks | **zero** `PrivateFrameworks` references across all three binaries. `Runner` and `Flutter` link only `/System/Library/Frameworks/*`, `/usr/lib/*`, `/usr/lib/swift/*`; `App` links only `libSystem` |
| signature | `codesign --verify --deep --strict` → valid, satisfies its Designated Requirement |
| `dlopen`/`mmap`/`mprotect` imports | present in `Flutter` (as in **any** Flutter engine: plugin registration, allocators). **Scope matters:** the Route B code we added contains no call to any of them — see §5. The one mapping on the path is the `PROT_READ` file mapping of I2 |

---

## 5. WHAT THIS FORK ADDS AT RUNTIME — the whole delta, so it can be checked

`git diff d684a576a6a..9e8c898a4d2` over the Dart SDK is **22 files, +2116/-10**.
Sorted by whether it can affect the device at runtime:

| category | files | runtime effect on device |
|---|---|---|
| **AOT compiler / build-time** | `compiler/aot/precompiler.{cc,h}`, `aot_call_specializer.cc`, `dispatch_table_generator.cc`, `backend/flow_graph_compiler*.cc`, `bin/gen_snapshot.cc`, `image_snapshot.h`, `pkg/dart2bytecode/*`, `pkg/front_end/*` | **none.** These change how a release and a patch are *compiled*, on the build host |
| **the Route B entry point** | `runtime/lib/object.cc` (+788) | the activation function, its trace record, target resolution, and original-code save/restore. **No mapping, no protection change, no codegen** — grep of the added lines for `mmap`/`mprotect`/`PROT_EXEC`/`dlopen`/`VirtualMemory` returns only a *comment* reading *"Pool entries are DATA, which is what makes this legal on iOS: no executable"* |
| **rollback helper** | `runtime/vm/object.{cc,h}` (+13/+9) | `RestoreCodeFromBytecode` only — reinstalls the release's own `Code` |
| **headers / API surface** | `include/dart_api.h`, `include/dart_route_b_trace.h`, `dart_api_impl.cc` | declarations and the trace struct |
| **three `dart:_internal` natives** | `bootstrap_natives.h`, `sdk/lib/internal/internal.dart`, `internal_patch.dart` | `attachBytecodeToFunction`, `detachBytecodeFromFunction`, `releaseBuildId` — **named here deliberately**, see the surface note below |
| **the interpreter** | *not in the diff* | `runtime/vm/interpreter.cc` is **upstream and unmodified**. So is `AttachBytecode` |

### Surface note — the three natives, stated rather than buried

Those natives were added for the kill-gate harness and are present in the shipped
engine (their names appear as strings in `Flutter`, since the VM resolves natives
by name; the C symbol `Dart_RouteBActivatePatch` does **not**, being statically
linked). They live in `dart:_internal`, which ordinary application code cannot
import, and production activation does not use them — it uses the pre-main
embedder hook. They are **not** a violation of any property in §1: they attach
bytecode by the same upstream `AttachBytecode` path, with the same
`InterpretCall` outcome.

**Recommendation, not a blocker:** compile the three harness natives out of
production builds, so the shipped surface is exactly the one production uses.
Tracked as a follow-up; the invariant holds either way.

---

## 6. RUNTIME EVIDENCE FROM DEVICE

The trace record was designed so this claim rests on measurement rather than on
reading the source. From the closure run on the audited cell
(`evidence/g15/CL_row5/trace`, `rbtrace v=5`):

    rc=0 attach_entered=1 attach_returned=1
    bc_pre=0  bc_post=1        interp_pre=0  interp_post=1
    uep_post_is_interpret_call=1
    fn_uep_post=0x105758044    interpret_call_ep=0x105758044

The patched function's unchecked entry point **equals** the `InterpretCall` stub's
entry point, sampled in the same run rather than compared against a remembered
constant (stub addresses are per-snapshot). That is I3, observed on hardware. An
earlier specimen shows the same on a different cell
(`evidence/g15/g5_armA_rbtrace.txt`, `rbtrace v=4`).

---

## 7. WHAT IS STILL OPEN — two arms, and they are not equivalent

### OPEN-1 — the entitlement audit must be repeated on a DISTRIBUTION-signed build

The specimen is **development**-signed, so `get-task-allow=true` is present. That
is a property of the profile it was signed with, not of Route B — and the correct
way to establish that is to sign one and look, not to argue it. **Do not close
this by reasoning.**

Procedure: build the same cell's release with an App Store or ad-hoc
**distribution** profile, then re-run §4's table. Expected: `get-task-allow`
absent, `allow-jit` and `dynamic-codesigning` still absent, framework and Mach-O
rows unchanged. Anything else is a finding.

**What is available on the audit host, and what it does and does not settle.**
There is an `Apple Distribution: Jewgo LLC (SK85S6YZP9)` identity — the specimen's
own team — and one App Store distribution profile, which reads
`get-task-allow => false`, `beta-reports-active => true`, and carries no
`ProvisionedDevices`. **That profile is for an unrelated production app
(`SK85S6YZP9.com.ShidduchCard`) and was read, not used.** Resigning the Route B
specimen with it would mean stamping another product's identity onto a test
artifact, and would not be a faithful audit anyway — the app id under test has to
be the real one.

So what it settles is narrow and worth having: a distribution profile sets
`get-task-allow = false` **by construction**, which is the only entitlement that
separates the specimen's set from a distribution set. What it does not settle is
the artifact-level check, which is the whole point of OPEN-1. **Closing this arm
needs a distribution profile for the Route B app id — it does not exist on this
host.**

### OPEN-2 — the VM-region check, and why it has NOT been run yet

The wanted observation: while a Route B patch is active, the process has **no**
`PROT_EXEC` region backed by the downloaded patch bytes.

**This must not be run against the frozen measurement specimen.** Release 108 /
patch 1 is an *eligible* client under `MEASUREMENT_MODE.md`, and a
debugger-attached or interrupted launch of it could enqueue a false
`ambiguous_boot_retry` — injecting exactly the kind of artefact the freeze exists
to keep out of the fleet data. The rig was available at audit time (iPhone 7, iOS
15.8.8, wired, `8cb4bc98…`); availability was not the blocker, the freeze was.

Two acceptable ways to do it, when it is taken:

1. **A separate app id**, so no event it emits can enter the measured
   population, patched through the ordinary pipeline, then inspected.
2. **A fixture-local region walk** — FFI to `mach_vm_region_recurse` from Dart,
   the same primitive class already used for the SIGKILL harness, writing a
   durable on-device witness. No engine change, so it adds no variable to the
   thing under test.

**Precommit for either:** PASS = no `PROT_EXEC` region whose backing file is the
patch path and none covering the payload buffer, with the patch demonstrably
active in the same run (`code patch: N` plus a patched value). FAIL = any such
region. **INVALID** = the patch was not active, or the witness is absent — which
must be scored as *no result*, not as a pass. State the falsifier now: finding an
executable mapping backed by patch bytes would refute I2/I3 as stated here.

**What is already established without it:** I1 and I2 from the shipped source
(the only mapping of those bytes is `PROT_READ`), and I3 measured on device (§6).
OPEN-2 would convert a source-plus-control-flow argument into a direct
observation of the address space.

---

## 7b. DELTA RE-AUDIT — trigger #1 fired 2026-08-25, cell `93a3756…`

**Why it fired.** The Dart SDK lineage moved: the CFE now refuses a `dart:` URI as
the target of `--resolve-private-names-in-library`, and the interface generator
stopped emitting bare private `class:` items. §8's first trigger says that forces a
re-audit.

**Scope of this pass: a DELTA, not a re-derivation.** The question is only whether
anything in §1's four properties or §3's path changed. Nothing did, and the reason
is mechanical rather than argued:

| check | result |
|---|---|
| files changed in the Dart tree | **exactly one:** `pkg/front_end/lib/src/source/source_loader.dart` |
| runtime files changed | **none.** `runtime/lib/object.cc`, `runtime/vm/object.cc`, `runtime/vm/interpreter.cc` untouched |
| engine artifacts in the new cell vs the donor | **byte-identical** — `ios-release/artifacts.zip` `216a326d81688d1a`, `dart-sdk-darwin-arm64.zip` `bc5948b7e4598f64`, `flutter_patched_sdk.zip` `213948fe75b4c7c4`, `flutter_patched_sdk_product.zip` `8c59cf50881ad44f` |
| what the cell actually rebuilt | two HOST artifacts: `dart2bytecode.aot` (`eb22c50f…` → `8dfb3b66…`) and `route_b_gen_dynamic_interface.aot` |
| I1 loader guard, I2 `PROT_READ`, I3 `InterpretCall`, I4 no runtime codegen | **unchanged** — none of their anchors is in a changed file |
| new executable-memory path | **none.** The delta is name RESOLUTION at compile time |
| new entitlement requirement | **none.** No JIT, no dynamic-codesigning |

**So the substantive change is build-time hardening, and the runtime execution
mechanism did not change at all.** That is worth stating positively rather than as
an absence: a compliance claim about how downloaded bytes execute is unaffected by
a change to which NAMES a compiler will resolve, and this cell demonstrates the
separation cleanly — the engine binary was not rebuilt, it was cloned.

**Measured consequence of the SDK change, on the consumer path** (the same test,
the same fixture, only the cell differing):

    old cell 2c4443ce, dart2bytecode eb22c50f
      --resolve-private-names-in-library dart:core  ->  rc=0, COMPILED
    new cell 93a3756…, dart2bytecode 8dfb3b66
      the same invocation                           ->  rc=255, REFUSED
                                                        "which is a platform library"

Verified on the FETCHED-BACK bundle, not the build directory. Every one of the
seven cell files matches the cell manifest by digest.

**What this pass did NOT re-check:** §4's signed-bundle audit and §6's device
trace. Neither can have moved — no engine bytes changed — but neither was re-run,
and OPEN-1/OPEN-2 stay exactly as §7 leaves them.

## 8. WHEN THIS MUST BE RE-AUDITED

Not on a schedule — on any of these:

* the **Dart SDK fork revision** moves (a new `dart_sdk_verification_hash`), or
  the Flutter fork's Route B commit changes;
* anything is added to `runtime/lib/object.cc`'s Route B block, or `AttachBytecode`
  / `interpreter.cc` / the `StubCode::InterpretCall` path stops being upstream;
* the **container format** gains any payload that is not bytecode — in particular
  anything Mach-O-shaped;
* the `SniffFile` guard at `shorebird.cc:675` moves, weakens, or starts keying on
  a filename instead of bytes;
* `dart_dynamic_modules` or `shorebird_use_interpreter` changes value;
* an entitlement is added for any reason;
* a plugin or dependency is added that maps executable memory, or the app gains a
  fourth Mach-O;
* the three `dart:_internal` natives grow a fourth, or become reachable from
  application code.

`compatibility.yaml` is the provenance authority for what actually ships; this
file is the compliance reading of it. If they disagree, `compatibility.yaml` is
right about the bytes and this file is stale.
