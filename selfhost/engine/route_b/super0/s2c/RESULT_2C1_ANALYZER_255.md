# D-SUPER-2C.1 · ANALYZER-255 — CLASSIFICATION A, v11 analyzer regression

Nothing published. H2 unchanged and AUDIT CLEAN, compiler still `9d4ace27…`,
release 140 frozen and un-retrofitted, release 139 untouched. The analyzer fix
was built to scratch dirs, so `out/host_release_arm64/zip_archives/
route_b_analyze.aot` is still byte-identical to the H2 manifest value.

## Correction to the release-140 ledger, accepted

    "full Route B set"   WRONG
    correct: full release-side evidence EXCEPT the required release_import.dill

Release 140's uploaded artifacts are `release_app.dill`,
`dynamic_interface.yaml`, `route_b_retention.json`,
`route_b_capabilities.json`, `route_b_snapshot_profile.json`,
`route_b_profile_binding.json` and the six link tables. There is NO
`release_import.dill` — `agreesWith()` returned false, so the product deleted it
and shipped a release that is installable but not patchable. Fail-closed, and
correct behaviour given a false result.

## 1. Specimens preserved

Surviving ORIGINALS from the release-140 run:

    build/route_b/early_import.dill        3423b615c1ae2d88   42,553,248 B
    build/route_b/prepass.dill             88081e1e38fc07f9   27,235,256 B
    build/ios/shorebird/release_app.dill   c583258d24bbe947   26,306,864 B
    build/app.dill                         c0eac579d96b617d

    late release_import.dill               ABSENT — deleted by the product,
                                           as designed. Recorded as absent; no
                                           regenerated copy is described as it.

Analyzer under test, exactly as the release fetched it from H2:

    route_b_analyze.aot   799a0796c4d20596c40d9742c662ad1644aa1c39485181591d42d51c1f537236
    dartaotruntime        075ccbb2858f299db06c2ef56b1b60c7ab07abdbc7ff413f33d4bb956e09f292

## 2. Reproduced, with full stderr

    A  import   -> import       exit 255
    B  release  -> release      exit 0
    C  import   -> prepass      exit 255
    D  import   -> release_app  exit 255   (reproduction of the late check)

    Unhandled exception:
    Reference to dart:core::Object is not bound to an AST node. A class was expected
    #0 Reference.asClass (package:kernel/canonical_name.dart:520)
    #1 Supertype.classNode (package:kernel/src/ast/types.dart:450)
    #2 ClosedWorldClassHierarchy._topologicalSortVisit (class_hierarchy.dart:1571)
    #3 ClosedWorldClassHierarchy._initialize (class_hierarchy.dart:1487)

The IMPORT kernel fails even against ITSELF. That is arm A, and it settles the
classification: this is not an AOT/non-AOT comparison defect.

## 3. CLASSIFICATION A — the analyzer bytes, proven by control

The CERTIFIED cell's analyzer, on the IDENTICAL specimen:

    cell 4792f0ec analyzer  14538a673160444206b261195cd4c20e0ed68f93d41f49d65c0cfbd4869550d0
    arm A                   exit 0

Same kernel, different analyzer, opposite outcome. So the kernel is within
contract and the analyzer regressed.

Attributed exactly, by `git log -L`:

    140d2883  feat(route-b): analyzer v11 release evidence + narrow-v1 producer gate
    +  final baseHierarchy = ClassHierarchy(base, CoreTypes(base));
    +  final patchedHierarchy = ClassHierarchy(patched, CoreTypes(patched));

A pure addition. v11 silently made a fully-LINKED base kernel a precondition of
EVERY analysis, while the release flow has always passed the
`--no-aot --no-link-platform` import kernel as base for a different question.

### Two distinct sub-faults, not one

Making the hierarchies lazy fixed arms A and B but NOT C and D, which is what
separated them:

    1. EAGER construction        breaks any analysis, even with no changed members
    2. UNCONDITIONAL super-target resolution over the base hierarchy
                                 breaks every analysis that HAS changed members
                                 -- i.e. every real release check

Sub-fault 2 is the one that actually bit release 140.

## 4. Fix verified (NOT published)

    late final baseHierarchy / patchedHierarchy       (deferred)
    final baseIsLinked = base.libraries.any((l) =>
        l.importUri.toString() == 'dart:core' && l.classes.isNotEmpty);
    releaseSuperTargets computed ONLY when baseIsLinked

`releaseSuperTargets` is OMITTED rather than emitted empty for an unlinked base.
Empty is a claim — "the release version of this method direct-called nothing" —
and making it from a kernel that could not be examined would be a measurement
never taken. Absent says we did not look.

    arm A/B/C/D with the fix     exit 0, 0, 0, 0

    arm C  added(non-accessor) 0  -> agreesWith TRUE   (early check passes)
    arm D  added(non-accessor) 0  -> agreesWith TRUE   (late check passes,
                                     release_import.dill would be RETAINED)

So the two kernels DO agree; v11 never got far enough to find out.

### No regression on the patch path

Linked base (`release_app -> prepass`), both analyzers:

    H2 (broken) analyzer   lowering 761, with releaseSuperTargets 761, non-empty 344
    fixed analyzer         lowering 761, with releaseSuperTargets 761, non-empty 344

Identical. The v11 super evidence is fully intact where the base IS linked,
which is exactly the patch path. The fix changes behaviour only for an unlinked
base, where v11 crashed.

## 5. Consequence — H2 cannot be repaired in place

`route_b_analyze.aot` lives inside `route-b-compiler-darwin-arm64.zip`, which is
an ADDRESSED member of the v2 manifest:

    analyzer bytes change -> archive digest changes -> cell address changes

    fixed analyzer   9c62488afa2de99d403bd99554a77709469ec4e74fa52fcfa9cfeb5ec04f506e
    H2 analyzer      799a0796c4d20596c40d9742c662ad1644aa1c39485181591d42d51c1f537236

So a SUCCESSOR CELL is required. No in-place H2 publication, and the qualified
`9d4ace27…` bundle cannot carry this fix.

Note this also means the compiler bundle must be re-qualified for the successor:
`9d4ace27…` was qualified with the v11 analyzer, and the successor's bundle will
differ in one member.

## 6. On `super`

The failed release-time call is not the narrow-v1 authorization itself — here
the analyzer is asked whether the import kernel contains everything the AOT
kernel compiled. But it is the SAME cell-owned analyzer that later produces
`releaseSuperTargets` and the coverage decision, so an unexplained exit 255 sits
directly upstream of trusting the super lane. It is now explained.

## State

    139   NOT PATCHABLE — cell binding failed, route_b.json absent
    140   NOT PATCHABLE — cell binding OK, route_b.json valid with
          engineRevision = H2, but release_import.dill withheld
    H2    ACTIVE, unchanged, AUDIT CLEAN
    fix   verified host-side, NOT published, successor cell required
