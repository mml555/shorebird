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

### The work that is actually left in P1

1. **The Flutter-shaped case, end to end.** Phase 0's dominant sub-blocker was
   methods on a conventionally private `State` class — 7 of 14 blocked emit
   targets on one `_FullscreenVideoViewerState`. The proven specimen is the
   *opposite* shape: a private field on a **public** class. The private-receiver
   path (`dynamic` lowering) is unit-tested and host-proven, not device-proven.
2. **A bind-time table, because a compile-time one cannot see this.** With a
   `dynamic` receiver the front end accepts any member name with no privacy test,
   so `self._x` compiles with or without the flag and fails at **BIND**. Any
   scoring table for the private-receiver case must run the AOT runtime arm —
   `probes/p3_usability.sh` is the working example. **This is a correction to
   P1.1's precommitted table**, which expected a compile-level REFUSE for the
   no-flag case; that holds only for a typed receiver.
3. **Private method/getter call on device**, and a decision on private **writes**
   (Phase 0 saw compound writes **0 times**, so a plain write may not be worth a
   design project — but say so from data, not from silence).
4. **The `🐞` capability-grant hole in the same area:** retaining a private class
   makes it **allocatable from a patch** — the patch constructed `_Dead()` with no
   constructor named in the interface. That is a privacy-boundary defect inside
   P1's own objective, not just a P4 refusal.
5. **Then P1.5**, which is the payoff measurement and the gate on P2.

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
