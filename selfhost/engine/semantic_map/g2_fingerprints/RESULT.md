<!-- cspell:words semantic dill devirtualizes -->
# SM1-G2 — ABI and canonical body fingerprints

**Gate:** [#51](https://github.com/mml555/shorebird/issues/51) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07 · **Verdict: 15/15 cases, independence proven both ways, no failures.**

One finding forced a design correction inside this gate rather than a note for a
later one: **`gen_kernel --aot` strips parameters**, so the ABI cannot be read
from the AOT kernel at all.

Transcript: [`evidence/g2_fingerprints.txt`](evidence/g2_fingerprints.txt) ·
structured: [`evidence/g2_fingerprints.json`](evidence/g2_fingerprints.json) ·
the kernel-domain measurement:
[`evidence/kernel_domain_abi.txt`](evidence/kernel_domain_abi.txt).
Reproduce: `run_g2.sh`.

## The finding: --aot strips parameters

| declaration | pre-AOT | AOT |
|---|---|---|
| `topLevel(int x)` | `req=1 pos=1` | **`req=0 pos=0`** |
| `Shape.area(int,int)` | `req=2 pos=2` | **`req=0 pos=0`** |
| `Shape.scale` (setter) | `req=1 pos=1` | `req=1 pos=1` |
| `Shape.+` (operator) | `req=1 pos=1` | `req=1 pos=1` |

Ordinary methods and top-level functions lose their parameters; setters and
operators keep theirs. **Two different declared signatures therefore erase to the
same empty shape.**

This is not a G1 carry-forward note — it is a correctness requirement for this
gate. Computing the ABI from the AOT kernel made `abi_added_positional` and
`abi_positional_to_named` report **`abi_equal`**, which is precisely the
over-claim SM1-G5 forbids. The gate's own arms caught it.

### The corrected design

    DOMAIN  which declarations exist    AOT kernel      conservative: only what
                                                        survived can be patchable
    ABI     the declared interface      PRE-AOT kernel  the AOT signature is the
                                                        post-TFA specialisation,
                                                        not the interface
    BODY    the implementation          BOTH            combined conservatively:
                                                        changed if EITHER moved

Where a declaration has no pre-AOT counterpart the ABI is recorded
`UNAVAILABLE_NO_PRE_AOT_COUNTERPART` with `abi_shape:
unknown:no_pre_aot_counterpart` — never silently taken from the AOT signature.

The pre-AOT kernel is built `--no-aot` **with the platform linked**. Adding
`--no-link-platform` leaves `dart:core` references unbound and kernel throws
inside `InstanceInvocation.visitChildren`:

    Reference to dart:core::num::@methods::+ is not bound to an AST node

The body walk has to traverse those nodes, so the platform must be linked.
Invocation targets are keyed by **canonical name read off the `Reference`**
rather than by dereferencing to a `Member`, so the same encoder works on both
kernels.

## Results

    same ABI + different body  ->  changed_existing_declaration
      body_only                    abi=  body≠

    different ABI  ->  not_reusable_under_old_abi   (one dimension each)
      abi_added_positional         abi≠  body≠
      abi_nullability              abi≠  body=
      abi_positional_to_named      abi≠  body=
      abi_generic_bound            abi≠  body=
      abi_return_type              abi≠  body=

    unrelated-program mutation  ->  both fingerprints identical
      reorder · unrelated_added · unrelated_removed · unrelated_renamed
      field_added · private_other_domain

    canonicalization exclusions, each with its own arm
      g2_local_rename              abi=  body=   candidate_unchanged
      g2_stmt_order                abi=  body≠   changed_existing_declaration
      g2_typeparam_rename          abi=  body=   candidate_unchanged

`field_added` keeps the boundary G0 set: the *method* is unchanged, so the
fingerprints say unchanged. Whether the owning class's layout change makes it
unsafe to reuse is **SM1-G5's** question and is not smuggled in here.

## Independence, demonstrated in both directions

    4 cases move the ABI with the body IDENTICAL
      abi_nullability · abi_positional_to_named · abi_generic_bound · abi_return_type
      -> a body-derived ABI would have reported equal

    1 case moves the body with the ABI IDENTICAL
      body_only
      -> an ABI-derived body would have reported equal

Neither fingerprint is computed from the other: the ABI is built from signature
nodes, the body from a walk of the function body.

## Canonicalization exclusions, enumerated and justified individually

**Body — excluded:**

1. **Source positions** (`fileOffset`, file URIs) — incidental source metadata.
2. **Local variable names**, encoded by binding ordinal instead — justified by
   `g2_local_rename`, which renames a local and must report `body_equal`.

**Body — deliberately NOT excluded:**

- **Statement and expression order** — execution order is observable, and
  `g2_stmt_order` swaps two independent statements and **must** move the
  fingerprint. If it reported equal, the canonicalizer would be discarding
  something that changes behaviour.
- Literal values (`body_only`), invocation target identities, named-argument
  names at call sites.

**ABI — excluded:**

3. **Type-parameter names**, encoded by position and bound — justified by
   `g2_typeparam_rename` (`Box<T>` → `Box<S>`), which must report `abi_equal`.
   Named-parameter *names* are **not** excluded: a call site names them, so a
   rename is an ABI break.

## The map states the refusal boundary

    a named parameter    ->  abi_shape: refused:named
    a generic class      ->  abi_shape: refused:type_parameters
    base census          ->  22 supported, 1 refused:type_parameters

The ROADMAP P2 boundary is a field **in the row**, not something a caller has to
infer.

## Cross-check against the incumbent oracle — three disagreements, all explicable

Printed Kernel stays the incumbent reference and is emitted as
`incumbent_printed_sha256`. It agrees on 12 cases and disagrees on 3, in **both**
directions:

| case | ours | incumbent | reading |
|---|---|---|---|
| `abi_positional_to_named` | abi ≠ | printed **equal** | the incumbent is blind to a signature-only change on an AOT kernel |
| `abi_generic_bound` | abi ≠ | printed **equal** | it prints the *member*; a class-level bound change is invisible to it |
| `g2_local_rename` | body = | printed **differs** | it prints local names, so it over-reports a rename our canonicalization correctly excludes |

The first two are the same finding seen from the incumbent's side, and they are
worth stating carefully:

    int area(int w, int h)  ->  int area(int w, {required int h})

is reported **unchanged** by printed-AOT-Procedure comparison, and
`coverage/parity.sh` builds its kernels with `--aot` and says so — *"matching the
real pipeline"*.

**What this does and does not establish.** It establishes that the printed-AST
oracle **alone** cannot see a signature-only change on an AOT kernel. It does
**not** establish that the production pipeline would ship such a patch: ROADMAP
P2 refuses named arguments before publication by a separate mechanism, and
whether that refusal fires first is **SM1-G5's** question. Recorded, not
concluded.

The third disagreement is the incumbent being *stricter* than necessary — safe,
but it would refuse a patch whose implementation is genuinely identical.

## Parity with G1

The identity is **recomputed** in this tool rather than imported, and the two
implementations are compared on the same input: **23 shared declarations, 0
disagreements**. Shared code would make the check prove nothing — the reasoning
`coverage/parity.sh` applies to the reference tooling.

## Acceptance

- [x] Both fingerprints computed independently; neither derived from the other, shown in both directions
- [x] Every adversarial arm classifies as specified
- [x] The refusal boundary is represented in the map, not inferred by a caller
- [x] Canonicalization exclusions enumerated and justified individually, each with its own arm
- [x] `DECLARATION_ID` / `ABI_FINGERPRINT` / `BODY_FINGERPRINT` remain separate; identity is stable across every same-declaration comparison

## Not established by this gate

- **No semantic equivalence.** Whether two differently written algorithms compute
  the same result is out of scope, by design. The body fingerprint is a canonical
  *structure*, not a meaning.
- **Whether the pre-AOT ABI is the right domain for every declaration class.**
  Extension members, synthetic members and declarations absent from one kernel
  are represented, but which kernel *should* be authoritative per class is a G5/G6
  decision.
- **No real application.** Wonderous and LocalSend are frozen in G0 and not
  exercised here; the corpus is the adversarial one.
- **`REDUCE_SCOPE` was not needed.** Canonical body fingerprinting did not turn
  into a compiler project, so `MODIFY_MAP_DESIGN` was not triggered.
