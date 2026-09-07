<!-- cspell:words dynmod localsend wonderous devirtualized devirtualization KBC dill -->
# SEMANTIC-MAP-1 — tracker and gate design (DRAFT FOR REVIEW)

**Status: DRAFT. No issues filed, no implementation started.**
Predecessor: [SEMANTIC-LINKER-1](../engine/semantic_linker/README.md), closed at
`PROCEED`.

## Objective

SEMANTIC-LINKER-1 proved the *runtime* can execute a mixed AOT/bytecode program
correctly. It says nothing about how a release decides **which** declarations may
be reused and which must be recompiled. That decision is this lane's subject.

> Can a release publish a **semantic map** that decides, per declaration, reuse
> versus recompile — **soundly, never over-claiming patchability** — at a cost a
> release can afford?

The safety property is asymmetric and worth stating plainly: a map that refuses
something patchable costs compatibility. A map that **claims** something is
patchable when it is not ships a broken patch. Every gate below is weighted
toward catching the second.

## This is unification, not greenfield

Four of the six semantic claims already exist in ad-hoc, separately-measured
form. The lane's first job is to find out whether they agree with each other.

| claim | what exists today |
|---|---|
| stable identity | `route_b/identity/gen_target_manifest.dart` — `{library, class, name, kind}` plus a `reachable` verdict and reason |
| ABI equivalence | ROADMAP P2 — receiver + required positionals supported; named, optional-positional and type arguments **refused before publication** |
| privacy domains | ROADMAP P1 — private-library scope; `--resolve-private-names-in-library`, and the frozen guard refusing platform libraries |
| retention | `SUPPORTED_STATE.yaml` retention policy `p2` plus constructor grants derived from the release's own census |
| patchability capability | the capability manifest and the existing refusal rules (ROADMAP P4) |
| optimizer assumptions | SEMANTIC-LINKER-1 G4 — deferred to `AOT-ASSUMPTIONS-1`, not re-litigated here |

Member difference is currently defined as **printed-AST equality**
(`route_b/packaging/build_patch.dart`). Whether that is the right definition of
"semantically unchanged" is a question this lane must answer rather than inherit.

## Inherited constraints — mandatory, not aspirational

From SEMANTIC-LINKER-1's closeout. Each is a design rule for every gate below.

1. **Verdicts are derived from evidence, never declared beside it.** Summary
   matrices are extracted at run time; a row whose marker is absent reads
   `NOT_ESTABLISHED`, never a remembered conclusion.
2. **One source of truth for mandatory inventories and counts.** Validator and
   falsifier read the same file; the equality `inventory == tested == caught` is
   asserted at run time.
3. **Every major claim gets an adversarial / withheld-information arm.** The
   happy path was uninformative in SEMANTIC-LINKER-1 and will be here.
4. **Negative arms require explicit confound analysis.** A negative that fails
   for the wrong reason is worse than none — SL1's `missing_retained_import`
   passed while measuring nothing because a `vm:entry-point` pragma retained the
   symbol independently of the contract under test.
5. **`FAIL_OPEN` is a first-class result**, never collapsed into pass/fail.
6. **[#47](https://github.com/mml555/shorebird/issues/47) stays off the critical
   path.** The lane builds from the G0-banked frozen lineage; if #47 ever becomes
   load-bearing that is a scope change to be flagged, not absorbed.

Plus the three carried out of SEMANTIC-LINKER-1's verdict:

7. Patchable members must carry the `can-be-overridden` contract.
8. Module-side dynamic-interface validation must become fail-closed before
   production.
9. Module-failure classification cannot rely on VM error strings alone.

## Proposed gates

Ten, in the shape of #36: each independently falsifiable, each with a stop
condition, each with an adversarial arm.

### SM1-G0 — Freeze the map's inputs, corpus, and reference implementations
Freeze the release lineage, the corpus pins (`coverage/demand1/*.window.txt`),
the analyzer version, and the two existing reference implementations that
`coverage/parity.sh` already cross-checks.
**Adversarial:** a mutated dill must not produce an identical map.
**Stop:** if the frozen corpus or analyzer identity does not match, stop.

### SM1-G1 — Stable declaration identity
An identity that survives unrelated edits, member reordering, recompilation, and
(separately) obfuscation — and that **changes** when the declaration itself does.
**Adversarial:** reorder members; rename a *different* member; add and remove
unrelated declarations; toggle obfuscation. The untouched declaration's identity
must not move.
**Confound:** the identity must not derive from anything order-dependent. Include
a deliberately index-derived identity as a **positive control on the test** — if
the harness cannot fail that one, it proves nothing about the real one.
**FAIL_OPEN:** two distinct declarations colliding on one identity.

### SM1-G2 — ABI equivalence
Decide when a compiled caller's expectation is unchanged.
**Adversarial matrix, each must classify NOT-equivalent:** return type; added
required positional; positional made optional; added named parameter; changed
type argument; nullability; field type; const-ness; changed supertype.
**Confound:** printed-AST equality is the incumbent definition. The gate must
exhibit both directions of disagreement — printed-AST differs while ABI is equal
(formatting, comments), and printed-AST equal while ABI differs, if such a case
exists. If none exists, that is a finding worth recording, not a blank.
**Boundary:** named, optional-positional and type arguments are *refused* today.
The map must state the refusal, not silently mis-classify.

### SM1-G3 — Privacy domains
Which private namespace each declaration belongs to, and what a patch may
resolve.
**Adversarial:** resolve a private name in a different library; in a **platform**
library (must refuse — the frozen `source_loader.dart` guard); a tree-shaken
private name; a private **write** where only a read was granted.
**Confound:** the platform-library guard is uncommitted-but-shipped source. The
lane must build from the frozen effective tree `7b04b01b`, or that refusal will
not fire and the arm will pass vacuously.

### SM1-G4 — Retention
What a release must retain per patchable declaration, and whether it actually
does.
**Adversarial:** withhold each retention class in turn; each must fail closed at
load with an attributable category.
**Confound — the one SL1 was bitten by:** `vm:entry-point` retains independently
of the contract. Every retention control must first prove the pragma is absent,
or it measures nothing.
**Cost:** SL1 measured **+1.88% retained AOT per declared-patchable member**. The
map must project retention cost for a whole release, and that projection must be
checked against a real measurement, not extrapolated from one member.

### SM1-G5 — Patchability capability, and the over-claim rule
Per declaration: patchable or not, and by which mechanism.
**The central safety property.** A declaration the map marks patchable that is
not patchable is the link-percentage lie Shorebird's own reporting exists to
prevent.
**Adversarial:** construct a case for every refusal reason — devirtualized;
inlined; unsupported ABI shape; missing `can-be-overridden`; private write;
generated code — and require refusal **before publication**.
**Corpus check:** the map's predicted-patchable set must not exceed what actually
patches on Wonderous and LocalSend. Predicted ⊄ actual is a `FAIL_OPEN`.

### SM1-G6 — Map identity, versioning and binding
The map has a stable digest, a schema version, and is bound to the release it
describes.
**Adversarial:** a map from a different release; an unknown schema version; a
corrupted map. Each must refuse, reusing SL1's category vocabulary
(`HOST_IDENTITY`, `MODULE_INTEGRITY`).
**Carry forward:** classification must not rely on the VM error string alone —
SL1 showed corrupt bytecode reporting as an import failure.

### SM1-G7 — Categorized negative controls
One shared inventory; every failure class; `FAIL_OPEN` first-class; the
`inventory == tested == caught` equality asserted at run time. Direct reuse of
SL1-G6A's structure and of `g6c_harness/falsify.sh`.

### SM1-G8 — Cost
Map size; generation time; effect on release build time and AOT size; projected
retention cost. Reported independently, raw samples retained, no production
threshold imposed in this lane.

### SM1-G9 — Clean one-command reproduction
Mirrors SL1-G6C: fresh inputs, rebuild rather than inherit, mandatory-evidence
refusal, structured output, falsification matrix derived from one inventory.

### SM1-FINAL — Classified verdict
Matrix extracted from evidence; verdict computed from the matrix.

## Dependency order

    G0 → G1 → G2 → G5 → FINAL          (critical path)
              G3 ┘
              G4 ┘
    G6 after G1 (needs a map to bind)
    G7 in parallel once any map exists
    G8 after G4 and G5
    G9 integrates

G1 is on the critical path because identity underpins every later claim: ABI
equivalence, privacy scope, retention and capability are all *per declaration*,
and a declaration you cannot name stably cannot be reasoned about at all.

## Allowed final verdicts

`PROCEED` · `MODIFY_MAP_DESIGN` · `MODIFY_ANALYZER` · `REDUCE_SCOPE` ·
`ABANDON_OR_REDESIGN`

(Deliberately different from SL1's set — this lane's failure modes are about the
*map*, not the runtime. Names are a proposal; the PM should fix them before G0.)

## Stop boundary

No patch-v2 format, no CLI integration, no signing change, no supported-state
change, no physical deployment, and no `AOT-ASSUMPTIONS-1` instrumentation from
inside this lane.

## Open questions for the PM — these change the gate design

1. **Is printed-AST equality the definition to keep?** G2 can either *validate*
   it or *replace* it. Validating is cheaper and lower-risk; replacing is a
   larger lane. This is the single biggest scope fork.
2. **Does the map ship inside the cell, or beside the release?** The analyzer
   ships in the compiler cell because the kernel format is version-locked to the
   frontend. The map describes a *release*, which argues for shipping with the
   release. That choice changes G6's binding rules.
3. **Is the corpus still Wonderous + LocalSend?** Their producer-demand baselines
   (50.00% / 92.67%) are frozen and re-usable, but they were selected for a
   different question.
4. **Should G5's over-claim rule be a hard refusal or a reported percentage?**
   Shorebird reports a link percentage. A map that refuses instead of reporting
   is a different product decision, not just a different gate.
5. **Are the five verdict names above the right ones?**
