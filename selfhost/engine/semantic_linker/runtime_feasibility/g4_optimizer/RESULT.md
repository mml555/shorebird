<!-- cspell:words dartaotruntime objdump devirtualized devirtualization dill semantic linker dedup -->
# SL1-G4 — optimizer adversity and the required fence

**Gate:** [#41](https://github.com/mml555/shorebird/issues/41) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Run:** 2026-09-06 · **Verdict: 5/5 sound under the designed contract. 5/5 bypassed when it is withheld. One fence, named exactly.**

Transcripts and banked disassembly: [`evidence/`](evidence).
Nothing was fixed here. The bypass is reproduced and left in place.

## The fence, stated narrowly

    ASSUMPTION      class-hierarchy-analysis devirtualization. When the closed
                    world contains exactly ONE implementation of a method, the
                    precompiler binds every call site directly to it -- and, at
                    a field receiver with inlining permitted, inlines the body
                    outright so no call remains at all.

    NARROWEST FENCE `dyn-module:can-be-overridden` on the overridden MEMBER
                    (di.yaml `can-be-overridden:`), which is what keeps the
                    dispatch point open.

    NOT SUFFICIENT  `extendable` on the class and `callable` on the member. The
                    bypassed arms carried BOTH and still devirtualized, so the
                    implicit-overridability path in
                    dynamic_interface_annotator.dart does not cover this.

## Six arms, because four of them could not answer the question

The first comparison — two host implementations, contract present vs absent —
came back identical, 5/5 sound both ways. That is not a fence result: with
`Base.execute` and `HostChild.execute` both reachable, the compiler must emit a
dispatch call whatever the contract says, so the arm measured the **hierarchy**,
not the contract. The solo arms exist to remove that confound.

| arm | host impls | `Base.execute` | contract | runtime | compiler form |
|---|---|---|---|---|---|
| `fenced` | 2 | never-inline | present | 5/5 sound | all DISPATCH_TABLE |
| `unfenced` | 2 | never-inline | **absent** | 5/5 sound | all DISPATCH_TABLE |
| `solo_fenced` | 1 | never-inline | present | 5/5 sound | all DISPATCH_TABLE |
| `solo_unfenced` | 1 | never-inline | **absent** | **5/5 BYPASS** | devirtualized |
| `soloinl_fenced` | 1 | inlinable | present | 5/5 sound | all DISPATCH_TABLE |
| `soloinl_unfenced` | 1 | inlinable | **absent** | **5/5 BYPASS** | devirtualized + one fully inlined |

The `di_applied_*.json` dumps confirm the arms really differ: `can-be-overridden`
is `[]` in every unfenced arm and carries the member in every fenced one, with
`extendable`, `can-be-used-as-type` and `callable` identical across all six.

## Per shape

Runtime truth is the execution-mode oracle plus the observed target; compiler
truth is `llvm-objdump` of the **same `host.aot` the run executed** — the frozen
product `gen_snapshot` cannot print flow graphs or disassembly (those flags are
`R()` in `flag_list.h` and this is a PRODUCT build), so rather than reason from a
different compiler's report this reads the bytes.

    CALL SITE: 1 ordinary virtual receiver          s1_virtual(Base)
      compiler form   fenced: DISPATCH_TABLE   unfenced(solo): DIRECT_CALL_DEVIRTUALIZED
      optimization    CHA devirtualization on a single-implementation hierarchy
      expected target PATCH-CHILD
      observed target fenced PATCH-CHILD | solo_unfenced AOT-BASE
      execution mode  fenced PatchChild.execute -> INTERPRETED
      BYPASS          NO (fenced) / YES (unfenced, solo)

    CALL SITE: 2 hot / monomorphic receiver         s2_monomorphic(Base)
      compiler form   fenced: DISPATCH_TABLE   solo_unfenced: DEDUPED_INTO_s1_virtual
                      soloinl_unfenced: DIRECT_CALL_DEVIRTUALIZED
      optimization    same CHA devirtualization; the identical bodies were then
                      merged by dedup_instructions, which is why this shape
                      reports as deduped rather than as its own call form
      observed target fenced PATCH-CHILD | solo_unfenced AOT-BASE
      execution mode  fenced PatchChild.execute -> INTERPRETED
      BYPASS          NO / YES
      note            200,000 warm calls with the host subtype changed nothing,
                      as expected: AOT has no runtime feedback. The monomorphism
                      that matters here is the compiler's, not the profile's.

    CALL SITE: 3 helper chain  a(h) -> b(h) -> h.execute()
      compiler form   fenced: DISPATCH_TABLE in s3_chain_a, s3_chain_b absent
                      (inlined into it)   solo_unfenced: DEDUPED_INTO_s1_virtual
      optimization    inlining of the helper, then CHA devirtualization
      observed target fenced PATCH-CHILD | solo_unfenced AOT-BASE
      BYPASS          NO / YES
      note            the FIRST run of this shape did not inline at all --
                      s3_chain_a was a plain `bl <s3_chain_b>` and the virtual
                      call simply happened one frame down. Sound, but not the
                      shape #41 asks for, so `vm:prefer-inline` was added to
                      raise the pressure. That makes the case harder, not easier.

    CALL SITE: 4 bounded generic receiver           s4_generic<T extends Base>(T)
      compiler form   fenced: DISPATCH_TABLE   solo_unfenced: DEDUPED_INTO_s1_virtual
                      soloinl_unfenced: DIRECT_CALL_DEVIRTUALIZED
      observed target fenced PATCH-CHILD | solo_unfenced AOT-BASE
      BYPASS          NO / YES

    CALL SITE: 5 receiver stored in an AOT field    s5_fieldCall()
      compiler form   fenced: DISPATCH_TABLE   solo_unfenced: DIRECT_CALL_DEVIRTUALIZED
                      soloinl_unfenced: NO_CALL_INLINED
      optimization    CHA devirtualization, and with inlining permitted the body
                      is inlined outright -- the strongest bypass form observed,
                      leaving no call instruction at all
      observed target fenced PATCH-CHILD | solo_unfenced AOT-BASE
      BYPASS          NO / YES

## A devirtualized host implementation cannot masquerade as success

Required by #41 and it matters: every bypassed arm returned `AOT-BASE` from a
host implementation while the run otherwise looked healthy — module loaded, no
error, exit 0. Output alone would have read as a pass. What separates them is
the observed target compared against the expected one, and the disassembly
showing there is no dispatch-table load at that site.

## Classification notes

Two states were added after reading the bytes rather than assumed in advance:

- `DEDUPED_INTO_<sym>` — several shapes compiled to identical code and were
  merged (`dedup_instructions` is on in this build). Not a verdict of its own;
  the merged target's form is this shape's form, and it is named instead of
  swallowed into "unclassified".
- Stub branches (`bl <stub …>`) are excluded from the "has a call" test. Counting
  them made every fully-inlined shape read as UNCLASSIFIED, which would have hidden
  the strongest bypass in the set.

## What this does NOT say

- The fence is an **existing** mechanism that works. Nothing here argues for a
  compiler change; the obligation it identifies is on the release-time contract
  generator, which must emit `can-be-overridden` for every patchable member. On
  #41's rubric that reads closer to a patchability-contract requirement than to
  `MODIFY_COMPILER_FENCES` — the PM's call, not mine.
- No fence was added and nothing was re-run until green. The bypassed arms stay
  bypassed in the evidence.
- Host macOS/arm64, ordinary valid dispatch. No iOS, no device, no real
  application, and no linker or binder work.
- G5 (#42) is **not** triggered. The frozen compiler can express and preserve
  the required behaviour; withholding the contract is what loses it. That is a
  fenceable policy, not a lineage limitation.

## Routing

Runtime healthy, bypass identified, fence named narrowly enough to feed
`AOT-ASSUMPTIONS-1`. Recommend proceeding, with the contract obligation recorded
as the deliverable this gate produces.
