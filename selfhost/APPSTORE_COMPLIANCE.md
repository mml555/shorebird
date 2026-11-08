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

## 7c. DELTA RE-AUDIT — cell `ac5d3b63…`, 2026-08-25 (P4.1)

**Why it fired.** The compiler cell gained an eighth member,
`route_b_release_probe.aot` — P4.1's release probe. §8 forces a re-audit on any
cell change, so this is the determination.

**Determination: NO RUNTIME DELTA.** Not a re-derivation, and not an assertion
either — the runtime artifacts are byte-identical to the donor and that is the
whole argument:

| artifact in cell `ac5d3b63…` | vs donor `93a3756…` |
|---|---|
| `ios-release/artifacts.zip` (Flutter.framework — the iOS runtime, and the bytecode execution mechanism) | **same** `216a326d81688d1a` |
| `dart-sdk-darwin-arm64.zip` | **same** `bc5948b7e4598f64` |
| `flutter_patched_sdk.zip` | **same** `213948fe75b4c7c4` |
| `flutter_patched_sdk_product.zip` | **same** `8c59cf50881ad44f` |
| `darwin-arm64/artifacts.zip`, `darwin-arm64/font-subset.zip` | **same** `31f88a5e89a56dd4`, `fea5a7433596604d` |
| `engine_stamp.json` | **changed by design** — it records the hash it is filed under, so it is re-derived by the mint |

Six of seven byte-for-byte; the seventh names the address itself. No engine
binary was rebuilt — it was cloned.

**What actually changed, and why it cannot touch §1 or §3.** One new HOST
artifact that runs on the *build machine, before publication*, and reads a JSON
snapshot profile to answer whether a target still has a surviving call site. It
emits no bytecode, is never downloaded to a device, and is not linked into the
app. The release pipeline additionally passes
`--write-v8-snapshot-profile-to=…` to `gen_snapshot`, which writes a
side-file — it does not change what `gen_snapshot` emits into the app.

| invariant | status |
|---|---|
| I1 loader guard | **unchanged** — no anchor of it is in a changed file |
| I2 `PROT_READ` mapping | **unchanged** |
| I3 execution through the pre-existing `InterpretCall` stub | **unchanged** |
| I4 no runtime code generation | **unchanged** |
| new executable-memory path | **none** — the delta is a pre-publication refusal gate |
| new entitlement requirement | **none** |

**Stated positively:** P4.1 makes the system refuse *more* patches than before,
never execute anything new. A gate that can only turn a publication into a
refusal cannot widen what runs on a device. The one artifact this cell adds has
no code path on a device at all.

Verified by `probes/p41_producer_end_to_end.sh` against the **fetched-back**
published bundle (`65a5aba0fbb493de…`, probe `ee144635d144a080`), 13/13.

## 7d. DELTA RE-AUDIT — cell `9b5f040c…`, 2026-08-25 (P4.4)

**Why it fired.** The compiler cell's coverage analyzer moved
(`route_b_analyze.aot` `422dda43…` → `14538a67…`), raising the analysis version
from 8 to 9 so it emits a signature identity per changed member.

**Determination: NO RUNTIME DELTA.** The same six engine artifacts as donor
`ac5d3b63…`, byte-for-byte — `ios-release/artifacts.zip` `216a326d81688d1a`,
`dart-sdk-darwin-arm64.zip` `bc5948b7e4598f64`, both patched-SDK zips, and both
`darwin-arm64` zips. Only `engine_stamp.json` re-derives, because it records the
address it is filed under.

**What changed, and why it cannot touch §1 or §3.** One host artifact that runs
on the build machine before publication. It reads two kernels and reports what
differs; it emits no bytecode, is never downloaded to a device, and is not
linked into an app. The new field it emits is consumed by the producer to REFUSE
a patch whose member changed shape.

| invariant | status |
|---|---|
| I1 loader guard | **unchanged** |
| I2 `PROT_READ` mapping | **unchanged** |
| I3 execution through the pre-existing `InterpretCall` stub | **unchanged** |
| I4 no runtime code generation | **unchanged** |
| new executable-memory path | **none** |
| new entitlement requirement | **none** |

Same argument as §7c, and it is the argument that makes these cheap: **P4.4 can
only turn a publication into a refusal.** A gate that adds refusals cannot widen
what runs on a device.

One thing worth noting positively rather than as an absence: the container now
carries a binding, which IS shipped to devices. It rides as an **additive header
field under format version 1**, and the device-side reader was measured against
it — `probes/p44_container_binding_compat.sh` runs the real
`packaging/patch_container.dart` over a container with a binding and over one
without. That reader refuses an unknown *version* on purpose, so had it also
refused unknown *keys* this would have broken every patch on the shipped engine,
on device, after the CLI reported success. It does not, and that is measured
rather than assumed.

## 7e. DELTA RE-AUDIT — cell `8e659812…`, 2026-08-26 (P6 device epoch)

**Why it fired.** The cell gained two engine-hash-addressed artifacts:
`ios/artifacts.zip` and `ios-profile/artifacts.zip`, built from this same pinned
tree. §8 forces a re-audit on any cell change.

**Determination: NO RELEASE-RUNTIME DELTA.**

`ios-release/artifacts.zip` is **`216a326d81688d1a`** — byte-identical to every
cell back to `2c4443ce`. The iOS *release* engine was not rebuilt, not
repackaged, and not touched. Nor were `dart-sdk-darwin-arm64.zip`
`bc5948b7e4598f64`, either patched SDK, or `darwin-arm64/artifacts.zip`.

**What was added, and why it cannot reach a device.** iOS **debug** and
**profile** engines. `flutter_cache.dart`'s `_iosBinaryDirs` requires all three
iOS groups before an iOS build proceeds, including a release build — so without
them a release could not be built from an empty cache at all. They are
**build-tool dependencies**: a release-mode app embeds the release engine, and
nothing from the debug or profile archives is linked into it or shipped.

That was verified rather than argued: a release built from a genuinely empty
cache on this cell produced `Runner.app` whose embedded engine is the
`216a326d…` release framework, and `isRouteBEngine` is TRUE on those consumed
bytes (`InterpretCall` present in `49182b375aeb858b`).

| invariant | status |
|---|---|
| I1 loader guard | **unchanged** |
| I2 `PROT_READ` mapping | **unchanged** |
| I3 execution through the pre-existing `InterpretCall` stub | **unchanged** |
| I4 no runtime code generation | **unchanged** |
| new executable-memory path | **none** |
| new entitlement requirement | **none** |

Both new archives were built with the same Route B configuration as the release
(`dart_dynamic_modules=true`, `shorebird_use_interpreter=false`) from identical
`engine_version` / `dart_version` / `skia_version`, so they are not a foreign
toolchain admitted through a side door — which is the thing that would have
mattered here.

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
