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
| **P1** | **Private-library scope** — can replacement code compile with the target library's real privacy identity instead of a synthetic library? | OPEN. **The dominant real-world blocker: 9/10 Phase-0 patches hit private app members.** Highest-return capability work available |
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
