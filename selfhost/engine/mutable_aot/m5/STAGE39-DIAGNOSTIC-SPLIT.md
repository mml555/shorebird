# STAGE39 — diagnostics out of the production data model

Fork `1e751597116` (clean), stamped.
Same A/B subject and flags as Stage 37/38, so the delta is directly comparable.

## 1. The change, and why no production sink was kept

The reader audit reduced further than the ruling anticipated:

| consumer | reads | production? |
|---|---|---|
| `StageReplacement` | `kEscapeCount`, a **Smi** on the descriptor projected by `NoteEscapeById` | yes |
| `BlockingRecordsFor` | id, class, disposition — only caller is `DumpToFile` | no |
| `DumpToFile` | all six slots | no |

**No production path reads the decision log at all.** So there is no minimum
production subset to preserve: the whole log moves.

It is now process-owned C++ memory (`MallocGrowableArray<MaotDecisionRecord>`
behind a mutex), not a `GrowableObjectArray` on the `ObjectStore`. It cannot
be reached from a snapshot root and cannot be traced by the serializer — by
construction, not by policy. `NoteEscapeById` runs first and is untouched, so
fail-closed behaviour is structurally independent of the log.

## 2. Result

| arm | total MB | .text MB | .rodata MB | selected | decisions |
|---|---|---|---|---|---|
| A baseline | 13.42 | 5.79 | 3.81 | 0 | 0 |
| B selection ON | **13.99** | 5.79 | 4.38 | 1,598 | **19,721** |

```
STAGE38 selection-only delta   +9.10 MB   (+67.9%)
STAGE39 selection-only delta   +0.57 MB   (+4.3%)
```

Object deltas, against Stage 38's:

| object | STAGE38 | STAGE39 |
|---|---|---|
| (RO) String bytes | +8.53 MB | **+0.42 MB** |
| (RO) String count | +83,800 | **+4,159** |
| CanonicalString bytes | +0.08 MB | +0.00 MB |
| Array bytes | +0.47 MB | +0.13 MB |
| .text | +0.00 MB | +0.00 MB |

## 3. Hard invariants

**No diagnostic prose in the snapshot.** Three representative reason strings,
searched as raw bytes in the produced ELF: **0 occurrences each, 0 total**.

**Evidence remains complete.** 19,721 decision records still produced with
diagnostics fully enabled and the dump unchanged in shape. This is the
distinction the ruling asked for — diagnostics ON, diagnostics not serialized —
not the earlier "disabled diagnostics do no work" gate.

**Production behaviour unchanged.** The recorded gate fixture passes 6/6 rows
at 53 checks each, including `installable=True`, `optimizer_escapes=0`,
`blocking_records=<none>` at every stage, and OLD -> NEW -> NEW2 replacement.

## 4. An eligibility number that needed explaining

Arm B reports `eligible=723` of 1,598, which looks alarming next to Stage 34's
1,780. It is **not** caused by this change:

```
arm B  875 refusals: 821 "static call emitted without the dispatch-cell
                          indirection (--maot_disable_call_indirection)"
                      54 "the inliner took this declaration as a callee"
arm D 1110 refusals: all the same call-indirection flag
```

Both are the falsification-control flags this size matrix sets deliberately in
every arm. They exist to manufacture those escapes, and the refusals are
fail-closed working correctly. Stage 34 measured a configuration without them.

## 5. Questions the ruling deferred, now answered by the fix

* **83,800 distinct canonical strings** — gone. The string count delta drops to
  +4,159, so they were the decision prose, as suspected.
* **The unexplained `FÑ` / +0.63 MB** — gone with them. It lived in the
  population that should never have been serialized.

## 6. Residual

The remaining +0.57 MB is +4,159 strings (0.42 MB) and +1,599 arrays
(0.13 MB) against 1,598 selected declarations — approximately one array per
declaration, consistent with the dispatch cells, plus declaration-identity
strings. That is ~357 bytes per selected declaration of genuine production
metadata.

At **+4.3%** this is inside the <=15% production-candidate band, so per the
ruling the residual is not investigated further here.

## 7. Status

```
Diagnostic/production separation     ESTABLISHED
Selection-only size delta            +0.57 MB / +4.3%  (was +9.10 MB / +67.9%)
Diagnostic prose in snapshot         0 occurrences
Evidence records produced            19,721, diagnostics ON
Production behaviour                 unchanged, 6/6 gate rows
Next                                 reachability-only release edge
```
