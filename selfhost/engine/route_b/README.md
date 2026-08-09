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

## Smoke-test the tree before trusting it

"It built" proves nothing about a fork/backend pairing — a mismatched
frontend/backend compiles cleanly and only fails later. Run the kill gate
against the new tree and compare with the recorded 2026-08-04 result:

```bash
SRC=/Volumes/build/route-b/flutter/engine/src \
OUT=/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64 \
  selfhost/engine/killgate/run.sh
```

Expected today, and reproduced on this tree 2026-08-09:

```
ATTACH: before -> IsInterpreted=0 HasBytecode=0
ATTACH: after  -> IsInterpreted=1 HasBytecode=1
ATTACH: C++ invoke of target returned: NEW     <-- the interpreter ran it
after  direct/tear-off/dynamic/apply : OLD     <-- no call site dispatches yet
GATE: BASELINE
```

**`BASELINE` is the healthy result.** The four `OLD` lines are the call-site
dispatch gap that Route B step 1 exists to close, not a broken build. The
authority on whether the interpreter executed is the `C++ invoke` line, which
goes through `DartEntry::InvokeFunction`; the Dart-side shapes are all
statically bound in AOT and cannot tell you. `GATE: INCONCLUSIVE` — attach
returned false — is the one that means something is actually wrong with the
build.

## What build_host.sh builds

It builds the host macOS arm64 release toolchain — `gen_snapshot`,
`dartaotruntime`, `dart`, `dart_sdk`, `vm_platform.dill` — and not the default
target graph, which pulls in ANGLE and fails on Xcode 26 without a separately
downloaded Metal Toolchain. Host before iOS is deliberate: a macOS release
build is also a precompiled runtime, so it exercises the same
`DART_PRECOMPILED_RUNTIME` + `DART_DYNAMIC_MODULES` pairing with no signing, no
device, and a roughly one-minute incremental loop.
