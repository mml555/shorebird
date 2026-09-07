<!-- cspell:words semantic dill devirtualizes -->
# SM1-G2 — ABI and canonical body fingerprints

**Gate:** [#51](https://github.com/mml555/shorebird/issues/51) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07, hardened after PM review · **Verdict: 19/19 cases,
independence proven both ways, every row's body encoding complete, no failures.**

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

## Five blocking defects closed

Each was real, and the gate's own arms or the new fail-closed status caught them.

**1. Formal parameters collapsed.** The walk began at `f.body`, so formals never
entered the local table and every reference encoded as `VarGet#-1` — making
`pick(int a, int b) => a` and `=> b` **identical**. Formals are now registered in
declaration order, and an unregistered variable is a **refusal**, not an ordinal.
New arm `g2_formal_b` moves the body.

**2. Field initializer contents were discarded.** The field body recorded only
`present`/`none`, so `final x = 1` → `final x = 2` stayed equal. The initializer
**expression** is now encoded. New arm `g2_field_init_b`.

**3. Constructor initializer lists were omitted.** They are separate Kernel
structure, not reachable from `function.body`, so `Shape.square() : sides = 4` →
`: sides = 5` vanished entirely. Constructors now encode `c.initializers`. New
arm `g2_ctor_init`.

**4. The generic visitor silently dropped semantic fields.** `defaultNode`
emitted only a node's runtime type plus its children, which cannot support the
claim that *only* positions and local names are excluded — every scalar and
reference field of every un-special-cased node was dropped. Replaced with an
**explicit allowlist**: each supported node has its behaviour-relevant fields
written out, and an unrecognised kind sets
`body_status: refused:unsupported_node:<Kind>`. **An unsupported body can never
classify as `candidate_unchanged`** — the classifier returns
`refused:unsupported_body` first.

The allowlist was grounded by censusing the node kinds the corpus actually
produces, **on both kernels**. Censusing only the pre-AOT side was itself a
mistake the run exposed: `--aot` folds literals into `ConstantExpression`, which
the first allowlist refused on 5 rows. Constants have their own allowlist and
encode by **value**.

**5. The owner's generic ABI was unresolved.** `Box.unwrap` reads `T → T` while
`Box<T extends Shape>` becomes `Box<T extends Object>`, so its own ABI does not
move. Every member row now carries **`owner_abi_fingerprint`**, and reuse
requires *both* to match. New arm `g2_owner_bound_member`: `abi=` `body=`
`owner≠` → `not_reusable_under_old_abi`.

## An ABI leak the independence arm caught

While fixing #1 I emitted formal types and the return type into the **body**
encoding. That made the body a partial function of the ABI, and
`abi_return_type` promptly moved the body fingerprint — the independence arm
failed and named it. Formals are now **registered but not emitted**, and the
return type is not written to the body at all.

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
      g2_local_rename              abi=  body=  owner=   candidate_unchanged
      g2_stmt_order                abi=  body≠  owner=   changed_existing_declaration
      g2_typeparam_rename          abi=  body=  owner=   candidate_unchanged
      g2_formal_b                  abi=  body≠  owner=   changed_existing_declaration
      g2_field_init_b              abi=  body≠  owner=   changed_existing_declaration
      g2_ctor_init                 abi=  body≠  owner=   changed_existing_declaration
      g2_owner_bound_member        abi=  body=  owner≠   not_reusable_under_old_abi

    every row's body encoding is complete
      all 23 rows encoded within the allowlist

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
| `g2_formal_b` | body ≠ | printed **equal** | it emits a constant-table *reference*, and indices are per-kernel — see below |

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

The third is the incumbent being *stricter* than necessary — safe, but it would
refuse a patch whose implementation is genuinely identical.

**The fourth is the sharpest, and the mechanism is not parameter stripping.**
Full detail in [`evidence/incumbent_findings.txt`](evidence/incumbent_findings.txt):

    source        pick(int a, int b) => a      vs      => b
    printed AOT   static method pick() -> dart.core::int
                    return #C1;                        (IDENTICAL)
    actual        IntConstant(1)                       IntConstant(2)

`--aot` stripped the parameters and folded each body to a constant; the printer
then emitted a constant-**table reference**, and table indices are assigned *per
kernel* — so two independently compiled dills each name their own first constant
`#C1`. A printed-text diff across two kernels therefore compares **indices, not
values**, and can report unchanged for a changed constant.
`build_patch.dart` compares a base and a patched dill, which are separately
compiled.

Our fingerprints encode the constant's **value**, so both the AOT-side and
pre-AOT-side body fingerprints move.

**Still not concluded:** whether production would ship such a patch. P2 refuses
named arguments by a separate mechanism and the analyzer computes more than a
printed diff; whether any of that fires first is **SM1-G5's** question.

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
- [x] Formal parameters are in the body's scope; parameter selection moves the fingerprint
- [x] Field initializer contents and constructor initializer lists are encoded
- [x] Body encoding is an explicit allowlist; an unsupported node refuses the row and can never be `candidate_unchanged`
- [x] The owner/type relationship is carried as `owner_abi_fingerprint`, and reuse requires both to match
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
