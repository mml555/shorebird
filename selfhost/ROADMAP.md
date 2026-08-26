# Roadmap — what to work on, in order

**Set 2026-08-25.** The priority order below is the assignment. `PARITY.md` stays
the authority on any *status*; this file is the authority on *sequence*. Where a
roadmap item and a `plans/` work order disagree about what comes next, this file
wins and the work order should be corrected where it sits.

**The one hard constraint on everything below:** patch boot-lifecycle behaviour is
**frozen** until 100 distinct eligible clients report a first ambiguity
([`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md)). Nothing in this roadmap licenses
touching it.

---

> ## P1.5 CURRENT BLOCKER RANKING: OPEN
>
> Historical-tree execution is infeasible under one pinned modern toolchain.
> Revert-onto-HEAD is mechanically executable but empirically biased toward
> trivial low-churn diffs (Wonderous: 11/40 applicable; 72% excluded; survivors
> median 5 changed lines vs 18 for exclusions). **No current compatibility
> percentage or blocker ranking is claimed.** P2 is proceeding **provisionally**
> from Phase 0 evidence and the independently established limitation.
>
> Written here, at the top, because the failure mode is a reader six weeks from
> now seeing "P2 follows P1" and assuming P1.5 selected it. It did not.
> Evidence: `engine/route_b/coverage/p15_pilot/` and `COMPATIBILITY_STUDY.md`.

## Priority order

| # | item | state |
|---|---|---|
| **P0** | **Close the iOS App Store technical-compliance audit** | **MECHANISM/STATIC AUDIT CLOSED 2026-08-23** — [`APPSTORE_COMPLIANCE.md`](APPSTORE_COMPLIANCE.md). **OPEN-1 (distribution signing) and OPEN-2 (address-space observation) remain DEFERRED VERIFICATION ARMS** — deferred because neither currently threatens the architecture, which is **not** the same as closed. Do not report them as closed |
| **P1** | **Private-library scope** — can replacement code compile with the target library's real privacy identity instead of a synthetic library? | **IN PROGRESS, and it is NOT greenfield — see §P1 below.** The mechanism ships and is wired per-target in the real producer; a private FIELD READ is device-proven. The residual is the Flutter-shaped case, the bind-time arms, and the rescore |
| **P2** | **Widen the replacement ABI** — receiver **+ positional args** | **DONE 2026-08-25 for REQUIRED POSITIONALS: proven on host and on physical iOS**, including private receiver + multiple typed arguments + private-member access in one body (`args=NEW-A-7-FLD`, then rollback to `args=OLD`). Named, optional-positional and type arguments **remain deliberately unsupported and refused before publication** — that is the boundary, not a gap to close next. **It was PROVISIONALLY SELECTED, never corpus-selected**, so its completion says nothing about what the next dominant blocker is | Not corpus-selected: P1.5 produced no ranking. Selected on Phase 0's measured **6/10** plus an independently established architectural limitation, with P1 having just removed the former 9/10 private-scope blocker. Scored on its own fixtures before any broad compatibility claim |
| **P3 / P1.5** | **Determine the next compatibility widening after privacy + required-positionals** | **OPEN, and now a PARALLEL research item — it gates nothing.** Two corpus models tried, neither usable. Its next task is a study DESIGN, not more cases: the era-appropriate-toolchain precommit, and a NEW measurement epoch for analyzer v8 rather than editing `FROZEN_VERSION = 6` in place |
| **P4** | **Route B publication refusal gates** | **CLOSED 2026-08-25.** All five items, live on the publication path in cell `9b5f040c…` — see §P4 |
| **P5** | **Build/config compatibility enforcement** | **CLOSED 2026-08-25**, and much smaller than this roadmap assumed: the authority already existed. One defect fixed, one question left explicitly open — see §P5 |
| **P6** | **Certify inherited workflows** as PROVEN / FAILED / UNSUPPORTED | OPEN, broad, cheap per item |

Further Dart widening waits on **measured** corpus failures from P3 — not on
guesses about which constructs matter.

---

## P0 — App Store technical compliance

**Done when:** we can mechanically state that Route B downloads interpretable data
and executes it only through native code already present in the signed
application.

| sub-item | state |
|---|---|
| 1. bind a proven cell to the exact Dart SDK revision that shipped with it | **CLOSED** — cell `2c4443ce…` ↔ Dart SDK `9e8c898a4d2` ↔ Flutter fork `2c7b8c3ea5`, bound on shipped bytes |
| 2. inspect the **shipped** `Dart_RouteBActivatePatch`, not the old spike file | **CLOSED** — `runtime/lib/object.cc:998`; `engine/spike/` ships nothing |
| 3. prove the path `payload → ordinary data → BytecodeLoader → AttachBytecode → existing InterpretCall` | **CLOSED** — source path anchored end to end, and `AttachBytecode` + `interpreter.cc` are **upstream and unmodified** |
| 4. audit a signed IPA (no `allow-jit`, no `dynamic-codesigning`, no `get-task-allow` in distribution, no downloaded Mach-O execution, no private frameworks) | **CLOSED except distribution signing** — the audited specimen is development-signed, so `get-task-allow` is present. **OPEN-1** |
| 5. runtime: applying a patch creates no executable mapping backed by downloaded bytes | **HALF CLOSED** — entry point measured on device as the `InterpretCall` stub; the address-space check is **OPEN-2**, and must not be run against the frozen measurement specimen |
| 6. write and freeze the invariant | **CLOSED** — [`APPSTORE_COMPLIANCE.md`](APPSTORE_COMPLIANCE.md), with re-audit triggers |

**Do not re-derive 1-3 and 6.** They are recorded with anchors; re-check them only
when a §8 re-audit trigger fires.

**Stating the P0 result exactly, because the short version invites a wrong reading:**

> P0 mechanism/static audit **closed**; OPEN-1 distribution-signing and OPEN-2
> address-space observation remain **deferred verification arms**.

Neither is worth spending time on ahead of P1 — unless a distribution profile for
the Route B app id becomes available opportunistically, in which case OPEN-1 is a
signing step and an entitlement dump.

---

## P1 — private-library scope: what is actually built, measured 2026-08-25

**The starting assumption needs correcting before anyone plans against it.** P1 is
not a design task and it is not even a "prove the design works" task: patch
`0005`'s `resolveInLibrary` approach is **landed in the shipped Dart SDK fork
`9e8c898a4d2`** and **wired into the real producer**, and one shape of it is
device-proven.

| P1 sub-item | actual state |
|---|---|
| **P1.1** host proof | **the positive arm was already proven** (`probe D` 4/4; producer unit tests cover the `dynamic` lowering for a private receiver class). The NEGATIVE arms had never been run — now they have: `probes/p1_private_scope_controls.sh`, **6 of 7 passed and one FAILED**, see below |
| **P1.2** multi-library question | **ANSWERED MECHANICALLY, and the answer is the good one.** The producer emits **one replacement library per target** (`replacement_$i.dart`, in a loop) and passes the flag **per compile**, so each target's compile gets exactly its own library's scope. A multi-library patch is already correct; nothing compiles all bodies into one synthetic module. The architecture you would have had to build is the one that exists |
| **P1.3** integrate into the real producer | **DONE.** `route_b_producer.dart:145` derives `targetLibrary` from the target's own key and passes exactly that; the flag is passed **only** when a granted private access is actually carried, so targets needing nothing private compile under the rules already proven on device and an older cell keeps working. Mismatch is impossible by construction, not by convention. Gated twice more: the release's capability manifest must grant that exact member **and** its enclosing private class, and **every** private identifier in the emitted body must be one of those grants — because the flag makes every private name resolvable, not only the ones the analyzer classified |
| **P1.4** device proof | **PARTIAL.** A private FIELD READ is device-proven (release `31.0.0+1` patch 2, `value() => _secret` → `NEW-PRIV`, iPhone 7, 2026-08-13). A private **method/getter call** is **host-proven only**. A private **write** is **not claimed** |
| **P1.5** rescore Phase 0 | **NOT STARTED, and the reason matters:** Phase 0 was scored with **analyzer v6 on cell `aa915584`, 2026-08-11** — *before* rung D fell (2026-08-12) and before the private path shipped (2026-08-13). **So "9/10 hit private app members" measures a system that no longer exists.** A rescore is a fresh run under v7 and a current cell, and `PARITY.md`'s bookkeeping rule forbids restating figures across the v6→v7 boundary — it must be reported as its own run |

### What the negative controls found — one real hole, now closed twice

`--resolve-private-names-in-library dart:core` **granted the compiled source
dart:core's private namespace**: `_GrowableList` compiled, and the same body
refused under an app library. `0005` guarded on `isDartLib`, which describes the
library being **compiled**, not the library the option **names** — and its own
comment asserted the invariant it failed to enforce, so a code review would have
agreed with itself. Closed in `0005` (loud `StateError`) **and** in the producer
(refuses a `dart:` target library; mutation-checked test). Product exposure was
nil: the producer only ever passes the target's own library.

**Operational consequence, worth scheduling rather than discovering:** the CFE
half is host toolchain, so it takes effect only when the cell's compiler tooling
is rebuilt and republished — a mint. Until then the boundary is held by the
producer guard, which ships with the CLI, and
`probes/p1_private_scope_controls.sh` is **RED against the published cell by
design**. Evidence: `engine/route_b/evidence/p1_private_scope_controls.txt`.

### Bind-time qualification — DONE 2026-08-25, GREEN 8/8

`probes/p1_bind_private_receiver.sh`. **The idiomatic Flutter shape works:** a
patch to a method of a conventionally PRIVATE State class binds and executes,
and its new body reads a private field, reads a private getter and calls a
private method (`NEW-FLDF` / `NEW-GETG` / `NEW-MTHM`) on the host AOT runtime.
That is the shape Phase 0 said dominates — 7 of 14 blocked emit-targets were
methods of one `_FullscreenVideoViewerState` — and the shape the existing device
specimen does **not** cover, which was a private field on a *public* class.

**And the capability question came back the good way.** Arm B4b withheld a
private member from the interface while keeping it **dispatchable in the
release** (called through a dynamic receiver, so nothing can inline it away; the
baseline prints its value). A patch still could not reach it. So **the interface
grant is what gates a patch's reach — not retention, and not the private-name
key.** Members are filtered to the granted set from the patch's point of view,
even for a member the release is dispatching by name at that moment.

Refusal *stages* are recorded because they are not interchangeable: a second
library's private is refused at COMPILE and never reaches bind; an ungranted
member of the target's own class is refused at BIND; and a member that exists
nowhere is the vacuity control that makes the other two mean anything.

Evidence, including the one harness artifact that cost a detour (the C++ smoke
invoke passes a NULL receiver, so *passing* arms also print a
`NoSuchMethodError`): `engine/route_b/evidence/p1_bind_private_receiver.txt`.

### The work that is actually left in P1

1. **`_Dead()` — private-class allocatability. ISOLATED 2026-08-25, fix measured,
   NOT YET IMPLEMENTED.** `probes/p1_dead_allocatability.sh`, GREEN 8/8 + 3
   classified. Diagnosis first, per instruction: the cause is **not** a retention
   side effect, not the binder, and not "classes implicitly retain constructors"
   — it is the dynamic interface's **definition**. `callable:` is parsed with
   `allowStaticDeclarations: true`, and upstream's `_Annotator.visitClass` calls
   `_visitPublicMembers(node.constructors)`; a class's implicit unnamed
   constructor is public. `dynamic_interface_annotator.dart` is **upstream and
   unmodified**, so the authority is decided by what our generator emits.
   **The fix, with both halves measured:** name a private class's MEMBERS
   individually — including the methods a patch may target — and emit **no bare
   `class:` item**. A patch then still attaches and reads privates (Cfix3) while
   construction is refused (Cfix4). **The obvious alternative is refuted:** moving
   private classes to `can-be-used-as-type:` grants type identity but a patch
   cannot ATTACH to a method of the class (Cfix). So the change lives in
   `gen_dynamic_interface.dart` — our own cell tooling, no upstream divergence and
   no producer blacklist as the boundary.
   **PRICED 2026-08-25, and it is free** (`probes/p1_retention_price.sh`,
   `evidence/p1_retention_price.txt`). Member-only retention vs the current
   policy: **−0.01% (toy), +0.00% (real Flutter app), +0.00% at 200 private
   classes**. The generated YAML roughly doubles — a build-time artifact, not
   release bytes — and that is the whole cost. The expectation that it would be
   cheap *because* a bare class item already retains the class's public members is
   confirmed. Two numbers not to misread: `member + all ctors` costs **+8.35%** at
   200 classes, but that arm names every constructor **including private ones**,
   which is strictly broader than today — it is the ceiling that argues for opting
   constructors in one at a time; and the real fixture prices realism, not breadth
   (1 constructor, 19 members in app code), which is the synth arm's job.
   **Constructor opt-in is expressible exactly**, so no invented
   `constructible: true` is needed: `member: ''` grants the unnamed constructor
   and nothing else (C6, measured), `member: '_mk'` a private named one (C3).
   Still to do: implement it, and pair it with the producer-side refusal.
   **Two things this arm also established.** A private *named* constructor already
   needs its own grant (C3), so the hole is specific to PUBLIC constructors. And
   an ungranted construction **aborts the process** — `object.cc:5500 unreachable
   code`, or a named `Unable to find function` — rather than declining, which is
   sharper than the ungranted-MEMBER case (a catchable `NoSuchMethodError`) and is
   why this must be refused pre-publication.
2. **Then batch the mint.** Do not mint for the `dart:` CFE guard alone. One
   SDK-lineage transition carrying: the `dart:` refusal, the constructor
   capability fix, and anything the bind arm proves is genuinely required. Then
   `dart_patches.sh --verify` → mint a coherent cell → producer audit and
   fetch-back → **P0 re-audit trigger #1** → `compatibility.yaml` restamp.
3. ~~**Device-prove the private `_FooState` getter/method path** after the mint:
   exact target/library receipt, successful bind, interpreted execution, a
   visible `NEW-*`, and an unrelated same-screen control still at its release
   value.~~ **DONE 2026-08-25** — `fixtures/privatestate_app`, release `1.0.1+1`
   patch 2 on cell `93a3756…`: `target=NEW-FLD-GET-MTH` on an iPhone 7, receipt
   naming `_FooState.target`, `uep_post_is_interpret_call=1`, `control=CTL`
   unmoved. Two attempts: the first found a producer bug that rendered
   `Instance of '_FooState'._field` to a real screen with nothing failing
   anywhere (`9125eb13`). **All eight conditions observed** — the `OLD`
   baseline was closed by rollback the same day: patch 2 withdrawn with
   `rollback=true`, two tap-launches, `target=OLD` with `next_boot_patch: null`
   and an empty `patches/` directory. The specimen reads
   `release -> OLD`, `patched -> NEW-FLD-GET-MTH`, `rollback -> OLD`, with the
   control at `CTL` throughout.
4. **A decision on private writes**, from data: Phase 0 saw compound writes
   **0 times**, so silence is not the same as evidence either way.
5. **Then P1.5**, fresh — not a reclassification of the 2026-08-11 numbers. The
   old 9/10 stays useful as the historical reason P1 was selected; it is not the
   current engine's acceptance rate.

## P1.5 — the two lanes, split 2026-08-25

**Measurement lane: OPEN, and only one of the three directions preserves the
question.** Era-appropriate toolchains. The other two are rejected *for the main
compatibility claim* and kept for narrower uses:

* **synthetic patch-shaped diffs** — useful for coverage testing later, but they
  are no longer empirical patch history, so they cannot answer "what blocks real
  patches";
* **the 11 Wonderous survivors** — a known-biased population. Usable only if the
  claim is explicitly narrowed to *"small HEAD-applicable maintenance changes"*,
  which is not the question.

The eventual architecture, recorded so it is not improvised case by case:

    real historical commit
        -> read its SDK / Flutter constraints
        -> select a COMPATIBLE HISTORICAL toolchain
        -> build parent as the release
        -> build the commit as the patch
        -> analyse with the CURRENT Route B analyzer and producer policy
        -> record

The hard part is the split it implies: the **release compiler must suit the
historical source** while the **capability model evaluated is today's**. That is
a design with its own precommit, not a harness tweak — and it is expensive
measurement infrastructure, so it is deliberately NOT built before P2. We already
have enough evidence to justify one bounded engineering rung.

**Engineering lane: P2, provisionally.** The justification is stated exactly, and
it is not the corpus: *P2 is selected on prior empirical evidence plus an
independently known architectural limitation, while current-corpus ranking remains
unresolved.* Phase 0 measured signature/arity in **6 of 10** real patches; the
limitation is mechanical and still present; instance methods taking arguments are
unremarkable Dart; and P1 just removed the former 9/10 private-scope blocker,
which makes this the obvious next ceiling. P2 is scored on its own
positive/negative fixtures before any broad compatibility claim is made.

## P3 — what has to clear before the compatibility study restarts

Restart, do **not** continue: the previous 100-row run is **void** and stays void.

1. `G3.6` complete;
2. `R3` released;
3. `dart_patches.sh --verify` green;
4. the historical-corpus methodology **decided** — historical tree builds, *or*
   reverting historical diffs onto a current buildable HEAD. Pick one and write
   down why, before any rows are scored.

Then run the frozen **50 + 50** corpus. Its output is what tells us what remains
after P1 and P2 land — which is the whole reason further widening is sequenced
behind it.

---

## P4 — fail before publication  *(CLOSED)*

> **Every mechanically knowable prerequisite currently required by Route B is
> checked against the exact release and the exact target before publication.
> Unsupported or unverifiable cases fail closed with a reason that does not
> claim more than was measured. Every mandatory refusal gate has a mutation
> proving it affects the publication outcome.**

That is the closure criterion, and it is enforced rather than asserted:
`test/src/route_b_publication_gates_test.dart` fails if any mandatory gate lacks
a positive, negative or mutation arm, and
`probes/p41_producer_end_to_end.sh` runs 18 arms through the real producer
against a fetched-back published cell.

**The invariant:** *if the system publishes a Route B patch, every mechanically
knowable prerequisite for executing that patch has already been proven against
the exact release artifact.*

Justified independently of any corpus ranking, by four things this project has
already measured:

* an optimized-away target attaches green and executes OLD (`G15`);
* a missing constructor capability **aborts the process** at run time
  (`object.cc:5500 unreachable code`) — there is no graceful runtime outcome to
  fall back on;
* a missing target/member capability currently surfaces later than it should;
* unsupported signature shapes are already known deterministically before the
  device ever runs.

### State of each sub-item, surveyed 2026-08-25 rather than assumed

| | what exists | what P4 must build |
|---|---|---|
| **P4.1** target reachability | **CLOSED 2026-08-25.** Cell-owned `route_b_release_probe.aot` over the release's own v8 snapshot profile, bound to the App binary's sha256; producer refuses `NO_SURVIVING_CALLSITE` and `UNKNOWN` with distinct messages. `P41_RELEASE_PROBE_SPEC.md` freezes the contract; four probes gate it, including 10/10 end-to-end through the actual producer with a gate-removed mutation arm. Wording bounded: **survival, never reachability** — `deadBranch` is the permanent control that publishes | — |
| **P4.2** target's own grant | **CLOSED.** `capabilities.refuseTarget` reads `privateClassPublicMembers`, so a target the release never retained is refused by name instead of failing at ATTACH | — |
| **P4.3** ABI/signature refusal | **CLOSED.** The boundary is pinned to CODES, not prose: `UNSUPPORTED_PARAMETER_SHAPE(named_parameters)`, `(optional_positional_parameters)`, `UNSUPPORTED_TYPE_SHAPE(generic_method)`, prepended to the real refusal. An unrecognised shape reason refuses as `UNSUPPORTED_UNCLASSIFIED` — a visible mapping gap, never a pass | — |
| **P4.4** release identity coherence | **CLOSED**, in three layers: release-bound evidence, a per-target receipt, and a binding carried in the container. Target identity is structured (library / owning class / member / signature), never a selector string. The analyzer now emits a signature identity, so a member whose SHAPE changed is refused — and so is one whose shape could not be established | — |
| **P4.5** mutation tests | **CLOSED.** One executable matrix; a mandatory gate without positive + negative + mutation arms fails the suite. Mutation-checked by adding an unwired gate and watching it fail | — |

### THE P4.1 CONSTRAINT, measured before the gate is designed

`PARITY.md` §3 already records the disqualifying case: on the `tagged(String x)`
target, `assert_result_consumed.sh` reported **CONSUMED — correctly** — because
its result fed a string interpolation, while the only call site sat in a **dead
branch** that the app never takes. So:

> **Consumption is necessary but not sufficient. Reachability is a separate
> property that no byte-level gate on the release artifact can see.**

That does not sink P4.1, it *scopes* it. The buildable gate is:

    no surviving call site for this target in the exact release artifact -> REFUSE

which is sound in the direction that matters — it never refuses a patch that
would have worked, and it closes the specific `G15` class where folding removed
every call site. What it must **not** claim is that passing it proves the target
is reached: a dead-branch call site still passes, and the honest CLI message says
"no surviving call site" rather than "unreachable".

**BUILT EXACTLY THAT WAY, 2026-08-25.** The constraint above is now enforced by
tests rather than by intent: `deadBranch` is a permanent control that must
PUBLISH, every mention of reachability in the spec and the probe must carry a
denial, and the CLI's refusal text is asserted never to use the word. See
`engine/route_b/P41_RELEASE_PROBE_SPEC.md` and
`engine/route_b/evidence/p41_closure.md`.

Two consequences were implemented rather than softened, and both are product
decisions to revisit deliberately:

* a release cut before the profile sidecar existed **cannot be patched** — it
  uploaded no evidence, so the question cannot be answered, and an unanswered
  prerequisite is not a satisfied one;
* the probe is the compiler cell's **required eighth file**, so the currently
  published cell resolves as INVALID **until a new cell is minted**.

## P4 — the refusal rule

> **If we publish the patch, the release artifact has demonstrated the
> prerequisites required to execute it.**

Refuse, pre-publication, when:

* the exact release artifact has **no surviving supported invocation path** to the
  target (the general property — a foldable constant is only one cause; inlining
  and dead-code elimination are others);
* the target or call shape is unsupported;
* release identity is incompatible;
* the patch uses an unsupported Route B language construct;
* retention or private-scope requirements are unmet.

**Which signal may gate:** the **static call-site probe against the exact release
artifact** is authoritative, because it runs before publication.
`TPOOL_ABSENT` from the runtime scan is **diagnostic only** — it is observed after
a patch ships and therefore cannot gate. The user-facing message must describe the
condition, not the compiler theory, and must **not** suggest that changing the
patch source repairs it: the defect is baked into the release artifact.

`STATE_OF_THE_SYSTEM.md` §4 has the fuller argument for why this is the highest
-value thing we could hand upstream.

---

## P5 — build/config compatibility identity  *(CLOSED)*

> **Every build input demonstrated to alter patch-relevant compiler semantics is
> compared by the existing canonical build configuration before publication.
> Missing required build-configuration evidence fails closed. No additional raw
> CLI identity is introduced without evidence that the existing gates can admit
> a semantic mismatch.**

**The roadmap assumed a new identity was needed. Measurement said otherwise.**
`probes/p5_build_identity_matrix.sh` ran one variable per row through the real
producer (`evidence/p5_build_identity_matrix.md`):

| dimension | producer | build-config authority |
|---|---|---|
| identical control | publishes | agrees |
| Dart define `A`→`B` | publishes | **disagrees** |
| flavor `foo`→`bar` | publishes | **disagrees** |
| obfuscation off→on | publishes | **disagrees** |
| target | publishes / incidental refusals | agrees — **not represented** |

No P4 binding catches a build-semantics mismatch, and that is correct: a patch
compiled with different defines targets the *same* release artifact, so every P4
binding holds. P5 is a different question.

**`RouteBBuildConfig` is now formally the P5 authority.** It already owns the
effective defines (order-independent, last-wins, absent ≠ empty — each measured,
not assumed), flavor via `FLUTTER_APP_FLAVOR`, and obfuscation, and it already
excludes `--split-debug-info` on evidence that it changes the ELF but not the
stripped program. A `build_identity_v1` over the same inputs was **not** built:
two hashes over one compiler fact is the coherence problem this project keeps
removing.

Flavor is semantic here, measured rather than assumed: with an app that never
reads `FLUTTER_APP_FLAVOR`, the `foo` and `bar` kernels still differ.

### P5.1 — the one demonstrated defect, fixed

A release carrying no comparable build configuration used to be **warned about
and permitted**, which made absent evidence read as agreement. It is now
`BUILD_IDENTITY_EVIDENCE_ABSENT` and refuses. This is what the release side
already intended: `ios_releaser` records `buildConfig: null` only when a build's
define expansion disagreed with Flutter's own, and marks that release
unpatchable when it is cut.

The legacy case stays distinct: an old release also predates the contract
revision and is refused earlier by P4.4 with a message about the epoch, so
reaching P5.1 means a revision-capable release whose evidence is *incomplete* —
corruption, not age. Mutation-checked.

### P5-TARGET OPEN

> `--target` is not represented by the build-semantics authority. The
> differential specimens have not produced a patch that is accepted against a
> release while differing in executable semantics solely because a different
> target was used. The existing refusals for alternate-target specimens are
> partly incidental — a new entry file is rejected as an **added member**, and a
> body referencing a member the release never calls is accepted *correctly*,
> because Route B retains app libraries whole (verified with the release probe:
> `ZERO_QUALIFYING_CALLSITES`, 1 Function node). **No target-identity gate is
> claimed.**

The target is now recorded as provenance on both sides — `releaseTarget` in the
sidecar, and a `P5-TARGET OPEN` detail line at patch time naming both — so if
such a case is ever found the evidence is already there. Instrumentation, not
policy. A test in the publication matrix asserts the absence deliberately, so
adding target to the canonical form has to be a decision rather than a surprise.

Not investigated: whether a target difference matters for a package dependency
outside the retained app libraries. That is the shape a real exploit would take.

---

## Parked, explicitly

Not to be worked until something above moves. Each of these has been parked with a
reason, not forgotten:

* **lifecycle retry policy** — frozen until 100 eligible first ambiguities
  ([`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md));
* further **`G15`** investigation;
* **Arm A** archaeology;
* **`TPOOL_AMBIGUOUS`**;
* pragma experiments;
* desktop platforms;
* a broad **Flutter bump** — cost already measured
  ([`UPSTREAM_INTEGRATION.md`](UPSTREAM_INTEGRATION.md)); do it after any
  hybrid-dependent measurement, since `SNAPSHOT_HASH` moves;
* obscure Dart constructs, until P3 says they matter.
