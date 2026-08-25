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

## Priority order

| # | item | state |
|---|---|---|
| **P0** | **Close the iOS App Store technical-compliance audit** | **MECHANISM/STATIC AUDIT CLOSED 2026-08-23** — [`APPSTORE_COMPLIANCE.md`](APPSTORE_COMPLIANCE.md). **OPEN-1 (distribution signing) and OPEN-2 (address-space observation) remain DEFERRED VERIFICATION ARMS** — deferred because neither currently threatens the architecture, which is **not** the same as closed. Do not report them as closed |
| **P1** | **Private-library scope** — can replacement code compile with the target library's real privacy identity instead of a synthetic library? | **IN PROGRESS, and it is NOT greenfield — see §P1 below.** The mechanism ships and is wired per-target in the real producer; a private FIELD READ is device-proven. The residual is the Flutter-shaped case, the bind-time arms, and the rescore |
| **P2** | **Widen the replacement ABI** — receiver **+ positional args**, then named/type args where required | OPEN. **6/10 Phase-0 patches needed instance methods with their own parameters.** The required-positionals work is a starting point; the objective is ordinary method compatibility |
| **P3** | **Resume the Phase 1 compatibility study** — the frozen 50 + 50 real-patch corpus | BLOCKED, deliberately. Prerequisites below |
| **P4** | **Route B publication refusal gates** | OPEN. Turns known constraints into automatic refusals |
| **P5** | **Android build/config compatibility enforcement** | OPEN. A wrong-flavor patch can currently be accepted |
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
   anywhere (`9125eb13`). **One condition is unobserved** — no launch rendered the
   `OLD` baseline, because the patch was published before the first tap. One
   rollback and two taps would close it and demonstrate rollback at the same
   time.
4. **A decision on private writes**, from data: Phase 0 saw compound writes
   **0 times**, so silence is not the same as evidence either way.
5. **Then P1.5**, fresh — not a reclassification of the 2026-08-11 numbers. The
   old 9/10 stays useful as the historical reason P1 was selected; it is not the
   current engine's acceptance rate.

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

## P5 — build/config compatibility identity

A platform-neutral compatibility identity covering the semantic build inputs —
flavor, Dart defines, target, obfuscation state where applicable — then refuse
mismatched patches. The Android *mechanism* needs no further code-push
investigation; this is about refusing a patch built for a different
configuration.

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
