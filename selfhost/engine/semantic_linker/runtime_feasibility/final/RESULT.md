<!-- cspell:words dartaotruntime dill semantic linker devirtualization KBC -->
# SEMANTIC-LINKER-1 — final runtime-feasibility verdict

**Issue:** [#46](https://github.com/mml555/shorebird/issues/46) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Published:** 2026-09-06

# VERDICT: PROCEED

Every required primitive is mechanically supported on the frozen lineage, and
optimizer behaviour is **fully characterised without changing the runtime
model**: it is sound when `can-be-overridden` is part of the release-time
patchability contract. The one blocking gap — module-side dynamic-interface
validation — is a production pipeline requirement, not a runtime or compiler
defect, so it does not select `MODIFY_VM` or `MODIFY_COMPILER_FENCES`.

**Next lane: `SEMANTIC-MAP-1`.** Nothing of it is begun here.

## Result matrix

Every row below is **extracted** from a marker in a gate transcript or a field
in a structured record by [`assemble_verdict.sh`](assemble_verdict.sh); a row
whose evidence cannot be found is emitted `NOT_ESTABLISHED` rather than filled
in from memory. Machine-readable: [`verdict.json`](verdict.json).

    FROZEN_LINEAGE:                   VERIFIED
    CURRENT_DART:                     NOT_TRIGGERED

    BYTECODE_TO_AOT:                  PROVEN
    AOT_TO_BYTECODE:                  PROVEN

    SHARED_HEAP:                      PROVEN
    OBJECT_IDENTITY:                  PROVEN

    AOT_ROOT_TO_PATCH_OBJECT:         PROVEN
    PATCH_ROOT_TO_AOT_OBJECT:         PROVEN
    CROSS_RUNTIME_CYCLE_COLLECTION:   PROVEN

    BYTECODE_EXCEPTION_TO_AOT:        PROVEN
    AOT_EXCEPTION_TO_BYTECODE:        PROVEN
    FINALLY:                          PROVEN
    STACK_UNWINDING:                  PROVEN

    PATCH_CLASS:                      PROVEN
    IMPLEMENTS_AOT_INTERFACE:         PROVEN
    EXTENDS_AOT_CLASS:                PROVEN
    SUPER_TO_AOT:                     PROVEN
    IS_CHECK:                         PROVEN
    CAST:                             PROVEN
    GENERICS:                         PROVEN

    OPTIMIZER_DIRECT_VIRTUAL:         SOUND_WITH_CONTRACT__BYPASSED_WITHOUT
    OPTIMIZER_MONOMORPHIC:            SOUND_WITH_CONTRACT__BYPASSED_WITHOUT
    OPTIMIZER_HELPER_CHAIN:           SOUND_WITH_CONTRACT__BYPASSED_WITHOUT
    OPTIMIZER_GENERIC:                SOUND_WITH_CONTRACT__BYPASSED_WITHOUT
    OPTIMIZER_FIELD_RECEIVER:         SOUND_WITH_CONTRACT__BYPASSED_WITHOUT

    SUBSTRATE_COST:          dartaotruntime +2.76%; vm_platform.dill 0.00%;
                             normal AOT performance: no measurable difference
    DYNAMIC_INTERFACE_COST:  +16,704 bytes (+1.88%) retained AOT per
                             declared-patchable member
    MODULE_COST:             module 1,190 B; load ~99 us; RSS delta ~112 KB
    CALL_COST:               direct 2.27 ns · virtual 2.52 ns ·
                             AOT->bc 20.78 · bc->AOT 27.94 · bc->bc 28.39 ns
                             alloc: AOT 5.69 · bc/AOT-type 77.15 ·
                             bc/patch-type 95.52 ns

    KNOWN_GAPS:
      MODULE_SIDE_DYNAMIC_INTERFACE_VALIDATION  UNRESOLVED
      NEGATIVE_CONTROLS_FAIL_OPEN               FINDING
      SUPPORTED_CELL_REPRODUCIBILITY            NOT_ESTABLISHED_BY_THIS_LANE
      GC_COST_CHARACTERISATION                  PARTIAL
      PLATFORM_SCOPE                            LIMIT
      CALL_SITE_REBINDING                       OUT_OF_SCOPE

    VERDICT:                          PROCEED

The `OPTIMIZER_*` rows are deliberately two-sided. Reporting only the sound half
would misstate the finding: each shape is sound **with** the contract and
bypassed **without** it, and both halves are required for the row to read as
characterised.

## The optimizer row, stated as a design constraint

With a single implementation in the closed world, the precompiler devirtualizes
every call site — and at a field receiver with inlining permitted, inlines the
body outright, leaving no call at all. `extendable` on the class and `callable`
on the member are **not** sufficient.

> **Patchability-contract invariant.** Every member intended to remain patchable
> must be emitted as `can-be-overridden` by the release-time contract generator.

This is carried into `SEMANTIC-MAP-1` and `AOT-ASSUMPTIONS-1` as a constraint,
not as a compiler change: the fence already exists and the compiler already
honours it.

## Non-proven claims and exact limitations

Stated so nothing here is read more broadly than it was measured.

1. **Module-side dynamic-interface validation is not enforced.**
   `KernelTarget.validateDynamicModule` runs only when the CFE is given
   `dynamicInterfaceSpecificationUri` while compiling the *module*, and neither
   `dart2bytecode` nor `gen_kernel` does that. All four
   `DYNAMIC_INTERFACE_POLICY` negatives load silently, and
   `member_not_overridable` additionally produces silently wrong behaviour.
   **Blocking for production; a pipeline requirement, not a runtime defect.**
2. **Five negative controls fail open** — `wrong_platform_dill`,
   `wrong_runtime_build`, `no_extendable`, `no_type`, `member_not_overridable`.
   The first two are not reproducible on this lineage because every build shares
   `SNAPSHOT_HASH`; that is correct behaviour, not a missing check.
3. **Corrupt bytecode is indistinguishable from an import failure** at this
   layer. Explain tooling must not classify from the VM error string alone.
4. **The supported cell is not reproduced.** The *lane's* builds are
   byte-reproducible from the G0 bank (10/10, including linked executables), but
   the historical cell is `NOT_ESTABLISHED_BY_THIS_GATE`; only `vm_platform.dill`
   matched. `NEXT_LANES.md`'s conclusion is narrowed by new evidence, not
   retracted.
5. **Call-site rebinding is out of scope and unproven.** Dart-side call sites
   remain statically bound in AOT. `AOT_TO_BYTECODE` is proven through the
   *additive* dynamic-module path — a new type at a dispatch point the contract
   declared open — not by replacing an existing function's callers. The binder
   is not built and no gate claims it.
6. **GC cost is partially characterised.** Collection cost is flat across the
   three allocation modes on one workload on one machine. That is not a GC
   characterisation.
7. **Platform scope.** Host macOS/arm64 only. No iOS, no physical device, no
   real application, no Flutter engine embedding.
8. **The Dart producing lineage is durable only as a bank.** `9e8c898a` is on no
   remote; [#47](https://github.com/mml555/shorebird/issues/47) tracks the repair
   independently and nothing here depends on it being done first.
9. **Two experiment-only instruments exist and are not product.**
   `functionExecutionMode` and `collectAllGarbageForTesting`, both banked, both
   shown non-causal against previously accepted results.

## Provenance

[`verdict.json`](verdict.json) carries a SHA-256 for every input: the freeze
manifest, all three banked source patches, both experiment patches, the G1 build
manifest, the negative-control record, the reproduction and falsification
records, the shared mandatory-evidence inventory, and the five gate transcripts
the matrix is extracted from.

    frozen distribution   selfhost-v1.1.1 / bdb234ab
    producing Dart tree   7b04b01b  (HEAD 9e8c898a plus the uncommitted guard)
    producer engine       dfa2b24a
    reproduction          REPRODUCTION=PASS, from a full clean run
    falsification         12/12 required and 12/12 supplementary mutations refused

## How this verdict was reached

The matrix is assembled by extraction, and the verdict is **computed from it**,
not declared alongside it. On its first run the assembler returned
`ABANDON_OR_REDESIGN` because `SHARED_HEAP` and `OBJECT_IDENTITY` read
`NOT_ESTABLISHED` — I had pointed those two rows at G3's transcript when the
markers live in G2's. The fix was the evidence pointer; the check was left
alone. A verdict that could not have come out any other way would not have been
worth publishing.

## Next-lane routing

    PROCEED  ->  SEMANTIC-MAP-1

Carried forward as mandatory constraints:

- the patchability-contract invariant (`can-be-overridden` per patchable member);
- module-side dynamic-interface validation must become **fail-closed** before
  this design is production-safe;
- explain tooling must not classify module failures from the VM error string.

**Stop boundary.** No semantic-map implementation, assumption instrumentation,
reconciliation, patch-v2, CLI integration, signing change, supported-state
change, or physical deployment begins from this issue.
