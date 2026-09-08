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

The `inlined` arm in that table is **withdrawn**: `Base.work` carries
`vm:never-inline` and only the helper was `prefer-inline`, so it could not show a
patched target *body* going stale. Item 2 below replaces it.

**Not classified.** Whether this is `REDUCE_SCOPE` or `MODIFY_MAP_DESIGN` is not
decided here. Evidence: [`evidence/callsite_arms.txt`](evidence/callsite_arms.txt).

## Item 2 — a genuinely inlined target body, proved from machine code

    @pragma('vm:prefer-inline')
    int smallTarget() => DateTime.now().millisecondsSinceEpoch >= 0 ? 41 : 0;

    @pragma('vm:never-inline')
    int callsSmall() => smallTarget() + 1;

A pragma is a request, so the inlining is read out of the shipped `app.aot` with
`llvm-objdump`. `smallTarget` has exactly two source-level call sites — inside
`callsSmall` and directly in `_state` — and **both carry its computation rather
than a call to it**: the `DateTime` call and the `999`/`1000` arithmetic are its
own body.

The claim is *not* argued from symbol absence. `--patchable_static_calls` turns
ordinary static calls into indirect `blr` calls, so "no `bl <smallTarget>`" is
not sufficient on its own; the evidence is the copied computation appearing in
the callers.

Patching it 41 → 141:

    APPLY ok: 1 target(s)
    small=41  callsSmall=42        (both unchanged)

**The ordinary source-level observations under test do not dispatch to the
attached replacement.** They continue executing stale inlined copies of the old
body, while the replacement itself is present and demonstrably computes 141 when
invoked directly. It fails **open** — the
same shape as G4's two retention classes and as a release built without
`--patchable_static_calls`: success reported, nothing done.

### The comparison: non-inlined vs inlined, one release, one container

A single `.sbrb` carries **two** targets applied atomically to the same release.
They are *different functions*, not a controlled same-target pair, so this table
is not the proof — it shows the release, container and apply path working in the
same process while the inlined observations stay old:

| target | machine-code state | after |
|---|---|---|
| `alpha` | not inlined; its computation is absent from `_state` | **`PATCHED-a`** |
| `smallTarget` | inlined; no `bl <smallTarget>` anywhere | `small=41`, `callsSmall=42` |
| `beta` | untargeted control | `OLD-b` |

`APPLY ok: 2 target(s)` for both — and, decisively, the container's own direct
invoke of each attached replacement in the same run:

    ATTACH: C++ invoke of target returned: PATCHED-a
    ATTACH: C++ invoke of target returned: 141

So the intended `smallTarget` replacement really attached and really computes
**141**, while the ordinary source call still reads **41**. Without that, the
stale reading would have been equally consistent with the wrong or unchanged
bytecode being packed — `APPLY ok` is not evidence of replacement semantics, as
this gate established earlier.

**The finding is same-target.** The *same* `smallTarget` has an attached
replacement that demonstrably computes 141 and ordinary call sites that still
read 41, in one process. `alpha`'s role is narrower: it excludes "nothing was
patched at all" by showing the machinery works in that same run. No claim is made
that `alpha` and `smallTarget` differ *only* by inlining — they are different
functions, and the exact machine instruction reaching `alpha` was never
identified.

Full provenance — release AOT, `.sbrb`, both KBC hashes, the container target
list, and the banked replacement sources — is in the evidence file.

Evidence: [`evidence/inlined_target.txt`](evidence/inlined_target.txt).

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

### The witness: a compiler-emitted AOT capability marker

`gen_snapshot` now writes an ELF note beside the build-id note, populated from
the compiler's own parsed `FLAG_patchable_static_calls`:

    .note.shorebird.capabilities
    owner    Shorebird
    payload  schema_version=1;patchable_static_calls=true|false

Not command-line text, not a build transcript, not Dart source, and not a
behavioural patch test. The reader **parses the section table**; scanning for the
string would match the same text anywhere in the artifact, including in a Dart
string literal a patch author controls.

**Identity is the whole section header, not the name.** The reader checks
`sh_type == SHT_NOTE`, `owner == "Shorebird"`, note type `1`, and that exactly
**one** such section exists. A section name is not a signature.

| artifact | result |
|---|---|
| built with `--patchable_static_calls` | `PROVEN` |
| built without it | `NOT_PATCHABLE` |
| frozen uninstrumented toolchain | `UNPROVEN_MARKER_ABSENT` |
| payload key corrupted | `UNPROVEN_MARKER_UNKNOWN_SCHEMA` |
| `schema_version=9` | `UNPROVEN_MARKER_UNKNOWN_SCHEMA` |
| name kept, `sh_type` forged to PROGBITS | `UNPROVEN_MARKER_MALFORMED` |
| owner forged to `Imposter!` | `UNPROVEN_MARKER_MALFORMED` |
| owner forged to `ShorebirdX` (prefix attack) | `UNPROVEN_MARKER_MALFORMED` |
| note type forged to `2` | `UNPROVEN_MARKER_MALFORMED` |
| two sections claiming the name | `UNPROVEN_MARKER_AMBIGUOUS` |

The owner check was a **prefix** comparison and `ShorebirdX` returned `PROVEN` —
a forged owner passing as a compiler-emitted marker. It is now exact: the
declared owner must be `name_size == 10` and byte-equal to `Shorebird\0`, the
`sizeof` the producer writes. Every field of the marker's identity — section
name, `sh_type`, owner, note type, uniqueness, schema version and payload value
— is now falsified by an arm.

Every arm banks its **full AOT sha256** beside the result.

**Producer provenance** is banked in `instrumentation/` — the base Dart revision
and frozen effective tree, the exact source delta and its sha256, and both
`gen_snapshot` hashes (instrumented and frozen-unmodified) — so the causal claim
that the compiler emitted the value from its own parsed flag can be rebuilt
rather than believed.

Absence is never `NOT_PATCHABLE`: an older toolchain does not say, and silence
must not become a claim about the artifact. The exact AOT sha256 is recorded
beside every result.

The marker agrees with observed behaviour: the `PROVEN` release patches
(`direct=PATCHED-w`), the `NOT_PATCHABLE` one does not (`direct=OLD-w`).

**Instrumentation provenance.** Built in an APFS clone at
`/Volumes/build/g5_marker`, never in the frozen lineage — G0–G4 verify effective
tree `7b04b01b`, and modifying it would invalidate every earlier gate. The
frozen `gen_snapshot` is byte-unchanged.

Evidence: [`evidence/capability_marker.txt`](evidence/capability_marker.txt).



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

---

## Route 2 closeout: the four items required before `NOT_INLINED` is a safety fact

Regenerated end to end by [`run_route2.sh`](run_route2.sh), which re-derives the
patch, re-verifies the replay, rebuilds both AOTs, re-runs the reader, and
re-runs both falsification sets with their positive controls.

Every outcome is **asserted, not printed** — 16 assertions covering note-hash
and verdict equality across the two builds, that the whole-AOT hashes still
differ (so the weaker claim cannot be quietly upgraded), per-file replay
equality, the arm count, the shipped reader refusing every arm, both reader
controls failing all but the baseline, and the completeness control being valid
and sensitive. Printing an exit code would let a control that unexpectedly
starts passing leave the run green, which is the same defect as a probe that
cannot fail. The assertion set has already earned its keep: it caught a
duplicated `ENUMERATION_HOLDS` marker the moment the completeness control began
running its own baseline.

### 1. Schema-6 exact private-key carrier — done

The producer emits each side's declaring-library key from
`Library::private_key()`, so the reader removes that **exact** key or refuses.
No regex over `@<digits>`, and never `String::ScrubName`, which also rewrites
`get:`/`set:`. Twenty fields per record, versioned, and provenance regenerated:
`0002` re-derived as a true incremental patch against the git-recovered frozen
base, replay verified byte-for-byte across all three files, producer and AOT
digests recomputed.

The subject changed. `app_s6.aot` is withdrawn as a provenance carrier because
its input kernel could no longer be identified in the work directory, so its
note was not reproducible from a recorded recipe. `app_s6r.aot` is built by a
recorded recipe from a named kernel. Per-declaration verdicts are identical
between the two, so nothing was traded away for the reproducibility.

### 2. Mapper tightened — done

Matching is on `vmName`/`loweredName` only; the canonical `name` fallback is
gone. Owner must agree, with one exception made explicit from G1's own lowering
metadata (`ownerKind in {extension, extension_type}`), because extension
lowering gives the VM a synthetic top-level owner while G1 recovers the
extension owner.

### 3. Full adversarial falsification — done

34 arms, [`evidence/reader_falsification.txt`](evidence/reader_falsification.txt):
note identity (forged owner, an ordinary `GNU` owner, wrong `n_type`, wrong
`sh_type`, two sections claiming the name, live bytes trailing the note inside
its own section, a genuine second Shorebird note in that section, the section
renamed away), section-table and name integrity (`e_shoff` out of bounds,
`e_shstrndx >= e_shnum`, undersized `e_shentsize`, `sh_name` past the string
table, a section name that is not valid UTF-8, `sh_offset`/`sh_size` past
EOF), **the section-name table's own extent** (a `sh_name` past the name table
but still inside the ELF, a `.shstrtab` shrunk so the note's name falls outside
it, a `.shstrtab` extent past EOF, no terminator before the name table's end,
and a big-endian `EI_DATA`), schema and framing (wrong schema, wrong field
count, a declared count that disagrees with the payload, an inflated field
length, a non-numeric field length, a record field that is not valid UTF-8, not
an ELF file, ELF32), and mapper identity (`vmName`/`loweredName` diverging from
a still-matching canonical `name`, a disagreeing owner, a kind moved out of the
projected set, an ambiguous two-row projection, and a private name that no
longer carries its declaring library's key).

Every arm asserts three things: the reader **produced output** — a parser
exception must resolve to a modeled `UNKNOWN`, never a crash, because a crash
writes no rows and an absent row must never be read as a safe row; that **no
candidate is reported `NOT_INLINED`**; and that **the refusal carries the arm's
own code**. The last of those closes a real hole: asserting only "something was
refused" is satisfied by a reader that collapses every problem into one generic
`UNKNOWN`, which would let one gate silently mask another. Refusal codes are
now stable values in the reader's output (`note_error_code`, and a `code` on
every state and unprojected record), and an arm that names no expected code
fails.

Two positive controls, because one is not enough:

* **A — a reader that trusts the note.** `complete = note_ok and not
  unprojected` becomes `complete = True` and the `note_ok` interception is
  removed. 29 of 30 arms flip to `FAIL`, naming the `NOT_INLINED` rows they
  manufactured.
* **B — a reader that refuses without saying why.** Every refusal code is
  rewritten to `GENERIC_FAILURE`, prose untouched. 29 of 30 flip, each naming
  the code it wanted. Control A cannot detect this failure mode at all.

The first version of control B was itself wrong: its regex was `[A-Z_]+`, so
codes carrying digits (`SECTION_NAME_NOT_UTF8`, `ELF32_UNSUPPORTED`,
`..._G1_PROJECTION`) were never collapsed and six arms passed a control they
should have failed. Fixed to `[A-Z0-9_]+`, with an assertion that no specific
code survives the rewrite.

**Section names are now bounded to `.shstrtab`, not to the file.** The reader
read the string table's `sh_offset` but never its `sh_size`, so `name_at()`
validated only "inside the ELF" and searched for a terminator all the way to
EOF. A `sh_name` pointing past the declared name table — or a `.shstrtab`
shrunk so the note's name fell outside its own extent — could still resolve.
The reader now reads `sh_offset` **and** `sh_size`, requires
`sh_name < shstrtab_size`, and bounds the terminator search to the table's end.
It also checks `EI_DATA`, because every unpack hard-codes little-endian.

The old "unterminated section name" arm was the evidence of that gap: it
returned `NOTE_SECTION_ABSENT` rather than `SECTION_NAME_UNTERMINATED`, because
the reader found a later NUL outside the table, decoded a run of garbage as a
name, and merely failed to match. It now names the defect it provokes.

An earlier run of this set is **withdrawn**. It read its output file without
deleting it first, so a crashed run reported the previous arm's result and two
arms were recorded as caught when the reader had in fact crashed. Fixing the
harness exposed three real reader defects: an out-of-bounds `e_shoff` raised
`struct.error`; an unterminated section name raised `ValueError`; and the reader
checked that only one *section* carried the note name but never that the note
consumed its section, so a second Shorebird note appended inside the same
section would have been silently ignored.

### 4. Recorder completeness — done, and it bounds the claim

[`evidence/recorder_completeness.md`](evidence/recorder_completeness.md) is the
argument; [`lib/verify_completeness.sh`](lib/verify_completeness.sh) re-derives
every count and gate from the tree and exits non-zero on drift. It caught an
error in the document while that document was being written.

**The first positive control for it was invalid and its transcript is
withdrawn.** It built the control tree with `cp -c -R src dst`, which fails
across volumes; the `|| cp -R` fallback then ran with the destination already
partly created and nested the tree at `vm/vm/…`, so `grep -r` still found
content while every direct path was missing. The enumeration therefore reported
`ENUMERATION_DRIFTED` **because files were absent**, while the two
`NextInlineId` checks it was supposed to flip actually *passed*. A missing file
had been allowed to masquerade as a flipped check.

[`lib/falsify_completeness.sh`](lib/falsify_completeness.sh) replaces it and
asserts, rather than prints: the baseline must hold; twelve named files must be
present or it refuses to run at all; the planted call site must be
*observable* (`NextInlineId` mentions in `inliner.cc` go from 2 to 3); and the
flipped set must be **exactly** the two `NextInlineId` checks, with every other
check still passing.

* Every copy of a Dart body's IL into another function is registered by
  `FlowGraphInliner::NextInlineId`, which has **exactly one caller** in the
  tree; the recorder reads that registry in the `FlowGraphCompiler` constructor,
  and AOT has **exactly one** `FlowGraphCompiler` construction site.
* The recorder runs before code is finalized, so a discarded recompilation
  **over**-records. Over-recording withdraws a safety claim; it cannot
  manufacture one.
* A second family — the `CallSpecializer` replacements — materializes a callee's
  semantics with no inline id. Its gates close for recognized methods
  (`recognized_kind` is assigned in one place, from a closed macro list naming
  built-in VM libraries; the `vm:recognized` pragma is a `DEBUG` check, not an
  assignment) and for operators on application classes (every branch requires
  operand class ids from a fixed VM-primitive set). They do **not** close for a
  field's VM-synthesized implicit accessors.

So the reader admits `NOT_INLINED` only for `method`, `getter`, `setter` and
`operator`. `field`, `constructor` and `factory` are candidates that **refuse**,
each naming the mechanism; `class` rows are reported as declaring no body; any
unclassified kind fails closed. The reader asserts
`len(states) + len(no_body_rows) == len(g1_rows)` and exits non-zero otherwise,
so no G1 row can silently disappear. The reconciliation is machine output, not
prose:

```text
total_g1_rows          36
INLINED                 2
NOT_INLINED            15
UNKNOWN                14
NO_BODY                 5
accounted              36
```

with `accounted == total_g1_rows` asserted in the reader, which exits non-zero
otherwise.

Two limits are stated rather than closed: front-end (CFE/`gen_kernel`) constant
materialization happens before the VM compiler and cannot appear in this note,
which is why `field` refuses rather than resting on the registry argument alone;
and the completeness enumeration covers the AOT path only, not JIT.

### Current reader state

`validated=True complete=True`, 0 in-scope unprojected, 3,010 out-of-scope,
and the accounting above. Note content is deterministic across two runs on the
same input kernel and the verdicts are identical, while the two whole-AOT
hashes differ — that is note/verdict determinism, **not** byte-reproducible
executable output, and downstream gates must bind to one exact `app_s6r.aot`
SHA rather than treating the second build as interchangeable.

Every refusal names a code: `KIND_NOT_COVERED_BY_PROOF` for the 13 field and
constructor rows, `ONLY_SYNTHETIC_CHILD_INLINEE` for `tearOffTarget`,
`ABSENT_FROM_VALIDATED_NOTE` for the 15 that carry the safety fact.

Still not authorized, and not done: predictor wiring, subset scoring, G5
classification, and virtual/instance dispatch — the `Base.work` bypass remains a
separate unresolved mechanism. #47 remains open, independent, and off this
critical path.
