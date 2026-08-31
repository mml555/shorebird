# D-SUPER-2B.1f — narrow-v1 admission gate. PASS.

Host only. No product wiring changed; `0015` still reads the release import
kernel and is still UNSOUND AS DESIGNED. This lane proves the **rule**, not an
implementation of it.

## The rule

> A patched super site is admitted only when the RELEASE VERSION OF THE SAME
> METHOD already direct-called a target with the same semantic provenance.

Same-method, not program-wide, because that is the only version with a causal
argument for compiled code:

    release method M is compiled
      -> M contains an exact super call to T
      -> AOT had to emit code for T
      -> patched M wants T
      -> T has release AOT code

Evidence from an unrelated release method would not support that chain, and that
broader sufficiency claim is not established.

## Controls

    control                     release evidence      patched resolves      gate
    c1  existing call           672|close|Method      672|close|Method      ADMIT
        execution: WRAP:TICKER:APP-STATE
    c2  introduced, mixin       (none)                672|close|Method      REFUSE
    c3  introduced, ordinary    (none)                303|read|Method       REFUSE
    c4  evidence corrupted      9999|close|Method     672|close|Method      REFUSE
    gate mutation on c2         bypassed                                    ADMIT
        runtime: ABORT — Attempt to compile function

**c1 is the principal v1 claim** and it also demonstrates why the comparison is
on the target rather than the site: the patch wraps the call, so the SITE offset
moves 988 → 1005, while the TARGET fingerprint is unchanged. A site-offset
comparison would have refused a valid patch here — and 2B.1c-SITE showed the
same comparison silently miscompiling in the other direction.

**c3 is a deliberate false negative.** Arm D proved in 2B.1d that an introduced
ordinary-superclass call actually binds and executes. The gate refuses it anyway,
because the gate is about **evidence**, not about guessing from class shape. An
unnecessary refusal is a cost; an abort inside a user's app is not acceptable.

**c4 corrupts only the RECORDED release target**, leaving the release itself
untouched, and c1 flips ADMIT → REFUSE. So the gate compares the target's
provenance, not merely "the release method contained some `super.close`".

**The gate mutation makes it load-bearing rather than precautionary.** Bypassing
only the membership check on c2 admits the patch, and the release then reaches
`compiler.cc:1152: Attempt to compile function …__Leaf&Base&Ticker@…_close` —
the abort this gate exists to convert into a refusal.

## Fingerprint, not canonical name, not site offset

    fileUri | fileOffset | name | kind

No synthetic owner (AOT mixin deduplication renames it — 2A), no arity (TFA
rewrites it — 2B.0), no site offset (not a cross-version identity — 2B.1c-SITE).
Every exclusion is a measured one.

## What this claims, and what it does not

**Claims:** for narrow-v1, an exact-super dependency already exercised by the
release version of the same compiled method is accepted; a new exact-super
dependency is refused.

**Does not claim:** any general ability to detect whether an arbitrary function
has AOT code. There is none. The gate infers compiled code from one specific
causal chain and refuses everything outside it.

## Where the remaining work sits

The gate is proven as a rule and lives only in this harness. Still to do, in the
order the ruling fixed:

1. switch the compiler to the **patched no-AOT** import kernel (2B.1d proved the
   relationship; the wiring is unchanged);
2. implement this evidence in the product — release-side super-target
   fingerprints per method, and the membership check in the producer, failing
   closed before publication;
3. repair the TFA-symmetric E2E fixture;
4. positive shipping-producer arm;
5. source-gate mutation, which becomes valid once the compiler reads the patched
   kernel;
6. **compiled-target gate mutation**, exactly as run here but through the product
   path;
7. regressions.

`D-SUPER-BROAD-0` stays parked: E2 is NOT ESTABLISHED, not negative, and would
have to be priced on real apps rather than on E3's toy per-target number.

## Reproduce

    WORK=/tmp/f  bash super0/s2b1f/run_2b1f.sh
    CORRUPT_EVIDENCE=1 WORK=/tmp/fc bash super0/s2b1f/run_2b1f.sh
    MUTATE_GATE=1      WORK=/tmp/fm bash super0/s2b1f/run_2b1f.sh
