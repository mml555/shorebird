<!-- cspell:words prebuilts dartsdk vmcode aot upstreamable kbc -->

# Rebuilding the fork ourselves, instead of asking for access

> **Superseded 2026-07-30 by [`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md),
> which is the actual plan.** Two of the open questions below have since been
> answered by measurement, and the "ask for access in parallel" recommendation
> at the bottom is **withdrawn** — see the plan for why. This file is kept for
> the reasoning that still holds: the two candidate routes, and why route 1 was
> rejected.

Brief for whoever picks this up. The decision recorded here is **direction, not a
plan**: nothing below has been attempted.

## Why this is on the table

Everything blocked on iOS is blocked by one artifact: `pkg/aot_tools`, the
host-side AOT linker inside Shorebird's private Dart VM fork. It works out which
functions in a patch can reuse the original AOT instructions (`linkPercentage`,
typically ≥98%) and emits the `.vmcode` the VM interprets. iOS forbids JIT, so
there is no other way to execute patched Dart there.

The alternative to asking for access is building the capability ourselves.

## What is already ours, and what that tells us

Do not start from "we must reimplement their linker". Two things have changed
since that framing was written.

**We already did the analogous job once.** Their fork was assumed to be the
blocker for Android too. It turned out to be **57 lines** — vanilla Dart 3.12.2
plus two snapshot-size accessors and one public getter, reproducible from
[`engine/dart-fork/`](engine/dart-fork). Their fork exists to *interpret* patched
code, which is the iOS mechanism; Android patches carry real machine code and need
none of it. So "private fork" was a much smaller dependency than it looked, and
the same may be true again.

**Vanilla Dart now ships an interpreter that did not exist when they forked.**
`runtime/vm/interpreter.cc` (~4,600 lines) and a bytecode reader (~3,100 lines)
sit behind `DART_DYNAMIC_MODULES`, and this engine already exposes
`--dart-dynamic-modules` (`engine/src/flutter/tools/gn`) with Flutter CI builders
for it. That is a *public* substrate for JIT-less patch execution. Shorebird built
their interpreter because they had to; upstream has since grown one.

## The two candidate routes

**Route 1 — reimplement the linker.** Diff two AOT snapshots, decide which
functions are byte-identical, emit a `.vmcode` referencing the originals plus
bytecode for the rest. Months, deep VM-internals work, and permanently coupled to
Dart's snapshot format. This is the option that was considered and rejected;
nothing has changed to make it more attractive.

**Route 2 — build on `DART_DYNAMIC_MODULES`.** Ship the changed code as a dynamic
module the upstream KBC interpreter executes, instead of reproducing their
link-and-interpret pipeline. Research-grade and may not pan out, but:

- it is the only route that could be **upstreamable**, since it uses upstream's
  own mechanism rather than a parallel one;
- it would not need their fork at all, so it also answers "what if Shorebird
  disappears", which the current design only partly answers;
- Android would keep its existing machine-code path; this is purely additive for
  the platforms that forbid JIT.

Route 2 is the one worth investigating first.

## First questions to answer, cheapest first

Answer these before writing anything. Each is a read or a small experiment.

1. **Does `--dart-dynamic-modules` actually work in this engine's Dart?** Build
   the flag on and run *any* dynamic module. If that fails, everything else is
   moot.
2. **Can a dynamic module replace a function the AOT snapshot already contains?**
   Patching means overriding existing code, not just adding new code. This is the
   crux, and it is where the idea most plausibly dies.
3. ~~**Does the KBC interpreter exist in a release AOT build**, or is it compiled
   out?~~ **ANSWERED: yes.** Vanilla Flutter's `ios-release` device slice
   (`ios-arm64`, 8.8 MB) contains `DRT_ResumeInterpreter`,
   `InvokeDartCodeFromBytecode` and the `[Bytecode Stub]` table. It is not
   debug-only, and it is *upstream's* — Shorebird's and vanilla's `gen_snapshot`
   carry the same interpreter symbols at the same Dart version (3.12.2), and only
   Shorebird's carries `shorebird` strings. Caveat: the same binary also contains
   `"Loading of dynamic modules is not supported."`, so the entry point is gated
   off in stock builds. The gate is `--dart-dynamic-modules` (`tools/gn:685`),
   which is ours to flip.
4. **What does Apple's review actually permit?** Shorebird's whole design assumes
   interpreting downloaded bytecode is acceptable. Confirm the constraint before
   building to it. (Weak evidence in favor: they ship it in App Store apps today.)
5. ~~**How large is the delta they actually ship?**~~ **PARTLY ANSWERED.** A
   symbol diff of the two `gen_snapshot` binaries names the contract:
   `--base_ct_link_data`, `--patch_{ct,op}_link_data`,
   `--base_{dt,ft,op}_link_data`, plus `ClassTable::AllocateIndex` and extra
   parameters threaded into `Deserializer` and `ObjectPoolBuilder::FindObject`.
   So the fork's job is to **pin the patch snapshot's identifier layout to the
   base's** — not to interpret. A precise count needs a version-matched diff
   against a `gen_snapshot` built from our own fork tree; that is Phase 3 of the
   plan.

## What this does not require

Worth being clear, because it is easy to over-scope:

- **Not** a rebuild of the engine or framework forks. Both are public and already
  captured in [`../vendor/flutter`](../vendor). Only the Dart VM side is at issue.
- **Not** anything for Android. That path is proven end to end on our own engine,
  including engine-level patched assets (Track D in
  [`HANDOFF.md`](HANDOFF.md)).
- **Not** a prerequisite for the control plane, the CLI, crash symbolication, or
  Route A assets. All of those ship on Shorebird's prebuilt engine today, on both
  platforms.

## Read these first

- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) — the evidence that the fork is private,
  the measured size of their changes, and what it cost to reproduce the Android
  part.
- [`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) — the layer analysis, the
  Android→iOS carryover argument, and Phase 6 where the dynamic-modules idea is
  first written down.
- [`HANDOFF.md`](HANDOFF.md) — the build rig, and the traps that cost real time.
- [`engine/dart-fork/`](engine/dart-fork) — the 57-line precedent, as a worked
  example of how to reproduce a piece of their fork from vanilla.

## The honest counter-argument, and why it was withdrawn

The original argument: asking for access costs an email and converts every
"Android only" row to "both platforms" without changing any of the work, while
rebuilding costs months and might fail at question 2. So ask, and investigate
Route 2 as insurance.

**Withdrawn 2026-07-30**, for three reasons:

1. **It buys less than it looked.** iOS code push already works here on
   Shorebird's prebuilt engine — Apple patchers, `aot_tools`, their host tools,
   device-verified. The *only* thing gated behind their fork is running **our
   own modified engine** on iOS.
2. **It would undo the point.** This fork exists so that nothing we depend on can
   be withdrawn. Building iOS capability on a private, revocable artifact
   re-creates that dependency one layer down.
3. **The insurance is worth less now.** Question 3 turned out to be "the
   interpreter is upstream's and already ships to iOS devices", so the fallback
   is a scoped compiler problem rather than a bet on inventing JIT-less
   execution.

The real question is not "ask or build" but "does iOS *engine* capability matter
enough to fund the work" — which is a product decision, not a negotiation.
