<!-- cspell:words semantic dill devirtualizes -->
# SM1-G1 — stable declaration identity

**Gate:** [#50](https://github.com/mml555/shorebird/issues/50) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-07, extended after PM review · **Verdict: identity is stable and
sufficient over the corpus. 22 cases + 6 arms, 0 failures, no collisions.**

One finding reaches past this gate: `gen_kernel --aot` **tree-shakes declarations
away**, so which kernel the map is derived from is a design decision, not an
implementation detail. See *Kernel domain* below.

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

## The four contract gaps the PM held on, now closed

### 1. Obfuscation — measured, not reasoned

An obfuscated snapshot is actually built, with `--save-obfuscation-map`:

    declaration_id under obfuscation   UNCHANGED
    obfuscation map entries            4,579
    our declarations renamed           topLevel->pF  Shape->Ji  area->lF  usesPrivate->rF

**Identity is obfuscation-invariant; the binding name is not.** The map is
kernel-derived and obfuscation is a snapshot-time transform, so `declaration_id`
does not move — but the runtime-resolvable name does, and binding therefore needs
the release's obfuscation map. Both halves are on the record because only
measuring the first would have implied the second was fine.

### 2. Recompilation — its own arm

An **independent** rebuild in a separate work directory, compared on the
**complete** declaration-id set: identical, 23/23. G0's deterministic-dill result
is supporting evidence, not a substitute for this.

### 3. Extension-member identity — distinctness, not just non-disturbance

Two same-named members in different extensions:

    ShapeX.doubled  vs  BoxX.doubled     distinct ids, differing by OWNER
    kernel lowered them to ShapeX|doubled / BoxX|doubled

The kernel lowers an extension member to a **mangled top-level procedure** —
`ShapeX|doubled`, owner `null`. Taking that at face value would put a VM-internal
mangling into what becomes a wire contract, the same complaint
`gen_target_manifest.dart` records about `get:`/`set:`, and would leave the
extension name buried in a string. The tool now reads the `Extension` nodes and
recovers the real owner and declared name, so the two differ **by owner** rather
than by accident of the mangling. `loweredName` is retained beside it so a reader
can see the lowering without the identity depending on it.

Renaming the extension owner moves the identity, as required — compared against
`ext_extension_member` rather than `base`, because base declares no extension and
the subject does not exist there. Baselines are now per-case and declared.

### 4. Nested, synthetic and generated scope

**Local functions are not named**, and that is now an explicit scope statement
rather than an omission:

> The map does not address local/nested functions. A patch targeting one must be
> **refused** rather than silently missed. Carried to SM1-G5.

**Generated members are named and flagged.** For a class with an implicit
constructor and a mixin application:

    Doubler.base        method       synthetic=False
    Mixed.<unnamed>      constructor  synthetic=True
    Mixed.base          method       synthetic=False

### Plus the generic-owner arm

`Box.unwrap` with the owner's bound changed `<T extends Shape>` → `<T extends
Object>`: **identity stable**. The member was not renamed, re-owned or re-kinded,
so it is the same declaration. Whether it is still ABI-compatible is **SM1-G2's**
question — G1 must not smuggle ABI semantics into identity.

## Kernel domain — the finding that reaches past G1

    AOT kernel      28 declarations
    pre-AOT kernel  33 declarations
    removed by --aot:
      Doubler.doubledViaMixin                     (method)  <- user-written
      _Mixed&Object&Doubler                       (class)
      _Mixed&Object&Doubler.<unnamed>             (constructor)
      _Mixed&Object&Doubler.base                  (method)
      _Mixed&Object&Doubler.doubledViaMixin       (method)

`gen_kernel --aot` runs the global transformations, and TFA removes declarations.
`Doubler.doubledViaMixin` is **written by the developer, called from `main`, and
absent from the AOT kernel** — the mixin was inlined into `Mixed`.

So **a map derived from the AOT kernel describes a tree-shaken program, not the
program that was written.** Which kernel it is derived from is a design decision:

- **AOT kernel — the conservative choice.** It names only what survived, so it
  cannot claim a shaken-out declaration is patchable.
- **Pre-AOT kernel — unsafe on its own.** It would name declarations the release
  does not contain, which is an over-claim and a `FAIL_OPEN` under **SM1-G5**'s
  subset rule.

**Recommendation:** derive the map from the AOT kernel, and carry the pre-AOT set
alongside **only as explanatory data** — so *"you wrote it and it is not here"*
can be explained rather than merely refused. That is a G5/G6 concern and is not
decided here.

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

## The scorer fails closed on missing evidence

Three checks were tightened after PM review, and each is shown able to fail —
[`evidence/scorer_hardening.txt`](evidence/scorer_hardening.txt):

**1. A must-move case has to prove a destination.** Disappearance from the old
key is *not* evidence the identity moved: a walker that simply dropped the
declaration would satisfy it. Each must-move case now declares
`expected_new_subject`, and the scorer requires the old key **absent**, the new
key present **exactly once**, and a **different** `declaration_id`.

    destination removed      FAILED  absence alone does not show the identity moved
    destination nonexistent  FAILED  found 0 time(s), want exactly 1

**2. Nested scope is scored, not merely reported.** Locals being named was
printing `FINDING` without incrementing failures. The accepted scope is
`nested_functions_named: 0`, and any other count now **fails** — changing that
scope is a deliberate decision, not a finding.

    scope set to expect 1 while 0 are named   FAILED

**3. The synthetic flag is required, not observed.** The arm used to fail only
when *no* generated members were found, so it could green with
`flagged_synthetic == 0`. A specific row is now required to exist **and** carry
the flag.

    required synthetic=false on a row flagged true   FAILED  want … saw …

## A harness defect this pass exposed — non-reentrant builds

`build_corpus_dill.sh` builds at a **stable path**, because the `rootUri` is
baked into the dill and cross-run determinism is what lets G0's frozen release
identity be re-verified at all. A stable path plus `rm -rf` is **not reentrant**,
and during this hardening pass two overlapping harness runs destroyed each
other's work directory — the second reported *"could not produce base ids"* for a
reason with nothing to do with the map.

A unique path per run would fix the race and break determinism, so the builder
now takes an **atomic `mkdir` lock** and serialises.

The first lock was itself wrong: it ended with `[[ -d "$LOCK" ]] || exit 2`, which
proves only that *a* lock exists — possibly another process's — so a contender
could proceed into the shared directory and later delete a lock it never owned.
Acquisition is now proven by `mkdir` succeeding, and the cleanup trap is
installed only after that. Controls, including a timeout negative where a foreign
holder keeps the lock for the whole budget, are banked in
[`../g0_freeze/evidence/build_lock_controls.txt`](../g0_freeze/evidence/build_lock_controls.txt).

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
- [x] **Obfuscation measured**, both halves: identity invariant, binding name not
- [x] **Recompilation** as its own arm — complete id set identical across an independent rebuild
- [x] **Extension-member distinctness** proven, differing by owner rather than by mangling
- [x] **Nested/local scope** stated explicitly as out of the map's domain, fail-closed
- [x] **Synthetic/generated members** named and flagged
- [x] **Generic-owner** arm: member identity stable while the owner's bound changes
- [x] **Must-move cases prove a destination** — old key absent, new key present exactly once, different id
- [x] **Nested scope fails closed** if locals ever become independently named
- [x] **The synthetic flag is required**, not merely observed

## Not established by this gate

- **Which kernel the map should use is not decided here** — only measured, with a
  recommendation. It belongs to G5/G6.
- **Synthetic members are named and flagged but not exercised as patch subjects.**
  Whether a generated member is a legitimate target is SM1-G5's question.
- **Obfuscated binding is not exercised end-to-end.** The rename is measured; that
  a patch actually binds through the obfuscation map at runtime is not shown here.
- **Extension-member patchability** is not claimed. Distinctness of identity is
  proven; whether an extension member can be patched at all is G5's.
- **Nested generic ownership** beyond `Box<T>` — deeper nesting, generic methods
  on generic owners — is not covered.
