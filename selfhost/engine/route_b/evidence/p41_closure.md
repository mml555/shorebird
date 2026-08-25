# P4.1 — closed

`probes/p41_producer_end_to_end.sh`, 2026-08-25, 10/10. Everything before this
proved the instrument; this proves the product.

## The arms

The CLI's own coverage analyzer, its own `cellSurvivalOracle` running the cell's
real `route_b_release_probe.aot`, and `RouteBProducer.produce` making the
decision. One declared deviation, identical to `cli_lower.dart`'s: `--platform`
is redirected to the VM dill and `--target flutter` dropped, because the release
under test is a plain `dartaotruntime` program.

| patched target | gate | result |
|---|---|---|
| `foldOpaque` | on | PUBLISHED |
| `deadBranch` | on | **PUBLISHED** — permanent control: a surviving call site that never executes |
| `foldConst` | on | REFUSED, naming the release as the cause and the remediation |
| `foldConst` | **off** | PUBLISHED — the mutation: the gate is what refused |
| `foldOpaque`, profile bound to another artifact | on | REFUSED as UNKNOWN, explicitly not absence |

The fourth row is the load-bearing one. The same patch, the same release, the
same analyzer: with the gate removed it publishes, with the gate on it is
refused. Without that row the third row proves only that *something* refused.

## What a user sees

```
probe    : …#foldConst -> ZERO_QUALIFYING_CALLSITES (noSurvivingCallsite)
           {target_function_nodes: 1, caller_owned_pools: 0, tearoff_pools: 0,
            self_owned_pools: 0, unowned_pools: 0, other_referrers: 4}

the release contains no surviving call site for it, so a patch would attach and
change nothing.

The target IS present in the release, and every invocation of it was compiled
away — constant-folded, or inlined and then folded. This is a fact about the
release, not about the patch: cutting the patch differently will not help, and
neither will retrying. The remediation is a new release in which the target is
actually called
```

The binding-mismatch arm says something deliberately different — "could not be
established … NOT a finding that the call site is absent" — and the end-to-end
probe asserts that the absence wording does **not** appear there. Two refusals
that read as each other would send an operator to cut a pointless release over
a broken instrument.

## Two harness bugs worth recording

1. **`$HERE` and `$RB` after the self-snapshot re-exec.** The re-exec guard
   protects against editing a running script, but `BASH_SOURCE` then points at
   the snapshot in `/var/folders`, so paths derived from it resolve beside the
   snapshot. Every arm failed with an empty verdict. Both are inherited now.
2. **A check that could not fail.** ARM 5 compared `grep -c …` to itself and
   printed PASS twice. It certified nothing. Rewritten as a `-ge 1` presence
   test — the same class of defect the anti-vacuity discipline exists for, found
   in the probe written to enforce it.

And one product bug the harness surfaced: scoping `loggerRef` without
`shorebirdEnvRef` crashes on the SUCCESS path only, which reads exactly like the
gate refusing when it had not.

## What is now true end to end

- The release asks `gen_snapshot` for a snapshot profile beside
  `--patchable_static_calls`, and writes `route_b_profile_binding.json` carrying
  the probe revision, the cell id, and the sha256 of the App binary the profile
  describes — computed after the build, from the bytes that shipped.
- Both travel in the supplement with their hashes in `artifacts`, so neither can
  be swapped between release and patch.
- The patcher computes the artifact digest from the downloaded bytes and asks
  the cell's probe. A release that uploaded neither sidecar gets an oracle that
  answers `RELEASE_EVIDENCE_ABSENT` → UNKNOWN → refuse.
- The producer refuses on `NO_SURVIVING_CALLSITE` and on UNKNOWN, with distinct
  messages, before any source is generated.

## The one consequence to decide, not to discover

**A release cut before this evidence existed cannot be patched.** It uploaded no
profile, so the question cannot be answered, and an unanswered prerequisite is
not a satisfied one. That is the literal reading of the invariant — if the
system publishes a patch, every mechanically knowable prerequisite has already
been proven against the exact release artifact — and it is implemented that way
rather than softened quietly. Softening it is a product decision.

Also outstanding: the probe is the cell's **eighth** file and is REQUIRED, so
the currently published cell resolves as INVALID until a new cell is minted.
That is deliberate (an absent gate is indistinguishable from a gate that
passed), and the mint is a separate, user-gated step.
