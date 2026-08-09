<!-- cspell:words killgate dynmod dartaotruntime APFS gclient depot caffeinate -->

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

Two deliberate scope choices in the patch, both explained in its comments:

- it lives in `EmitOptimizedStaticCall`, not `GenerateStaticDartCall`, because
  `EmitTestAndCall` also reaches the latter for polymorphic instance dispatch
  and supplies no arguments descriptor;
- it does **not** call `AddStaticCallTarget`, because that records a
  `Code::kCallViaCode` site and `BindStaticCalls` would then run
  `CodePatcher::PatchStaticCallAt` over a sequence that is not the pool-load
  shape that patcher expects.

**What this is not.** It is one call form working in a host harness. Steps 2–5
(symbol retention, stable target identity, the versioned container, and
`shorebird patch` producing one) are untouched, and the iOS port and both vetoes
are still ahead.

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
