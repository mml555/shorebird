# STAGE38 — the +9.1 MB is a serialized diagnostic log

Fork `2569595b493` (clean), stamped.
Arms A and B from the Stage 37 matrix; call indirection and retention roots OFF
in both, so nothing but selection metadata varies.

**Returning before optimizing: one structure explains it.**

## 1. Attribution by object type

Profiled totals: A = 9.60 MB, B = 18.70 MB, delta **+9.10 MB**.

| object type | bytes A | bytes B | delta | count A | count B | cumulative |
|---|---|---|---|---|---|---|
| **(RO) String** | 1.67 | 10.20 | **+8.53** | 21,704 | 105,504 | **94%** |
| Array | 0.11 | 0.58 | +0.47 | 22,330 | 23,930 | 99% |
| CanonicalString | 0.02 | 0.11 | +0.08 | 21,702 | 105,502 | 100% |
| everything else | — | — | ~0.00 | — | — | 100% |

`(RO) Instructions` is **5.79 MB in both** and `Code`, `Function`, `ObjectPool`,
`Class` are unchanged — independently confirming Stage 37's finding that no
code or retention effect is involved.

Three categories cover 100% of the delta; strings alone cover 94%.

## 2. What the strings are

By object name, the largest contributors in B:

```
2.90 MB  "one warmed call site in this state observed successive implementation ..."
2.22 MB  "no install decision reads a slot-preserving record; it is positive evi..."
0.61 MB  "an instance call was devirtualized into a static call on TFA's direct-..."
0.56 MB  "SLOT_PRESERVING"
0.35 MB  "static call emitted without the dispatch-cell indirection (--maot_disa..."
0.31 MB  "the AOT dispatch-table slot for this declaration holds its trampoline,..."
0.26 MB  "MaotRegistry::StageReplacement refuses installation while this disposi..."
```

These are **decision-log reason strings** — the human-readable explanations this
programme records for every optimizer/dispatch decision. They are prose written
for evidence documents, and they are being serialized into production
snapshots.

## 3. Owner structure

```
MaotRegistry::NoteDecision(declaration_id, caller_id, class, decision, disposition)
        v
6-slot record appended to a GrowableObjectArray
   [0] declaration id   [1] caller id   [2] optimization class
   [3] DECISION PROSE   [4] disposition [5] consumed-by
        v
array held by the MaotRegistry
        v
registry rooted in the ObjectStore
        v
serialized into the snapshot
```

## 4. Semantic requirement — measured, not assumed

The decision array has exactly **two** readers:

| reader | slots read | production? |
|---|---|---|
| `blocking_records` builder | 0 (id), 2 (class), 4 (disposition) | **yes** — this is refusal reporting |
| `DumpToFile` | all six | no — diagnostic JSON |

**Slot 3, the prose, is read by nothing except the diagnostic dump.** The
production-relevant consumer needs only the declaration id, the optimization
class and the disposition.

By the ruling's taxonomy this is category **(2): diagnostics/debug metadata
accidentally serialized** — not required production metadata, not a redundant
representation of something needed, and not snapshot-implementation overhead.

## 5. Two things not established

* **Why 83,800 distinct canonical strings.** `CanonicalString` count rises by
  the same amount as `String`, so these are not collapsing to one shared
  constant per message. Whether that is because each carries per-declaration
  detail, or because canonicalization is not reaching them, is **not**
  determined here.
* **A 0.63 MB entry named `FÑ`** appears among the top contributors. It is not
  explained and I did not chase it; it is 7% of the string delta.

## 6. Status

```
Delta explained                    94% strings, 99% strings+arrays, 100% top three
Named structure                    MaotRegistry decision log (NoteDecision records)
Why it exists                      evidence/diagnostic record for this programme
Production consumer                blocking_records, which does NOT read the prose
Category                           (2) diagnostics accidentally serialized
Optimization                       NOT ATTEMPTED -- returning as directed
```
