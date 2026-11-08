<!-- cspell:words dartaotruntime KBC dill semantic linker devirtualizes -->
# SL1-G6A — categorized negative controls

**Gate:** [#43](https://github.com/mml555/shorebird/issues/43) · **Run:** 2026-09-06
**Verdict: 6 of 11 exercisable negatives fail closed with the expected category. Five FAIL OPEN, and that is the result.**

One command: `run_negatives.sh`. Structured output: [`evidence/negatives.json`](evidence/negatives.json).
Transcript with every raw message: [`evidence/negatives.txt`](evidence/negatives.txt).

## Non-vacuity is enforced, not asserted

The positive path is built and run first from the same work directory with the
same inputs; if it does not load the module and reach the patch override, the
run **aborts** before any negative is attempted. Every negative is that positive
with exactly one thing changed.

## Outcomes

Four outcomes, never collapsed into pass/fail — "did not fail" is the one that
matters most and must not score the same as "failed with a different category".

| negative | exit | expected | observed | outcome |
|---|---|---|---|---|
| `truncated_kbc` | 134 | MODULE_INTEGRITY | MODULE_INTEGRITY | **closed, expected** |
| `wrong_bytecode_version` | 134 | MODULE_INTEGRITY | MODULE_INTEGRITY | **closed, expected** |
| `wrong_import_dill` | 255 | HOST_IDENTITY | HOST_IDENTITY | **closed, expected** |
| `tree_shaken_target` | 134 | IMPORT_RESOLUTION | IMPORT_RESOLUTION | **closed, expected** |
| `missing_retained_import` | 134 | IMPORT_RESOLUTION | IMPORT_RESOLUTION | **closed, expected** |
| `malformed_kbc` | 134 | MODULE_INTEGRITY | IMPORT_RESOLUTION | closed, **wrong category** |
| `wrong_platform_dill` | 0 | HOST_IDENTITY | — | **FAIL OPEN** |
| `wrong_runtime_build` | 0 | HOST_IDENTITY | — | **FAIL OPEN** |
| `no_extendable` | 0 | DYNAMIC_INTERFACE_POLICY | — | **FAIL OPEN** |
| `no_type` | 0 | DYNAMIC_INTERFACE_POLICY | — | **FAIL OPEN** |
| `member_not_overridable` | 0 | DYNAMIC_INTERFACE_POLICY | silent bypass | **FAIL OPEN** |
| `corrupt_digest` | — | MODULE_INTEGRITY | not applicable at this layer | see below |

## Finding 1 — the whole DYNAMIC_INTERFACE_POLICY category fails open

None of the four policy negatives is enforced anywhere in this toolchain path. A
module that extends a class the contract does not mark `extendable`, or names a
type the contract does not expose, compiles and loads without complaint.

The mechanism **exists**: `KernelTarget.validateDynamicModule`
(`pkg/front_end/lib/src/kernel/kernel_target.dart:1815`) runs
`dynamic_module_validator.validateDynamicModule` — but only when the CFE option
`dynamicInterfaceSpecificationUri` is set while compiling the module. Neither
shipped tool sets it: `dart2bytecode` has no such option at all, and
`gen_kernel`'s `--dynamic-interface` is consumed on the **host** compile, where
it annotates rather than validates.

So the fence is present in the front end and unreachable from the module
compiler. Anything that later wants policy violations to fail closed has to
route module compilation through a CFE invocation that sets that option.

`member_not_overridable` is the worst of the four because it does not merely
load — it produces **silently wrong behaviour**: the module loads, the call
devirtualizes, and the host implementation answers while everything reports
success. That is G4's bypass seen from the failure-mode side, and it is the
strongest argument for the patchability-contract invariant.

## Finding 2 — corrupt bytecode is indistinguishable from an import failure

`malformed_kbc` fails closed (abort, exit 134) but reports:

    bytecode_reader.cc:1118: error: Unable to find class ° in Library:'dart:core'

The corruption produced a garbage class name, and the VM reported it as a
*lookup* failure. Any future patch-explain tooling that classifies on this
message alone will call a corrupt module an import-resolution problem and send
the reader after the wrong thing. Truncation and a bad version word are
distinguishable; arbitrary corruption is not.

## Finding 3 — two HOST_IDENTITY negatives are not reproducible on this lineage

`wrong_platform_dill` (module compiled against another build's
`vm_platform.dill`) and `wrong_runtime_build` (host snapshot run by another
build's `dartaotruntime`) both **succeeded**. That is correct behaviour, not a
missing check: all the builds in this lane share Dart revision `9e8c898a` and
therefore the same `SNAPSHOT_HASH`, because the G2 and G3 instruments were
deliberately placed in `runtime/lib/object.cc` and `bootstrap_natives.h`, which
are not in `VM_SNAPSHOT_FILES`.

So this is also a corroboration: the instruments did not perturb snapshot
identity, exactly as their design claimed. Forcing a genuine mismatch needs a
different Dart lineage, which is outside this gate.

## Finding 4 — `corrupt_digest` is not a substrate concern

`loadDynamicModule` takes raw bytes and carries no digest. Integrity of a
*delivered* patch belongs to the cell/patch layer — `verify_cell_members.sh`,
the addressed cell, the signing model — not to the runtime substrate. Exercising
it here would test a mechanism this gate does not contain, so it is recorded as
`NOT_APPLICABLE_AT_THIS_LAYER` rather than faked.

## Two harness defects, fixed before the numbers were trusted

1. `retained()` carried `@pragma('vm:entry-point')`, which retained it
   independently of the contract — so withdrawing `callable` changed nothing and
   `missing_retained_import` passed while measuring nothing. With the pragma
   removed it fails correctly at `bytecode_reader.cc:1172`.
2. The first scorer collapsed everything into pass/fail, which hid the
   distinction this gate exists to make. It now reports four outcomes.

## Categories, for reuse

`MODULE_INTEGRITY`, `HOST_IDENTITY`, `IMPORT_RESOLUTION`,
`DYNAMIC_INTERFACE_POLICY`, plus `FAIL_OPEN_SILENT_BYPASS` and
`NOT_APPLICABLE_AT_THIS_LAYER`. Classification is signature-based on the
observed message, and the message is banked beside every verdict so the mapping
can be re-derived rather than believed.
