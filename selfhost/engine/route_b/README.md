<!-- cspell:words killgate dynmod dartaotruntime APFS gclient depot caffeinate -->
<!-- cspell:words devirtualize devirtualizes devirtualized megamorphic movz uxtx -->
<!-- cspell:words SBRBPTCH sbrb routebios interpretcall jank janky frametime -->

# Route B — the dedicated build tree

The plan lives in [`../../ROUTE_B.md`](../../ROUTE_B.md). This directory is only
the two scripts that stand up the tree it is built in.

```bash
selfhost/engine/route_b/create_checkout.sh   # ~90 s, ~0 bytes
selfhost/engine/route_b/build_host.sh        # run under screen, see below
```

## Why Route B gets its own checkout

Route B needs three things at once that no existing tree can hold together:
`dart_dynamic_modules = true`, the killgate SDK changes, and the VM/compiler
changes that are Step 1.

The killgate patch modifies `sdk/lib/_internal/vm/lib/internal_patch.dart` and
`sdk/lib/internal/internal.dart`. Those are **SDK sources**, so they compile
into `platform_strong.dill` *regardless of the GN flag*, and an iOS engine
build that picks them up dies at the AOT step with `Unexpected tag 4 (Field)` —
a message that names nothing useful and costs an afternoon. So the shipping
iOS-engine tree at `/Volumes/build/ios-engine` stays clean, and Route B works
in `/Volumes/build/route-b`.

## The clone is free

`create_checkout.sh` uses `cp -Rc`, an APFS copy-on-write clone: 43 GB in 84
seconds for zero additional bytes, against a multi-hour `gclient sync` over the
network. Blocks stay shared until one side writes, so the trees diverge only
where you actually edit them.

Do not "consolidate the duplicate checkouts" later to reclaim disk. There is no
disk to reclaim, and merging them re-creates the exact failure above.

The cloned `out/` is deleted rather than kept: its ninja files carry the source
tree's absolute paths, and its GN config is the wrong one.

## Two rules this tree does not exempt you from

- **`dart_patches.sh --verify` before any build**, on this tree like every
  other, and again after any `gclient sync` — `managed: False` protects the
  flutter checkout's git state, not the DEPS-managed subtrees, so a sync
  silently discards `0004`/`0005`/`0006`.
- **Verify patches by content, never by exit code.** A wrong `-p` level makes
  `git apply` match no files, change nothing, and exit 0. Both scripts here
  check sentinel strings in the files for that reason.

## Running the build

Never as a harness background task — harness cleanup has killed long builds on
this host twice. `caffeinate` handles the other killer, idle sleep.

```bash
screen -dmS routeb bash -c 'caffeinate -is selfhost/engine/route_b/build_host.sh'
tail -f /Volumes/build/route-b/logs/route_b_host_*.log
```

## Step 1 — DONE 2026-08-09, at the host-gate level

`0001-patchable-static-calls.patch` adds a third static-call form on arm64,
behind `--patchable_static_calls`. AOT's two existing forms both resolve the
callee at compile time — a PC-relative branch bakes its address, and the pool
slot is patched by `BindStaticCalls` to hold the callee's `Code` — so neither
consults the `Function`, and `AttachBytecode` cannot redirect them. The new form
emits:

```
ldr r4, [pp, #N]   _ImmutableList          ; ARGS_DESC_REG  (already there)
ldr r0, [pp, #M]   Function 'greet'        ; FUNCTION_REG
ldr lr, [r0, #7]                           ; Function.entry_point_
blr lr
```

Normally `entry_point_` *is* the AOT implementation, so nothing changes but the
call sequence. After `AttachBytecode` it is the `InterpretCall` stub, whose
register contract is exactly what the sequence establishes.

Result on the kill gate, same program, only the flag differing:

| call shape | flag off | flag on |
|---|---|---|
| direct | OLD | **NEW** |
| tear-off | OLD | **NEW** |
| dynamic | OLD | **NEW** |
| apply | OLD | **NEW** |
| verdict | `GATE: BASELINE` | **`GATE: PASS`** |

Snapshot cost on that program: **+1.88 %** (881,560 → 898,144 bytes), against
~4 % for `--force_indirect_calls` alone. **This is a toy program and not the
veto.** Step 7's real-app size and frame-time benchmark is the veto, and nothing
here anticipates it.

One deliberate scope choice in the patch, explained in its comments: it does
**not** call `AddStaticCallTarget`, because that records a
`Code::kCallViaCode` site and `BindStaticCalls` would then run
`CodePatcher::PatchStaticCallAt` over a sequence that is not the pool-load shape
that patcher expects.

It first landed in `EmitOptimizedStaticCall` on the assumption that
`EmitTestAndCall` — the other route into `GenerateStaticDartCall` — supplied no
arguments descriptor. **That assumption was wrong**: `EmitTestAndCallLoadReceiver`
loads `ARGS_DESC_REG` unconditionally. Checking it is what made the widening
below a two-line move rather than a redesign, and the patch now records the
precondition so a third caller cannot quietly break it.

**What this is not.** It is one call form working in a host harness. Steps 4–5
(the versioned container, and `shorebird patch` producing one) are untouched,
and the iOS port and both vetoes are still ahead.

### Widening — measured, not assumed

`inventory/` is a call-form inventory: one program exercising the shapes AOT
actually emits, each patched in turn, so widening is driven by evidence rather
than by guessing which shapes matter.

```bash
selfhost/engine/route_b/inventory/run_inventory.sh
```

| form | dispatch AOT chose | patchable |
|---|---|---|
| top-level static | form (c) | **yes** |
| static method on a class | form (c) | **yes** |
| instance method, monomorphic | devirtualized to a static call | **yes** |
| instance getter | devirtualized to a static call | **yes** |
| dynamic instance call | `EmitTestAndCall` cid chain | **yes** — after widening |
| statically-typed polymorphic call | **dispatch table** | **no** |

Two of those deserve comment. Monomorphic instance methods and getters came out
patchable **for free** — AOT devirtualizes them into static calls, so form (c)
already covered them; the inventory discovered that rather than the code
enabling it. And the dynamic instance call needed the one real widening: it
lowers to `EmitTestAndCall`, a cid-check chain whose branches were PC-relative
direct calls, so form (c) moved from `EmitOptimizedStaticCall` into
`GenerateStaticDartCall`, which both paths share. Its precondition — that
`ARGS_DESC_REG` is loaded — holds for both callers, and the patch says where to
check if a third one ever appears.

**Dispatch-table calls are the one genuinely unreachable form, and they are a
different order of work.** The call site is:

```
movz r0, #0xec                    ; folded (cid, selector) slot
ldr  lr, [r21, lr uxtx scaled]    ; r21 = DISPATCH_TABLE_REG
blr  lr
```

The table stores **raw entry-point addresses**, not `Function`s, and the site
sets up neither `R0` nor `R4`. So there is no cheap version of this:

- *Rewrite the table at patch time.* The table is data, so this is legal on iOS
  — but the stub it would point at needs `R0`/`R4`, which the call site does not
  provide. Not sufficient on its own.
- *Change `EmitDispatchTableCall` to dispatch through the `Function`.* Correct,
  and it taxes **every instance call in the program** — landing directly on the
  step 7 size and frame-time veto.

Deciding between those wants the real-app benchmark first, which is why this
stops here rather than guessing. Note the practical consequence for step 5: a
patch's coverage is *not* "any Dart function", and the link-percentage figure
Shorebird reports has a direct analogue here.

## Step 2 — symbol retention, and the policy the measurement forced

Patch bytecode does not resolve against the base snapshot for free: AOT drops
library dictionaries, and Spike B's first replacement died in
`bytecode_reader.cc:1172` with *Unable to find function print in
Library:'dart:core'*. Retention has to be declared at release time via
`gen_kernel --dynamic-interface`.

Spike B declared three members by hand. A release cannot — nobody knows which
members a future patch will touch. `pkg/vm/dynamic_interface.md` offers the
lever: a `library:` item with no `class:` retains every public class and member
of that library. So the release chooses **breadth**, not symbols, and
`gen_dynamic_interface.dart` generates that from the app's own kernel.

**The obvious policy is not shippable, and the measurement is the reason.**
`measure_retention.sh` sweeps breadth against the call form, on the gate program:

| retention breadth | plain | + call form |
|---|---|---|
| none (stock AOT) | — | +1.88 % |
| app libraries only | +0.89 % | +2.78 % |
| **app + named SDK members** | **+0.90 %** | **+4.64 %** |
| app + WHOLE `dart:core` | **+309.90 %** | +322.99 % |

Retaining the app's own libraries whole is effectively free, and matches Spike
B's +0.93 %. Retaining `dart:core` whole is a **four-fold snapshot** — a library
item keeps every public member of every public class, and AOT can no longer
tree-shake any of it.

So the shipping policy is **asymmetric on purpose**: whole-library for the app,
an explicit member list for the SDK. That one decision is the difference between
+4.64 % and +323 %. The default SDK list is deliberately tiny (`dart:core#print`)
— widen it from evidence about what patches actually call, and re-run the sweep
when you do. `--sdk-libraries` still exists so the expensive option stays
measurable, not because anything should ship it.

### Proving it functionally, not just by size

```bash
selfhost/engine/route_b/verify_binding.sh
```

runs steps 1 and 2 together: a replacement body that calls `print()` — an SDK
symbol, retained by the generated interface — and checks the value arrives back
through ordinary Dart call sites. The two halves fail differently on purpose:

- no `BOUND` line → **retention** failed (step 2);
- `BOUND` but call shapes `OLD` → **dispatch** failed (step 1).

Passing 2026-08-09: `BOUND` once per call shape, all four returning
`NEW-PRINTED`.

## Step 3 — target identity, which was smaller than the plan expected

The plan framed this as *"the runtime cannot lean on addresses or incidental
object-pool positions"*, which reads like a release must carry a bespoke target
table. It does not, and one probe settled it.

```bash
selfhost/engine/route_b/identity/probe_retention_lookup.sh
```

Step 2's whole-library retention lowers to `@pragma('dyn-module:callable')`,
which the VM treats exactly like `vm:entry-point`. So with every
`vm:entry-point` **stripped from the program**, all targets still resolve by
name at run time. Step 3 is therefore naming and bookkeeping, not runtime
lookup — do not build a target table.

### The coverage hole that probe found

A `library:` item retains **public members only** — pkg/vm's spec says so, and
the consequence is concrete: attaching to a private function failed with
`function _report not found` while its own library was retained whole. Real apps
are mostly private code, so a release shipping that policy would have reported
broad coverage and delivered very little.

`gen_dynamic_interface.dart` now emits an explicit `member:` entry per private
app member. Cost on the inventory program: **+0.01 %** (945,280 → 945,384
bytes). The VM's `_name@<library key>` mangling is not our problem —
`Library::LookupLocalObjectAllowPrivate` applies it, so the plain source name is
what to emit and what to hand the runtime.

### The manifest

```bash
selfhost/engine/route_b/identity/gen_target_manifest.dart --dill app.dill
```

emits `{library, class, name, kind, vmName, selector, reachable, reason}` per
target. Structured fields, never a joined string: the harness split
`Class.name` on the first dot and made callers know that a getter is stored as
`get:name`, which is a VM internal leaking into what becomes a wire contract.
`selector` is composed here so no caller has to know either rule.

**`reachable` is the point of the manifest, not a decoration.** Step 1's
inventory established that coverage is not "any Dart function", so each entry
says what it is:

| verdict | meaning |
|---|---|
| `yes` | static-shaped call — emitted as the patchable form |
| `conditional` | instance member — reachable where the call site devirtualizes or uses the cid chain, **not** where it becomes a dispatch-table call |
| `no` | abstract; call sites dispatch to implementations |

`conditional` is deliberate rather than evasive: whether a given call site
devirtualizes is decided per-site by the precompiler and is **not** visible in
the kernel the manifest is generated from. Reporting a guess as a fact is how a
link percentage becomes a lie. Turning `conditional` into a per-site count wants
snapshot-side data, and belongs with step 5's coverage reporting.

## Step 4 — the container, and the rollback that did not exist

```bash
selfhost/engine/route_b/packaging/verify_container.sh     # 10 checks
```

The spikes shipped a `*.vmcode` file whose meaning came entirely from its
filename and the fact that exactly one function was ever patched. A real patch
carries several targets, must refuse the wrong release, and must be verifiable
before anything is attached — none of which a naming convention can express.

```
magic       8 bytes   "SBRBPTCH"
version     uint32    little endian
headerLen   uint32    little endian
header      JSON      release build id + targets + payload offsets/hashes
payloads    raw bytecode blobs
```

Magic first so a truncated or misidentified file fails at byte 0 rather than
somewhere inside the interpreter. Targets are named by **selector** (step 3's
manifest), never by index — an index into anything the release computed is
exactly the "incidental position" the plan warns against.

**Release identity is the GNU build ID** the toolchain already emits into the
snapshot, read at run time via `releaseBuildId()`. Patch bytecode is compiled
against one release's kernel, so applying it elsewhere is undefined rather than
merely unsupported — and would surface as a corrupt interpreted body, not an
error.

### The finding: upstream cannot roll back in AOT

`Function::ClearBytecode()` — upstream's undo — calls `ClearCode()`, which is
`UNREACHABLE()` under `DART_PRECOMPILED_RUNTIME` and, in the JIT, installs the
`LazyCompile` stub. Correct there; meaningless in a runtime with no compiler.
Worse, **`AttachBytecode` discards the original `Code` without saving it**, so
even a working `ClearBytecode` would have had nothing to restore.

So Route B supplies rollback itself: the attach path saves the original `Code`,
and `RestoreCodeFromBytecode()` puts it back. The plan lists "preserve rollback"
as part of step 4 — it turned out to be the part that did not exist.

**Where that saved `Code` lives cost two attempts, and the first one is a trap
worth naming.** Appending a field to `OBJECT_STORE_FIELD_LIST` looks tidy and
fails twice over: the AOT deserializer leaves the appended slot holding a raw C
`nullptr` — *not* the Dart null object — so `Object::IsNull()` reports false and
the first use segfaults at `0xf`; and the slot may sit past the end of the
deserialized `ObjectStore` allocation, so writing to it corrupts the heap rather
than crashing honestly. (Inserting the field anywhere *earlier* fails louder and
sooner: every following offset shifts and the build dies in `dart.cc`
`CheckOffsets`.) The saved codes now live in persistent handles, which are GC
roots and survive compaction.

### What the 10 checks actually check

| | |
|---|---|
| two targets, one container | both change together, both revert together |
| wrong release | refused on build-id mismatch, nothing attached |
| corrupt payload | refused on hash mismatch, nothing attached |
| partial apply | one target unresolvable → the already-attached one is rolled back |

The last is the case a one-target harness cannot test at all, which is why the
release program has two functions. Hash verification lives in the **installer**,
not only in the packer — a packer checking its own output proves nothing about a
file that crossed a network — and it runs before any attach, because a
transactional apply can unwind attachments but cannot unwind a corrupt body that
already ran.

**Still host-only.** The installer here is Dart because the harness is; in the
product it belongs in the engine's C++ patch installer, alongside the existing
Shorebird lifecycle rather than beside it. The order it establishes — verify,
match release, attach tracking what succeeded, unwind on failure — is the part
to copy.

## Step 5 — producing a patch, and refusing to produce a misleading one

```bash
selfhost/engine/route_b/packaging/verify_patch_flow.sh    # 8 checks
```

The whole loop the CLI will eventually drive: release → edit a Dart function →
kernel diff decides what changed → compile bytecode for exactly that → pack →
apply → revert.

**Change detection diffs the kernel, not the source.** A source diff answers
"which lines did the author touch", which is the wrong question: whitespace
changes source and not kernel, while a changed const or an inlined helper
changes kernel well beyond the edited line. `build_patch.dart` prints each
member from the kernel AST and compares — printed rather than hashed from the
binary, because the binary carries offsets and canonical-name indices that shift
when unrelated code moves, which would report the whole program as changed after
a one-line edit.

**Coverage is the output, not a footnote.** Each changed member is classified
against step 3's manifest, and the tool exits non-zero rather than emit a
container when any part of the change cannot land:

| situation | why it is refused |
|---|---|
| changed member not reachable | the patch would install cleanly and do nothing for it |
| changed member not in the manifest | unknown reachability is not the same as reachable |
| **member added** | a patch replaces bodies; it cannot introduce members, and bytecode referencing a new symbol fails to bind at load |

That last row was a bug in this tool, caught by its own test: it detected the
addition and shipped anyway. Note also how the test had to be written — the
first version added a function nobody called, AOT tree-shook it, and the tool
correctly saw no change at all. An addition only matters once something
references it, which is also exactly when it breaks binding.

### Why this is not wired into `shorebird patch`

The iOS engine port has not happened. Wiring a half-path into the shipping CLI
would let someone run `shorebird patch`, get a container, and believe it means
something. When step 6 lands, this is the pipeline to move behind the command —
the pieces are already in the shape the CLI needs: a manifest per release, a
build-id stamp, a coverage verdict, and a packer.

## Steps 6 and 7 — one suite, and the first number that is not a toy

```bash
selfhost/engine/route_b/run_all.sh            # step 6: every host check
selfhost/engine/route_b/measure_real_app.sh   # step 7: the size half
```

**Step 6.** By the end of step 5 the checks lived in five scripts across three
directories, each with its own invocation and its own way of saying "passed" —
which is how a suite quietly stops being run. `run_all.sh` is one command with
one verdict (**7/7**), guards the tree before trusting any result, and runs the
kill gate **twice**: with the patchable call form and without. That pairing is
not ceremony — a passing arm alone is equally consistent with the flag being
ignored.

**Step 7, size half — measured on the real Flutter fixture**, 469 libraries and
a 25 MB kernel, compiled against the Flutter platform dill with TFA on:

| configuration | bytes | vs baseline |
|---|---|---|
| baseline (stock AOT) | 5,736,952 | — |
| + call form | 5,933,888 | **+3.43 %** |
| **+ call form + app-only retention** | **5,988,552** | **+4.39 %** |
| + call form + ALL 469 libraries retained | 21,547,112 | **+275.58 %** |

The shipping policy costs **+4.39 %** on a real app — within a percentage point
of the toy's +4.64 %, which is the first evidence the toy numbers were not
lying. The naive policy costs **3.75×**, and the gap between those two rows is
the entire value of step 2's asymmetric retention decision.

That real app also caught a bug the toys could not: private **accessors** were
being emitted as bare names, and the VM matches the dynamic interface against
its disambiguated `get:`/`set:` forms, so `gen_kernel` rejected the app outright
with *"a member with disambiguated name `_platform` was not found"*. No toy here
had a private getter.

### What step 7 still does not answer

**Frame time is not measured, and cannot be from a snapshot** — it needs the app
running on a device, which needs the iOS engine port. Half of the veto is open.

And these are **macOS host snapshots**. Absolute bytes are not an iOS release
size; the deltas are the transferable part, since both arms compile the same
kernel with the same compiler and differ only in flags.

## Step 8, in progress — the iOS port, and two different interpreters

```bash
screen -dmS routebios bash -c 'caffeinate -is selfhost/engine/route_b/build_ios.sh'
```

**The first failure was not the one the plan predicted.** Trap #1 says an iOS
build carrying the killgate SDK edits dies at the AOT step with `Unexpected tag
4 (Field)`. It never got that far — it failed in **97 seconds**, compiling C++:

```
FAILED: obj/flutter/runtime/shorebird/patch_cache.patch_cache.o
patch_cache.cc:39: use of undeclared identifier 'Shorebird_ReadLinkHeader'
```

`patch_cache.cc` is the single file in the tree that calls into Shorebird's
**private Dart fork**. The shipping iOS tree never compiles it, and the reason
is a selfhost change already in the tree: patch `0002` moved that dependency
from `is_ios` onto `shorebird_use_interpreter`, precisely so an iOS engine could
build against vanilla Dart.

**So the tree carries two unrelated things both called "the interpreter", and
conflating them costs a build:**

| flag | selects | Route B wants |
|---|---|---|
| `shorebird_use_interpreter` (defaults to `is_ios`) | **Shorebird's** interpreter path, backed by their private fork | **false** |
| `dart_dynamic_modules` | **vanilla Dart's** interpreter, `InterpretCall`, `AttachBytecode` | **true** |

The correct combination reads like a contradiction and is not:
`shorebird_use_interpreter = false` *with* `dart_dynamic_modules = true` — no
interpreter in their sense, the interpreter in ours. `tools/gn` has no
pass-through for arbitrary args, so `build_ios.sh` appends the flag to
`args.gn` and regenerates. Excluding `patch_cache` also drops the target count
from 8,162 to 6,825.

## Cold review, 2026-08-10 — three questions, and one risk that shrank

Written up during the media copy, when the SSD was busy and nothing could be
built. All of it is reading, not running.

### 1. Is the saved-original-Code table safe against a double attach?

**Yes.** `AttachBytecode` asserts the bytecode slot is empty, but `ASSERT` is
compiled out in product builds, so a second attach would silently overwrite —
and the rollback table would then record the **InterpretCall stub** as the
"original", making a later detach restore the stub instead of the app's code.

That cannot happen: the pre-existing *already interpreted* guard
(`object.cc:809`) returns false before the save at `:826`. The ordering is what
makes it safe, so do not reorder those.

### 2. Does the unchecked entry point work, or is it just emitted?

I expected this to be the weak spot: form (c) loads
`Function::entry_point_offset(entry_kind)`, and for `kUnchecked` that is
`unchecked_entry_point_`, which `SetInstructionsSafe` fills from the
InterpretCall stub's *unchecked* entry. If a stub's unchecked entry differed
from its normal one, those call sites would jump somewhere wrong.

**Already exercised, and working.** In the inventory snapshot:

| entry | field | call sites |
|---|---|---|
| normal | `[r0, #7]` | 1,107 |
| **unchecked** | `[r0, #15]` | **842** |

So ~43 % of call sites already take the unchecked path, and both the kill gate
and the inventory pass. This was a real question with an evidence-backed answer,
not an untested path.

### 3. Dispatch-table calls — what would it actually cost?

Still the coverage ceiling, and the scoping is unchanged by review: the table
holds **raw entry-point addresses**, and the call site sets up neither `R0` nor
`R4`. Rewriting the table at patch time is legal on iOS (it is data) but
insufficient, because the stub it would point at needs those registers. Making
`EmitDispatchTableCall` dispatch through the `Function` is correct and taxes
**every instance call in the program**.

The size half of the step 7 veto is now measured — the current call form costs
**+3.43 %** on a real app — but instance calls vastly outnumber static ones, so
extrapolating that figure to dispatch-table calls would be guessing. This still
needs the frame-time measurement first.

### 4. The `Unexpected tag 4 (Field)` risk has already been partly tested

Trap #1 predicts that an iOS build carrying the killgate SDK edits dies at the
AOT step, because those edits compile into `platform_strong.dill` regardless of
the GN flag. The Route B tree does carry them (6 occurrences across the two SDK
files).

**And step 7 already put that to the test, for an unrelated reason.** Measuring
real-app size required building this tree's own
`flutter_patched_sdk/platform_strong.dill` and compiling the airgap fixture —
**469 libraries** — against it with `--aot --tfa`, then snapshotting it. That
worked. A poisoned platform dill should have failed exactly there.

So the risk is **reduced, not eliminated**: the *host* AOT path is clean, and
the iOS engine build's AOT step is a different invocation with a different
platform dill target. But the most likely form of this failure has now had a
chance to fire on a real Flutter app and did not.

## Step 4a — PASSED ON HARDWARE, 2026-08-10

```
route B baseline:  OLD
route B attached:  NEW
route B detached:  OLD
route B note:      attach=true detach=true bytes=409
```

iPhone 7, iOS 15.8.8, arm64. All three states from the **same installed
process** — no restart, no reinstall, no re-release between them. Evidence:
[`fixtures/evidence/routeb_4a_device_gate.png`](../../fixtures/evidence/routeb_4a_device_gate.png).

**The claim, exactly:**

> Route B's arm64 iOS runtime mechanism is proven on physical hardware: a
> shipped AOT call site can be redirected to attached bytecode and restored to
> its original AOT `Code`.

**And separately, without softening:**

> Production delivery is not built. `shorebird patch` cannot produce an iOS code
> patch (`ios_patcher.dart:198` gates on `aot-tools.dill`), and nothing in the
> engine or updater consumes an `SBRBPTCH` container. The payload here was
> bundled as an asset and attached in-process by test-only scaffolding.

What each line establishes: **baseline** that the function ran its AOT body from
a normally-emitted call site; **attached** that the *existing compiled call
site* reached the interpreted replacement — the whole thesis; **detached** that
the original `Code` came back, which vanilla Dart cannot do at all, since
`ClearBytecode` calls `ClearCode` (`UNREACHABLE()` under
`DART_PRECOMPILED_RUNTIME`) and `AttachBytecode` discards the original without
saving it.

Attribution: App `a230b37fd3a9f5b4e96405b04b1f1d94`, engine `b4817db848…`
(2 `interpretcall` symbols), 409-byte payload, `code patch: none`.

**Keep this gate.** It is the shortest possible proof that the engine mechanism
still works, independent of CLI and updater complexity. When 4b lands, this
stays as the thing you run first when delivery breaks, to tell "the mechanism
regressed" from "the plumbing regressed".

### Everything that fought us was infrastructure, not mechanism

A mixed-provenance overlay, a GN path quirk in `zip.py`, the `dart:_internal`
package-name rule, and a `dart2bytecode` target mismatch. The mechanism itself
worked the first time it was handed a coherent build.

Three that will recur:

- **`dart:_internal` needs a package literally named `dynamic_modules`.** The
  CFE checks `importer.path.startsWith("dynamic_modules/")`, and `importer.path`
  for `package:airgap_probe/main.dart` is `airgap_probe/…` — so a subdirectory
  does not satisfy it. Hence `fixtures/airgap_app/dynamic_modules/`.
- **`dart2bytecode` needs `--target flutter`** to match the import-dill, or it
  crashes with "Null check operator used on a null value", which says nothing
  about targets.
- **The payload is release-specific.** It is compiled against the app's own
  pre-AOT kernel, so it goes stale the moment `main.dart` changes, and a stale
  payload presents as `attach returned false` — a mechanism failure, apparently.
  `assets/routeb_patch.bytecode.provenance` records what it was built against.

## The seam 4a exposed

Steps 1–5 prove host-side production, container and reference-install
semantics. They do **not** constitute an iOS delivery path: nothing in the
engine or the updater consumes an `SBRBPTCH` container, and
`ios_patcher.dart:198` gates non-`--assets-only` patches on `aot-tools.dill`,
Shorebird's linker, which we cannot build. That seam is 4b.

4a therefore proves only the mechanism, on hardware, with the payload bundled
as an asset and attached in-process — test-only scaffolding with no networking,
no control plane and no persistence.

### The publish seam it exposed

`publish_ios_overlay.sh` defaults `HOST_REL` to the **shipping** tree
(`/Volumes/build/ios-engine/.../host_release_arm64_nodm`). That default is
correct for the shipping engine and silently wrong for Route B: the host
toolchain zips — `flutter_patched_sdk_product` and `dart-sdk-darwin-arm64` —
then come from a tree WITHOUT the killgate SDK edits, while `sky_engine.zip`
comes from the Route B tree and has them.

The result is an overlay that contradicts itself:

| artifact | source tree | `attachBytecodeToFunction` |
|---|---|---|
| `sky_engine.zip` | Route B | **present** |
| `flutter_patched_sdk_product` | shipping | **absent** |
| `dart-sdk-darwin-arm64` | shipping | absent |

An app compiles against the platform dill, so it cannot see a symbol its own
SDK sources declare, and the failure is a CFE error naming the method rather
than anything pointing at the overlay. The 2.0.0+1 release did not notice
because it never referenced those symbols.

**When publishing a Route B engine, set `HOST_REL` to the Route B tree's
`out/host_release_arm64`.** The `_nodm` default exists because the shipping
iOS toolchain must NOT carry dynamic modules; Route B wants the opposite, and
the whole-toolchain-one-tree-one-GN-config invariant applies to the published
zips exactly as it does to a local build.

## Step 7 frame-time veto — PASSED 2026-08-10

Five alternating paired runs on the iPhone 7. Same engine, same app source,
same device, same 600-frame sample after 180 warmup frames, no patch applied.
**Only `--patchable_static_calls` differs.** Order alternated C→R, R→C, … so a
thermal trend over 20 minutes could not be credited to whichever arm ran second.

Paired deltas (Route B − control, within each pair), four clean pairs:

| layer | metric | median | range |
|---|---|---|---|
| **signal** | build p50 | **+3.2 %** | +2.7 … +4.6 % |
| | build p95 | **+9.6 %** | +1.3 … +12.4 % |
| **noise** | raster p50 | −1.6 % | −2.6 … +0.2 % |
| | raster p95 | +0.8 % | −0.3 … +4.5 % |
| **product** | total p50 | **+0.3 %** | −0.4 … +0.9 % |
| | total p95 | **+1.1 %** | −0.1 … +2.6 % |
| | jank | **0 / 3000 in both arms** | |

Size on the same source, one flag: 4,005,536 → 4,186,368 bytes (**+4.5 %**),
consistent with the +3.43 % measured on the host.

**Verdict: PASS.** There is a real Dart-phase CPU tax and it should be recorded
rather than described as free — but the user-visible frame cost is negligible
and an iPhone 7 keeps ~40 % of its 60 Hz budget spare in both arms.

Read `build p95 = +9.6 %` cautiously: it is positive in all four clean pairs but
ranges +1.3 to +12.4 %, so the tail is much noisier than the median. The
defensible statement is "build p50 ≈ +3 %, p95 positive but roughly +1–12 %".

### Why the raster channel is in the table

Raster runs no Dart, so the flag cannot affect it. It is there as the noise
floor, and it earned its place: **pair 2's Route B run came out 35–40 % faster
on every metric including raster**, which is impossible as a Route B effect and
means that run simply did less work — occlusion or throttling. Without a channel
the flag cannot influence, that run would have looked like a spectacular win and
dragged the median the wrong way.

Excluding it moves build p50 from +2.7 % to +3.2 % and total p95 from +0.9 % to
+1.1 %. **The verdict is identical either way**, which is the useful fact. The
raw ten runs are kept in
[`fixtures/evidence/routeb_frametime_5pairs.txt`](../../fixtures/evidence/routeb_frametime_5pairs.txt).

### The workload had to be built

The fixture's own screen is a static column of `Text`: it paints once and then
produces no frames, so it could not measure frame time at all. `frame_bench.dart`
drives continuous rebuilds of a 96-cell tree with real arithmetic per cell, so
the framework's own static calls — the code the flag taxes — run thousands of
times a second. Build is ~40 % of the frame here; a heavier Dart workload would
raise the tax's visible share and a lighter one would bury it.

### Consequence for dispatch-table calls: DEFERRED, on evidence

We are already paying ~3 % build-phase tax on the static calls Route B
intercepts. Taxing **every instance call** to move coverage from 5/6 to 6/6 is
not justified by the coverage matrix alone. It needs evidence that missing
dispatch-table calls actually blocks useful patches. This is deferred *on
grounds*, not merely unfinished.

## Seam 6 — native pre-main activation, PASSED 2026-08-10

4a proved the mechanism with the app attaching its own patch from Dart. Seam 6
removes the app from the loop entirely: `0002-seam6-premain-activation.patch`
adds `InstallRouteBActivationHook(Settings&)` to `shell/common/shorebird/
shorebird.cc`, called from the tail of `ConfigureShorebird`.

**Where activation happens, and why there.** The hook arms
`settings.root_isolate_create_callback`, which fires at `dart_isolate.cc:163`
inside a `tonic::DartState::Scope` — after the isolate exists and its libraries
are loaded, and before `RunFromLibrary`/`InvokeMainEntrypoint` at `:174`. Route
B needs live `Function` objects, so it cannot run any earlier; it must run
before user Dart, so it cannot run any later. That is a one-line window and the
callback sits in it.

**Ownership is split on purpose.** `ConfigureShorebird` decides *which* patch is
active — that is the updater's lifecycle and it is unchanged. The hook decides
only *how* a Route B patch becomes live. Keeping them separate is why this is a
new function rather than more code inside `ConfigureShorebird`.

**Fail closed, and chain.** No payload → return before touching anything, so
ordinary apps pay nothing. Any existing `root_isolate_create_callback` is
**chained, never replaced**: fuchsia and the embedder API both set it, and
silently eating another subsystem's hook would be a miserable regression to
find.

### The trigger is file presence, and that is test scaffolding

The first attempt read `SHOREBIRD_ROUTEB_*` environment variables and the hook
never fired — `ios-deploy --envs` does not reach the launched process, so
`getenv` returned null and the chain was skipped in silence. That is a test
**transport** failure, not a Route B failure, and swapping the trigger changes
only how the engine *receives* configuration. Env is still honoured where it
works.

In 4b this whole block is replaced by the lifecycle-selected `SBRBPTCH` path,
and library/target come from the container's own target records instead of being
hard-coded. **Do not build the producer first.** Make a real updater-selected
artifact reach this exact function, then wire `shorebird patch` to it.

### The evidence, and its limit

Two builds one asset apart: patched → `NEW`, control → `OLD`, read once in
`initState` from a build whose `grep` for `attachBytecode|detachBytecode|
dynamic_modules` returns zero. Screenshots and the full construction are in
[`evidence/`](evidence/README.md).

Attribution is **behavioral, not log-backed**. The hook emits a `ROUTEB:` chain
via `FML_LOG` and none of it survives — no engine log line of any kind reaches
`idevicesyslog` for a `--noninteractive` launch on this device, Flutter's own
included, because stderr is not routed there. Absence of `ROUTEB` lines is
therefore evidence of nothing. The control is what carries the argument.

## 4b milestone 1 — real updater bytes, and the three things it needed first

The scope was meant to be one substitution: test asset path becomes the
lifecycle-selected `SBRBPTCH` path. Tracing the runtime chain first turned up
three hard dependencies, none of which are visible from the seam-6 side and all
of which are delivery plumbing rather than producer work.

### 1. A Route B iOS engine had no base reader at all

`install_downloaded_patch` unconditionally inflates against the base snapshot,
and on iOS `patch_base()` is `file_provider.open()` and nothing else. That
returned a null handle — `FileCallbacksImpl::Open()` was gated on
`SHOREBIRD_USE_INTERPRETER`, and so was `SetBaseSnapshot`, so there was nothing
to hand back. **Every install failed inside `inflate()` before reading a byte.**

The flag was standing in for "is iOS", because upstream has no iOS build where
it is false. Route B is exactly that build. Two capabilities were coupled that
are not the same question:

```
iOS patch installation needs base snapshot bytes   (inflate reads them)
iOS must use Shorebird's private interpreter       (a different question)
```

`SHOREBIRD_NEEDS_BASE_SNAPSHOT` now keys on the platform; the private-fork
`Shorebird_SetBaseSnapshots` call stays behind the interpreter flag alone.

### 2. Content sniffing is a boot-safety invariant, not cleanup

The lifecycle installs **every** code artifact as `patches/{N}/dlc.vmcode`
whatever is inside it, so the filename carries no information and
`PatchCarriesCode()` — which keys on `.vmcode` — says "code" for a Route B
container too. With the interpreter off, iOS takes the `clear()` branch, which
would make the container the app's only library path and hand a JSON-headed file
to the VM snapshot loader. That is not a degraded patch, it is a failure to
boot. The sniff therefore happens **before** `application_library_paths` is
touched.

### 3. The artifact goes through the normal inflate, and is base-independent

No special-casing of transport: same bidiff+zstd, same download/resume/install/
hash path. But a Route B container has nothing in common with the base snapshot,
and diffing against the real base would force the producer to reproduce the
device's exact byte stream — which needs `analyze_snapshot --dump_blobs`, a
Shorebird-fork tool we cannot build.

So `route_b_artifact` diffs against a one-byte synthetic base (an actually-empty
base panics inside bidiff's suffix-array code) and the artifact comes out as
pure literal inserts. That only helps if it is genuinely base-independent, so the
tool **verifies rather than assumes**: every run reconstructs against an empty
base and a 4 MB noise base and requires byte-identical output. Measured, a
4,338-byte container becomes a 229-byte artifact, identical for every synthetic
base length tried.

### The rejection taxonomy

Container parsing lives in `shell/common/shorebird/route_b_patch.cc`, never in
`object.cc`: the VM receives validated `(library, selector, bytes)` triples and
knows nothing about JSON, containers or releases. `Dart_RouteBActivatePatch`
returns a `Dart_RouteBResult` rather than a bool so the VM-side outcomes are
separable too.

| outcome | where | means |
|---|---|---|
| `not-a-container` | reader | an ordinary code patch. Common, cheap, silent |
| `unsupported-version` | reader | magic matched, version did not |
| `malformed` | reader | truncated, unparseable, missing fields, bad offsets |
| `payload-corrupt` | reader | payload does not match its declared sha256 |
| `wrong-release` | hook | **checked before any target is resolved** |
| `target-missing` | VM | retention or library-URI problem |
| `invalid-bytecode` | VM | producer or corruption problem |
| `already-interpreted` | VM | conflicting state |
| `attach-failed` | VM | the attach itself |

**Wrong-release must never degrade into `attach=false`.** That collapse cost this
project days: a stale payload sent us looking at retention, bytecode metadata and
the installer in turn, none of which were wrong.

`Dart_RouteBReleaseBuildId()` exists because the check has to run in the hook,
before targets, where no Dart has run and none can be. A null identity is
refused, never treated as a wildcard.

### Why the taxonomy is tested by a shell script

The assertions are written as gtest cases in `route_b_patch_unittests.cc`, which
is where they belong. **That target cannot link on a vanilla-Dart tree**: it
pulls in `runtime/shorebird/patch_cache.cc`, which calls
`Shorebird_ReadLinkHeader`, a symbol only Shorebird's private fork defines. So
`packaging/verify_container_reader.sh` compiles the REAL parser against a stub
and runs the same cases — no second copy of the logic exists. `kWrongRelease` is
absent there because it needs a live isolate; it is proven on device.

The SHA-256 in the reader is hand-written, because no shell target depends on
boringssl and this is an integrity check rather than a security boundary. A NIST
vector guards it. If that case ever fails, every integrity check in the file is
meaningless.

## The producer invariant: releases must be patchable, and it is DETECTED

`applied N/N targets` in the `.routeb` report plus `OLD` on screen means the
release was built without `--patchable_static_calls` — not that the hook is
broken. The attach genuinely succeeds and the call site simply never consults
`Function.entry_point_`.

Nothing else in the stack reports the flag's absence, so this is a detector
rather than a convention. `verify_patchable_release.sh` counts the two fixed
instruction words the patchable form always ends in:

```
ldur lr, [r0, #7]    0xF840701E     ; Function.entry_point_
blr  lr              0xD63F03C0
```

It is a property of the **shipped bytes**, so a stale build, a cached artifact
or provenance that says the right thing cannot defeat it. Measured on the two
releases that produced the failure and the fix:

| release | built with the flag | pairs | per MB | verdict |
|---|---|---|---|---|
| 8.0.0+1 | no | 8 | 2 | **NOT PATCHABLE** |
| 9.0.0+1 | yes | 7,109 | 1,788 | **PATCHABLE** |

A non-patchable release still contains a few — AOT already dispatches some
closure and tear-off calls through `entry_point_` regardless — which is why the
test is a density threshold and not `> 0`. Three orders of magnitude apart, so
the threshold is not a fine judgement call.

`build_4b_artifact.sh` runs it and refuses before compiling anything.

## The patch series, and which tree each patch belongs to

Three trees, and mixing them up produces a build that looks fine and behaves
wrongly:

| patch | tree | what it does |
|---|---|---|
| `0001-patchable-static-calls.patch` | **Dart** (`third_party/dart`) | form (c) call emission, `Dart_RouteBActivatePatch`, `Dart_RouteBReleaseBuildId`, `RestoreCodeFromBytecode` |
| `0002-seam6-premain-activation.patch` | **flutter** | the pre-main activation hook |
| `0003-4b-lifecycle-delivery.patch` | **flutter** + **updater** | base decoupling, content sniffing, container reader, artifact producer |
| `../0007-flutter-assets-only-patch-support.patch` | **flutter** | assets-only patch plumbing; `0002` applies on top of it |

Note `third_party/updater` is its OWN git repo inside the engine checkout, so
its files cannot be reconstructed from the engine tree's HEAD. `0003` spans both
and was generated accordingly; getting that wrong silently produces a patch that
adds `Cargo.toml` as a new file.

`0001` applies on top of `../killgate/0001-attach-bytecode-native.patch`, not on
bare upstream. All of them were regenerated by reconstructing each file from its
pinned base and diffing, then re-applied to a scratch tree and compared
byte-for-byte against the live checkout — a patch that does not reproduce the
tree it claims to describe is worse than no patch at all.

## Smoke-test the tree before trusting it

"It built" proves nothing about a fork/backend pairing — a mismatched
frontend/backend compiles cleanly and only fails later. Run the kill gate
against the new tree and compare with the recorded 2026-08-04 result:

```bash
SRC=/Volumes/build/route-b/flutter/engine/src \
OUT=/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64 \
  selfhost/engine/killgate/run.sh
```

Without the flag you should get `GATE: BASELINE` — all four shapes `OLD`, with
`C++ invoke ... returned: NEW`. That is the healthy pre-step-1 result: the
interpreter runs the attached bytecode, nothing dispatches to it yet.

With `GEN_SNAPSHOT_FLAGS=--patchable_static_calls`, expect `GATE: PASS` and all
four shapes `NEW`. Run both — the pair is the evidence, since either alone is
consistent with the flag doing nothing.

`GATE: INCONCLUSIVE` (attach returned false) is the one verdict that means the
build is actually wrong.

### The gate's own trap, worth knowing before you trust a FAIL

`greet()` deliberately routes its value through `DateTime.now()`. It used to be
`=> 'OLD'`, and that made the gate measure the wrong thing: `vm:never-inline`
stops the body being spliced into `main`, but it does not stop the type-flow
analysis proving the result is always `'OLD'` and substituting the constant at
the call site. The call was still emitted and still executed — its result was
simply unused, visible in the disassembly as a `blr` whose `r0` nobody reads.

The symptom is a working mechanism reporting `direct : OLD`. If you ever change
the target program, keep the value opaque.

## What build_host.sh builds

It builds the host macOS arm64 release toolchain — `gen_snapshot`,
`dartaotruntime`, `dart`, `dart_sdk`, `vm_platform.dill` — and not the default
target graph, which pulls in ANGLE and fails on Xcode 26 without a separately
downloaded Metal Toolchain. Host before iOS is deliberate: a macOS release
build is also a precompiled runtime, so it exercises the same
`DART_PRECOMPILED_RUNTIME` + `DART_DYNAMIC_MODULES` pairing with no signing, no
device, and a roughly one-minute incremental loop.
