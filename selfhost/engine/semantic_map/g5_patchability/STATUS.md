# SM1-G5 — work in progress, NOT a gate submission

**Gate:** [#54](https://github.com/mml555/shorebird/issues/54) · updated 2026-09-07

Step 1 closeout: three further predictor defects fixed after PM review. Step 2, the
shipping `.sbrb` demonstrator, is next and nothing is scored until it has a
trustworthy positive control.

## Step 1 — predictor corrections (done)

All five defects were the same mistake in different places: asking a question
about the TARGET when the fact lives somewhere else.

**A. Exact-release retention proof.** Round 1 used
`enforced_at_load.containsKey(c)`, which only means "G4 measured this retention
class". The predictor now takes `--release-pragmas`, the annotations read off
the BUILT RELEASE KERNEL by G4's `dump_pragmas.dart`, and checks the specific
entry for each required class on that declaration. `RETENTION_UNPROVEN` now
fires 10 times on the frozen corpus, where before it could not fire at all.
Missing `--release-pragmas` is refused outright rather than defaulted.

**B. `MISSING_CAN_BE_OVERRIDDEN` reads the release, not the requirement list.**
It asked whether G4's *required* list contained the entry — which it always
does by construction, so the reason was unreachable. It now asks whether the
release kernel carries `dyn-module:can-be-overridden` on that member. It fires
on `Shape.+`, whose contract genuinely omits it.

**C/D. Body facts come from the body.** New `lib/body_references.dart` walks the
Kernel body and reports private type references, private writes and private
reads per declaration, failing closed (`refused:<Kind>`) on anything it cannot
traverse. Validated on both corpora:

    Shape.scale   private write -> _scaled          (the SETTER's body, not the field)
    useHidden     private type  -> _Hidden          (a body naming a private type)
    helperUsesHidden  private type -> _Hidden

Members *of* `_Hidden` are correctly NOT flagged — owning a private class is not
the same fact as naming a private type in a body, which is what round 1
conflated.

**E. Call-site shape is unproven, so it refuses.** `DEVIRTUALIZED_CALL_SITE` and
`INLINED_BODY` had no code able to emit them, so two of #54's named arms
silently defaulted every declaration to patchable. Deciding them needs the
release's machine code, the way SL1-G4 read dispatch-table calls out of the AOT
with llvm-objdump. Until that exists the fact is UNKNOWN and every replaceable
declaration is refused `CALL_SITE_SHAPE_UNPROVEN`.

**Owner ABI propagates.** `Box.unwrap` is no longer predicted patchable on the
strength of its own signature while `Box` is `refused:type_parameters`; it now
refuses `OWNER_ABI_SHAPE_UNSUPPORTED`.

### Result

    predicted patchable   0 of 23      coverage_diagnostic_only 0.0%

    CALL_SITE_SHAPE_UNPROVEN      14
    RETENTION_UNPROVEN            10
    ABI_SHAPE_UNSUPPORTED          9
    OWNER_ABI_SHAPE_UNSUPPORTED    3
    MISSING_CAN_BE_OVERRIDDEN      1
    PRIVATE_WRITE                  1

Zero is the correct answer while call-site shape is undecidable here: under-claim
is safe degradation, and the alternative is defaulting two of #54's arms to
patchable. It also makes the subset check trivially true, which is exactly why
it must not be scored yet — a vacuous subset proves nothing.

## Step 1 closeout — three further defects (done)

**1. The body walker was not actually fail-closed.** It extended
`RecursiveVisitor` and overrode selected node types, so any construct it did not
recognise traversed silently and the body read as clean — the exact false
negative SM1 prohibits. It now has an explicit node allowlist with everything
else landing in `defaultNode` and marking the body unsupported, and the
allowlist is **grounded by census** over both corpora rather than guessed.
Types no longer fall through at all: `defaultDartType` routes every type into
one exhaustive switch that refuses anything it does not model, and named
parameter types — previously skipped — are walked.

**2. Private reads were discovered and then ignored.** The predictor consumed
only writes and private types, and built a G3 index it never used. Every private
reference is now resolved and asked of G3 by mode:

    body reference -> exact referenced declaration -> read/write/construct
                   -> G3 grant decision -> allowed or refused

Reads that G3 grants are ALLOWED, not blanket-refused: `Shape.scaled` reads
`_scaled` and passes, while `Shape.scale` writes it and refuses `PRIVATE_WRITE`,
because for a mutable field the manifest key cannot express which mode it
authorised. An unresolvable reference fails closed.

**3. Release identity was too loose.** The predictor rekeyed G4's pragma dump as
`library#owner#name` and unioned the pragmas, so an entry on `get:x` could stand
as proof for `set:x`. New `lib/release_contract.dart` carries full identity —
library, owner, **kind**, name, vm_name — and marks any key answered by more
than one declaration `ambiguous`, which the predictor refuses rather than
merging. G4's banked tool is untouched, since that gate is closed.

Falsified in `evidence/step1_falsification.txt`: removing one node kind from the
allowlist refuses 14 of 21 bodies; making interface types fall to the default
branch refuses 16 of 21; and the release contract shows `get:perimeter`,
`set:scale` and `get:scaled` holding distinct keys, so one cannot prove
retention for another.

## Step 1 closeout, second pass — exact private-reference identity (done)

`PrivateRef` carried `library + owner + name + mode` but **not the referenced
declaration's kind**, so the predictor searched G3 across kinds and took the
first match. That is the same loose-identity fault removed from the
release-contract path: evidence for one declaration authorising another. The
claim in this file that references resolved to "the exact referenced
declaration" was not yet true.

The kind is now derived from the resolved `Member` — `Field` → field,
`Constructor` → constructor, `Procedure` → its procedure kind — and each
reference carries an exact `target_key`. The predictor does one lookup with **no
fallback**, and a reference whose kind cannot be established is refused rather
than recorded with a guessed one.

New corpus `corpus_ext/g5_accessor_pair` declares a private getter and a private
setter both named `_x`:

    Holder.readIt   read   -> Holder#getter#_x
    Holder.writeIt  write  -> Holder#setter#_x

**This also exposed a bug in my own write policy.** It refused every private
write unconditionally. That is right for a mutable FIELD, whose single bare key
cannot express which mode it authorised, but wrong for a SETTER, whose key names
its mode (`set:x`) and can therefore be proven granted. Refusing both would have
discarded the very row-level distinction exact identity exists to make. The
write branch now consults the resolved row: `Shape.scale` (mutable field) still
refuses `PRIVATE_WRITE`; `Holder.writeIt` (setter) is allowed.

Falsified in `evidence/step1_falsification.txt` §4: removing the kind refuses
both references; corrupting it makes the write consult the getter's row and
refuse `PRIVATE_REFERENCE_UNGRANTED`; and a direct comparison shows the fallback
strategy selecting the **getter** row for a **write**, which is a different
declaration from the one the body names.

## Step 1 closeout, third pass — the allowlist cannot hide a reference (done)

The walker fail-closed on **unknown** node kinds but still allowlisted several
that carry a member reference with **no fact-bearing visitor**. "Allowlisted"
was being used to mean "understood", and it was not: a private reference through
such a node was reported as *no reference at all*.

Every allowlisted kind was audited for `Reference` / `Name` / `Member` fields
and split three ways:

* **modelled** — `InstanceTearOff`, `StaticTearOff`, `ConstructorTearOff`,
  `RedirectingFactoryTearOff`, `InstanceGetterInvocation`, `EqualsCall`, and
  `Super*`/`AbstractSuper*` property and method access, plus `ConstantExpression`
  through an explicit constant walk with a fail-closed default — a constant can
  name a member, and `--aot` folds tear-offs into constants;
* **removed, so they refuse** — `DynamicGet` / `DynamicSet` /
  `DynamicInvocation`, which carry a `Name` but no resolved target and so cannot
  yield an exact `target_key`, and `InstanceCreation`, whose several references
  are unmodelled;
* **genuinely referenceless** — kept. Three allowlisted nodes carry a reference
  that is not to a member (`CheckLibraryIsLoaded`, `LoadLibrary` reference a
  library; `_PrivateName` carries the libraryReference defining a name's privacy
  domain) and so cannot hide a member access.

New corpus `corpus_ext/g5_tearoff` reaches a private member four ways:

    viaStaticTearOff     supported                  #method#_secret
    viaSuper             supported                  Base#method#_hidden
    viaInstanceTearOff   supported                  Base#method#_hidden
    viaDynamic           refused:DynamicInvocation  --

Falsified in `evidence/step1_falsification.txt` §5: deleting
`visitInstanceTearOff` while leaving the node allowlisted makes the private
tear-off **invisible** (still "supported", nothing recorded); re-allowlisting the
dynamic nodes flips `viaDynamic` from refused to "supported" with nothing
recorded.

§5c records a correction worth keeping: the arm first tried to demonstrate this
with `StaticTearOff` and its own output disagreed, because that tear-off is
carried by the constant path as well. Removing both paths makes it *refuse*
rather than go silent, since the constant walk's default is fail-closed — so the
static tear-off is covered twice, and 5a is the arm that actually shows the
false negative.

## Step 2 — the demonstrator: POSITIVE CONTROL ESTABLISHED

    DEMONSTRATOR_FIDELITY=ESTABLISHED

The authorised path, end to end, with success meaning **the observed program
result moved**:

    container_target.dart
      -> gen_kernel --aot --dynamic-interface di.yaml
         (di.yaml GENERATED by gen_dynamic_interface --policy p2, not written by hand)
      -> gen_snapshot --patchable_static_calls --snapshot_kind=app-aot-elf
      -> changed source -> dart2bytecode (528 bytes)
      -> pack_patch.dart --release-build-id --target (811 bytes)
      -> dartaotruntime app.aot patch.sbrb

    before alpha=OLD-a beta=OLD-b
    APPLY ok: 1 target(s)
    after  alpha=PATCHED-a beta=OLD-b

`alpha` moved `OLD-a -> PATCHED-a`. `beta` was not targeted and stayed `OLD-b`,
so the change is attributable to the patch rather than to anything global.

### A release-build precondition, and it fails open

The same patch against a release built **without** `--patchable_static_calls`:

    APPLY ok: 1 target(s)
    after  alpha=OLD-a beta=OLD-b

The paired experiment holds everything but one variable:

    same release source
    same replacement bytecode
    same target
    same container construction
    same apply path
    container REBOUND to each release's build ID
    semantic variable: --patchable_static_calls

The containers cannot be byte-identical: the two AOTs carry different GNU build
IDs, `.sbrb` embeds `release.buildId`, and `pack_patch.dart` requires it. The
container verified hashes, matched the release id, attached the bytecode and
reported success — while the program went on running the old body.

So patchability depends on **how the release binary was produced**, not only on
the declaration; and the absence of that flag is a **silent bypass**, the same
shape SM1-G4 measured for two retention classes, now observed at the apply
layer. G5's exact-release proof will therefore have to cover a release-level
build fact, not just per-declaration retention entries.

It also explains this gate's earlier direct-attach nulls, which were recorded as
a harness state rather than a finding: that harness never passed the flag.
Recording them as "not demonstrated patchable" would have been wrong.

Evidence: [`evidence/positive_control.txt`](evidence/positive_control.txt).

## Step 3 — paired call-site arms (run)

One patch target, `Base.work`, reached four ways in the SAME release and patched
by the SAME `.sbrb`:

| call site | shape | after |
|---|---|---|
| `direct` | concrete receiver, devirtualizable | **`PATCHED-w`** |
| `virtual` | receiver the compiler cannot bind | `OLD-w` |
| `inlined` | `vm:prefer-inline` helper | `OLD-w` |
| `other` | a different declaration (untargeted control) | `OTHER-w` |

**Observed patchability differs by call-site shape** for one declaration, one
patch, one release. The untargeted control never moved, so the change is
attributable to the patch.

The `can-be-overridden` control did **not** rescue the virtual or inlined sites.
Adding the entry changed the release bytes (1,035,488 → 1,035,496, different
sha256) and the recorded contract entry (`['dyn-module:callable']` →
`[..., 'dyn-module:can-be-overridden']`), and changed none of the four observed
values. The mutation was real, not inert — I checked, having first wrongly
claimed the opposite from a coincidence of build IDs.

The direction is the opposite of the naive expectation: the *devirtualized* site
takes the patch and the dispatched ones do not, consistent with
`--patchable_static_calls` making direct calls patchable while an instance
dispatch still reaches the original AOT code object.

**Not classified.** Whether this is `REDUCE_SCOPE` or `MODIFY_MAP_DESIGN` is not
decided here. Evidence: [`evidence/callsite_arms.txt`](evidence/callsite_arms.txt).

### A release-identity finding, carried to G6

The two releases above are **different artifacts with the same release
identity**:

    app.aot      sha 62a17ab7ba56c36b   BUILD_ID 97c212a34226f975f1e700f8ac5b12e6
    app_cbo.aot  sha a63398add9052b7f   BUILD_ID 97c212a34226f975f1e700f8ac5b12e6

Different bytes, different dynamic-interface contracts, identical GNU build ID.
Route B binds a patch to a release by that build ID — `pack_patch.dart` requires
it and the container matches on it — so a patch packed against one of these is
accepted by the other. That is the stale/swapped-proof hazard G6 exists to
close, now observed rather than hypothesised. Recorded; this gate does not act
on it.

## Step 4 — release-level prerequisite in the predictor (plumbed)

Three states, never two, so a missing input cannot become a claim about the
artifact:

    PROVEN          -> no refusal
    NOT_PATCHABLE   -> RELEASE_NOT_PATCHABLE_BUILD
    anything else   -> RELEASE_PATCHABILITY_UNPROVEN

The frozen corpus release currently reports
`UNPROVEN_NO_ARTIFACT_MARKER`, so every replaceable declaration additionally
refuses `RELEASE_PATCHABILITY_UNPROVEN`. Deriving `PROVEN` needs a mechanically
checkable artifact fact; a build transcript saying `--patchable_static_calls` is
not one, and inferring capability from the flag's *effect* would be circular.
That is the remaining work before any subset calculation.



Rebuild on the shipping path, with success meaning THE PATCHED VALUE WAS
OBSERVED — not exit 0, not "attached":

    release source -> exact release AOT/Kernel -> changed source -> bytecode
    -> pack_patch.dart -> .sbrb -> dartaotruntime release.aot patch.sbrb
    -> program observes a deliberately changed result

The superseded direct-attach probe is retained only as a harness observation;
its nulls are explained above and were never findings.

## Then, in order

3. one positive arm: release says OLD, patch must visibly produce PATCHED;
4. paired negatives on the SAME target — open/virtual, direct/devirtualizable,
   inlineable caller, and a `can-be-overridden` contract control — to ask
   whether observed patchability differs by call-site shape alone;
5. only then compute `predicted ⊆ observed`;
6. only then Wonderous + LocalSend.

Whether the call-site distinction implies `REDUCE_SCOPE` (detectable and
conservatively excludable) or `MODIFY_MAP_DESIGN` (required for soundness but
not representable per declaration) is deliberately NOT classified from the
direct-attach nulls.
