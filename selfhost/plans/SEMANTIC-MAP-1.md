<!-- cspell:words dynmod localsend wonderous devirtualized devirtualization KBC dill -->
# SEMANTIC-MAP-1 — tracker and gate design

**Filed as [#48](https://github.com/mml555/shorebird/issues/48) with ten child
issues [#49–#58](https://github.com/mml555/shorebird/issues/48). PM decisions of
2026-09-06 are incorporated; this file mirrors the tracker body.**

Predecessor: [SEMANTIC-LINKER-1](../engine/semantic_linker/README.md), closed at
`PROCEED`.

## Objective

SEMANTIC-LINKER-1 (#36, closed at `PROCEED`) proved the runtime can execute a
mixed AOT/bytecode program correctly. It says nothing about how a release decides
**which** declarations may be reused and which must be recompiled. That decision
is this lane's subject.

> Can a release publish a **semantic map** that decides, per declaration, reuse
> versus recompile — soundly, never over-claiming patchability — at a cost a
> release can afford?

## The central invariant

> **False negatives cost compatibility. False positives can ship incorrect code.
> Therefore every safety decision fails closed, and `FAIL_OPEN` is a first-class
> outcome.**

## This is unification, not greenfield

Four of the six semantic claims already exist in ad-hoc, separately-measured
form. The first job is to find out whether they agree with each other.

| claim | what exists today |
|---|---|
| stable identity | `route_b/identity/gen_target_manifest.dart` — `{library, class, name, kind}` plus a `reachable` verdict and reason |
| ABI equivalence | ROADMAP P2 — receiver + required positionals supported; named, optional-positional and type arguments refused before publication |
| privacy domains | ROADMAP P1 — private-library scope; `--resolve-private-names-in-library`, and the frozen guard refusing platform libraries |
| retention | `SUPPORTED_STATE.yaml` retention policy `p2` plus constructor grants derived from the release's own census |
| patchability capability | the capability manifest and the refusal rules (ROADMAP P4) |
| optimizer assumptions | SEMANTIC-LINKER-1 G4 — deferred to `AOT-ASSUMPTIONS-1`, not re-litigated here |

## Three separate identities — do not conflate them

    DECLARATION_ID     names the declaration; MUST NOT change when the body changes
    ABI_FINGERPRINT    parameters, named/optional shape, type parameters and bounds,
                       return type, member kind, static/instance, owner/type relationship
    BODY_FINGERPRINT   canonical Kernel structure, excluding incidental
                       serialization order and source metadata

Printed-Kernel representation (`route_b/packaging/build_patch.dart`) stays an
**incumbent reference oracle**, not the wire contract. It prints Procedure nodes
because binary offsets and canonical indices are unstable; it does not define ABI
compatibility and must not be promoted to that role.

This lane does **not** attempt arbitrary semantic equivalence. Whether two
differently written algorithms compute the same result is out of scope. If
canonical Kernel structural fingerprinting turns into a large compiler project,
classify `MODIFY_MAP_DESIGN` rather than silently becoming a research lane.

## Architecture: the map ships beside the release

    compiler/analyzer cell   defines schema support, extraction semantics,
                             canonicalization algorithm
    release artifact         contains semantic-map.json (or binary equivalent),
                             its digest, the release Kernel digest, AOT/release
                             identity, and producing cell/toolchain identity

The map describes one specific release, so it belongs to that release. The cell
is an **input identity**, not the storage location. This also keeps future
releases from requiring new compiler cells merely because they have new maps.

## Corpus

    REAL-WORLD REGRESSION      Wonderous, LocalSend  (continuity anchor)
    ADVERSARIAL SEMANTIC       purpose-built, one mutation dimension at a time,
                               expected classification checked mechanically

Wonderous and LocalSend were selected for a different question and are not
sufficient evidence for map soundness on their own. No third real application is
added yet; if G5/G7 shows the two give materially different conclusions the
adversarial corpus cannot explain, that becomes a named follow-up.

The historical `50.00%` / `92.67%` producer-demand numbers stay **Route B
producer-demand baselines**. They are not semantic-map quality scores.

## Execution map

- [ ] #49 — SM1-G0 — Freeze inputs, corpus and reference implementations
- [ ] #50 — SM1-G1 — Stable declaration identity
- [ ] #51 — SM1-G2 — ABI and canonical body fingerprints
- [ ] #52 — SM1-G3 — Privacy domains
- [ ] #53 — SM1-G4 — Retention contract and measured cost
- [ ] #54 — SM1-G5 — Patchability capability and over-claim safety
- [ ] #55 — SM1-G6 — Map schema, identity, versioning and release binding
- [ ] #56 — SM1-G7 — Cost at release scale
- [ ] #57 — SM1-G8 — Clean reproduction and centralized negative/falsification inventory
- [ ] #58 — SM1-FINAL — Extracted verdict and next-lane routing

## Dependency order

    #49 → #50 → #51 → #54 → #57 → #58        G0 → G1 → G2 → G5 → G8 → FINAL
                  ↘ #52 ↗                              ↘ G3 ↗
                  ↘ #53 ↗                              ↘ G4 ↗
    #50 → #55 ────────↗                       G1 → G6 ────↗
    #53/#54 → #56 ────↗                       G4/G5 → G7 ─↗

G1 is on the critical path because every other claim is *per declaration*: a
declaration that cannot be named stably cannot be reasoned about at all.
**FINAL depends on G8** — SEMANTIC-LINKER-1 established why.

## Mandatory design constraints

Inherited from SEMANTIC-LINKER-1's closeout. Each is a rule for every gate.

1. **Verdicts are derived from evidence, never declared beside it.** Summary
   matrices are extracted at run time; a row whose marker is absent reads
   `NOT_ESTABLISHED`, never a remembered conclusion.
2. **One source of truth for mandatory inventories and counts.** Validator and
   falsifier read the same file; `inventory == tested == caught` is asserted at
   run time, never hand-maintained.
3. **Every major claim gets an adversarial / withheld-information arm.**
4. **Negative arms require explicit confound analysis.** A negative that fails
   for the wrong reason is worse than none.
5. **`FAIL_OPEN` is a first-class result**, never collapsed into pass/fail.
6. **#47 stays off the critical path.** The lane builds from the G0-banked frozen
   lineage; if #47 becomes load-bearing that is a scope change to flag, not absorb.

Carried out of SEMANTIC-LINKER-1's verdict:

7. Patchable members must carry the `can-be-overridden` contract.
8. Module-side dynamic-interface validation must become fail-closed before
   production.
9. Module-failure classification cannot rely on VM error strings alone.

## Allowed final verdicts

| verdict | meaning |
|---|---|
| `PROCEED` | All safety-critical map claims hold; no unexplained over-claim; costs measured; known refusals explicit. |
| `MODIFY_MAP_DESIGN` | The map model/schema/fingerprint/binding representation is inadequate, but the required information exists and a redesign appears viable without changing the runtime model. |
| `MODIFY_ANALYZER` | The map model is sound, but the extractor/classifier implementation fails to derive it correctly. |
| `REDUCE_SCOPE` | Soundness is achievable only by mechanically excluding a named declaration/feature class. The exclusion itself must be decidable fail-closed. |
| `ABANDON_OR_REDESIGN` | Required safety information cannot be derived reliably from available release/compiler evidence, or distinct unsafe states are fundamentally indistinguishable. |

Precedence, applied mechanically:

    analyzer bug under a valid model            -> MODIFY_ANALYZER
    model cannot represent the distinction      -> MODIFY_MAP_DESIGN
    model works after excluding a decidable
      feature class                             -> REDUCE_SCOPE
    cannot mechanically identify or exclude
      the unsafe class                          -> ABANDON_OR_REDESIGN

There is no generic `FAIL`.

## Stop boundary

No patch-v2 format, no CLI integration, no signing change, no supported-state
change, no physical deployment, and no `AOT-ASSUMPTIONS-1` instrumentation from
inside this lane.

## Next-lane routing

- `PROCEED` → `AOT-ASSUMPTIONS-1`
- `MODIFY_MAP_DESIGN` / `MODIFY_ANALYZER` / `REDUCE_SCOPE` → re-scope and re-run
  the affected gates before routing
- `ABANDON_OR_REDESIGN` → stop and reassess the architecture

Design draft: `selfhost/plans/SEMANTIC-MAP-1-DRAFT.md`.
