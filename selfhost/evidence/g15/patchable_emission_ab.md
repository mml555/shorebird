# `--patchable_static_calls` — COMPILER REGRESSION REFUTED, narrowed to the build invocation

Outcome: **neither** of the two anticipated results. Not "BUILT FIX" and not
"COMPILER REGRESSION ISOLATED" — the regression hypothesis is **REFUTED**, and the
differentiator is release 103's Flutter build invocation. Lifecycle lane untouched.

## THE EMITTER IS COMPILE-TIME GUARDED, WHICH LOOKED LIKE THE ANSWER

`runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc:406`

    #if defined(DART_DYNAMIC_MODULES)
      if (FLAG_precompiled_mode && FLAG_patchable_static_calls) {

and the flag's own help text says *"Requires a build with
dart_dynamic_modules=true."* Crucially the `DEFINE_FLAG` lives OUTSIDE that guard,
so **a binary can accept the flag while the emitter was never compiled** — exactly
"accepted and inert".

**Measured, and it does not hold here.** Both cells' `gen_snapshot_arm64` carry the
flag help string (2 hits) and 38 dynamic-modules symbols — identical counts. Both
were built with `DART_DYNAMIC_MODULES`.

## THE A/B, OUTSIDE SHOREBIRD ENTIRELY

Ten non-inlinable static calls, each lineage using **its own matched SDK** — no
mixing. `gen_kernel_aot` from that SDK, its own `vm_platform_product.dill`, then
that lineage's snapshotter with `--patchable_static_calls`.

| snapshotter | output path | patchable sites |
|---|---|---|
| old cell `gen_snapshot_arm64` | app-aot-elf | **936** (1,146/MB) |
| new cell `gen_snapshot_arm64` | app-aot-elf | **935** (1,145/MB) |
| new `dart-sdk/bin/utils/gen_snapshot` | app-aot-elf | **935** |
| old `dart-sdk/bin/utils/gen_snapshot` | app-aot-elf | **rejects the flag entirely** — `Unrecognized flags: patchable_static_calls` |
| old cell, assembled | app-aot-assembly → `clang -c` | **936** |
| new cell, assembled | app-aot-assembly → `clang -c` | **935** |

**Every snapshotter in the new lineage emits, on both output paths.** The iOS
build uses the assembly path, and that is preserved too. So the emitter, the
compile-time guard, the flag plumbing and the output format are all exonerated.

Incidental but useful: the OLD `dart-sdk`'s `gen_snapshot` does not know the flag
at all, so release 102 must have used the CELL's snapshotter — confirming the cell
artifact is the one that matters for the app AOT.

## WHAT THIS LEAVES — one narrow question

> Release 103's build produced **8** sites while the same snapshotter produces
> **935** on a minimal fixture. The flag therefore did not reach the AOT step that
> compiled the app, or that step used something not tested above.

## TWO CHECKS I RAN THAT PROVED NOTHING — recorded so they are not repeated

1. **The build trace.** `build-trace-ios.json` is current (02:05, beside the 02:04
   IPA) and contains `gen_snapshot`, but it records **no command arguments at all**
   (`--` occurrences: 0). It is a Perfetto timing trace. So "0 mentions of
   patchable_static_calls" is **vacuous** and is not evidence.
2. **Text-grepping the `.S` output** for `ldur`. gen_snapshot's assembly emits
   instructions as `.quad` data directives, not mnemonics — `ldur` appears **0**
   times in both files. The 0/0 comparison was inconclusive by construction, which
   is why the files were assembled with `clang -c` and scanned as bytes instead.

## THE NEXT MEASUREMENT, stated precisely

Instrument the real build: interpose a logging wrapper on `gen_snapshot_arm64`
inside the active cell's `artifacts/engine/ios-release/`, run one release, and
capture **argv and the executable's digest** for the app's AOT step. That answers
which binary ran and whether `--patchable_static_calls` was present, mechanically
rather than by inference. It requires re-pointing the checkout at the cell, so it
is a rig mutation and belongs to a session that can also restore.

Do NOT re-derive: the emitter works. The question is solely what the build invoked.

## RIG STATE

Untouched by this lane — all work was offline against fetched artifacts in
`/Volumes/build/route-b/{gsprobe,ab_patchable,runner_probe}`. Rig remains on cell
`50bdae36`, `compatibility.yaml` unstamped, fixture at `1.2.0+1`, no release 104.
Lifecycle verdicts unchanged.
