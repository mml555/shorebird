<!-- cspell:words semantic dill devirtualizes -->
# SM1-G1 — stable declaration identity

**Gate:** [#50](https://github.com/mml555/shorebird/issues/50) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07 · **Verdict: identity is stable and sufficient over the corpus. 17/17, no collisions.**

Transcript: [`evidence/g1_identity.txt`](evidence/g1_identity.txt) ·
structured: [`evidence/g1_identity.json`](evidence/g1_identity.json) ·
controls: [`evidence/harness_controls.txt`](evidence/harness_controls.txt).
Reproduce: `run_g1.sh`.

## The inherited constraints, honoured mechanically

    1. build from effective Dart tree 7b04b01b   run_g1.sh REFUSES to start otherwise
    2. pin the shipped analyzer 67741a08…        read from the G0 manifest and echoed
    3. never derive identity from dill order     a property of the tool: it takes
                                                 no position input at all
    4. include the index-derived control         emitted as `index_id` beside every
                                                 declaration, and required to FAIL

## The identity

    declaration_id = sha256( library ⊘ owner_path ⊘ kind ⊘ declared_name )

`⊘` is U+0000 — it cannot occur in a library URI, a class name or a Dart
identifier. A printable separator would let `a|b` and `ab|` collide by
concatenation, which is a collision the map would be *inventing* rather than one
the program has.

Every human-readable component is **retained beside** the hash — `library`,
`owner`, `name`, `kind`, `static`, `synthetic`, `vmName`, `selector`. The hash is
not the only representation; an id nobody can read is an id nobody can debug.

`DECLARATION_ID` is independent of `ABI_FINGERPRINT` and `BODY_FINGERPRINT`
(SM1-G2). The `body_only` mutant confirms the load-bearing consequence: a body
change leaves the identity **stable**, so the map can say *"same declaration, new
implementation"*.

## Results — 17 cases

**G0's frozen corpus, 12 cases.** The subject's identity is stable under every
one, including the four ABI mutants where only a signature moved:

    body_only · abi_added_positional · abi_nullability · abi_positional_to_named
    abi_generic_bound · abi_return_type · reorder · unrelated_added
    unrelated_removed · unrelated_renamed · field_added · private_other_domain

`private_other_domain` matters: `corpus.helper::_privateHelper` and
`corpus.app::_privateHelper` share a simple name across privacy domains, and the
identity keeps them apart because the library is a component.

**G1's corpus extension, 5 cases** — the sufficiency conditions #50 lists that
G0's dimensions do not reach. Kept in `corpus_ext/` with its own expectations so
**G0's frozen digest stays valid and its acceptance is not disturbed**:

| case | required | observed |
|---|---|---|
| `ext_extension_member` | stable | stable — an extension member elsewhere does not disturb the subject |
| `ext_renamed_subject` | **moved** | moved |
| `ext_kind_change` | **moved** | moved (function → getter; the VM name changes too, `topLevel` → `get:topLevel`) |
| `ext_owner_change` | **moved** | moved (top level → static member of `Shape`) |
| `ext_moved_library` | **moved** | moved |

## Sufficiency: two gaps in the reference tool's coverage

`gen_target_manifest.dart`'s `{library, class, name, kind}` was the starting
point, and its field separation and deterministic sort are the right foundation.
Two things it cannot name, both found here:

1. **Constructors and fields.** It walks `lib.procedures` and `cls.procedures`
   only. Generative constructors are `Constructor` nodes and fields are `Field`
   nodes, so `Shape.square()` and `Shape.sides` are invisible to it.
2. **Classes.** A class is a declaration, and a **generic bound, a supertype and
   a type-parameter list live on it, not on any member**. `abi_generic_bound`'s
   subject *is* the class `Box` — a map that names only members cannot express
   that change at all.

This gate's tool names all of them: **23 declarations in base — 2 class,
3 constructor, 1 factory, 3 field, 2 getter, 10 method, 1 operator, 1 setter.**

## No collisions

Searched across **all 18 variants**, not just base: zero `declaration_id`
collisions. A collision is a `FAIL_OPEN` — two distinct declarations sharing one
id is what would silently misroute a patch — so it is searched for rather than
assumed away.

## The controls, and why they are not decoration

**The order-derived control earns its place three different ways.** `index_id` is
derived from position on purpose and is never a candidate:

| case | canonical | index-derived | what the control shows |
|---|---|---|---|
| `reorder` | stable | **moved** | fails exactly where an order-derived identity is wrong |
| `ext_extension_member` | stable | **moved** | would have reported an *untouched* declaration as changed |
| `ext_kind_change` | **moved** | stable | would have reported a *changed* declaration as unchanged |

The last two matter most: they show the control is a genuinely different function
and errs in **both** directions, not a copy of the canonical one that happens to
disagree once.

**The scorer is falsifiable too.** Flipping one G1 expectation to a false claim —
that a renamed declaration keeps its identity — makes it fail:

    FAILED  ext_renamed_subject  subject …::topLevel vanished but was expected stable
    SUMMARY checks_failed=1   G1 IDENTITY FAILED
    (restored)                G1 IDENTITY VERIFIED

## Two harness defects found and fixed

Both were mine, and both would have produced a wrong reading:

1. **Subjects were resolved by matching a joined selector string.**
   `Shape.perimeter` never matched `Shape.get:perimeter`, and a bare `Box`
   matched nothing, so two cases reported *"subject not found in BASE"*.
   Resolution is now **structural** — library + owner + name — which is the same
   defect `gen_target_manifest.dart` records about its own harness: it used
   `"Class.name"`, split on the first dot, and forced callers to know a VM
   internal.
2. **`Field` carries no `isSynthetic`** in this kernel AST, though `Procedure`
   and `Constructor` do. `synthetic` is recorded `false` for fields because it is
   **unknown, not determined**, and the emitted schema says so. It is metadata
   and is not an input to the identity.

## Findings for later gates

- **A library URI is part of the identity, so renaming a package re-identifies
  every declaration in it.** That is correct — the declarations did move — but it
  is a real consequence for **SM1-G6** to weigh when it binds a map to a release,
  not a defect of the identity.
- **Obfuscation does not affect `declaration_id`**, because the map is derived
  from the kernel and obfuscation happens at snapshot time. What it *does* affect
  is the runtime-resolvable `vmName`. The identity is obfuscation-invariant; the
  **binding name is not**, and needs the release's obfuscation map. Recorded here
  rather than measured, because no obfuscated release was built in this gate.

## Acceptance

- [x] Identity stable across every listed non-change; moves on rename, re-owning and kind change
- [x] Body mutation provably does not alter `DECLARATION_ID` (`body_only`)
- [x] The index-derived control **fails**, in both directions, proving the harness can detect the defect
- [x] Collisions searched across the whole corpus — 18 variants, zero
- [x] Human-readable components retained beside the hash

## Not established by this gate

- **Extension members are covered only as a non-disturbance case.** An extension
  member's *own* identity is emitted as a procedure of its enclosing library, and
  whether that is the right owner path for a patch to target is not tested here.
- **Synthetic and generated members** are named but not exercised as subjects.
- **Obfuscation** is reasoned about, not measured.
- **Nested generic ownership** is covered only through `Box<T extends Shape>`.
