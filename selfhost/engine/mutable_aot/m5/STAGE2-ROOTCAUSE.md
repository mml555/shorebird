# MAOT-5 (#69) — root cause: every trampoline deduplicates to one

Diagnostics only. No mutation was made on the strength of this yet.

## The failing invariant

**A trampoline must be distinct per declaration. They are not — all of them
merge into a single `Code`.**

```text
installed=6   distinct=1   <-- MERGED BY DEDUP   serializes
installed=7   distinct=1   <-- MERGED BY DEDUP   crashes
installed=13  distinct=1   <-- MERGED BY DEDUP   crashes
```

Checkpoint 1 asserted the opposite: *"each trampoline references its own cell
through a distinct global-pool index, so no two trampolines share instruction
bytes and `ProgramVisitor::Dedup` has nothing to merge them with — but that is
an argument, and obligation 6 requires it be measured."* Measured, the
argument is false.

The mechanism: every trampoline is assembled against a **local**
`ObjectPoolBuilder` parented to the global one. Each adds its cell at local
index 0, and each local builder is constructed with the same
`base_index_ = parent->CurrentLength()` because the locals are not merged back
into the parent between trampolines. The encoded pool offset is therefore
identical, so the emitted instruction bytes are identical, so `Dedup` merges
them.

### This is semantically fatal independent of serialization

One `Code` shared by N declarations branches through **one** cell. Every
mutable declaration would dispatch to whichever single cell that trampoline
embeds. Even a build that serialized cleanly would be wrong, and would have
been wrong in a way no serialization test could catch.

### The 6 → 7 boundary is a symptom, not the cause

`distinct=1` at 6, 7 and 13 alike. The count threshold is downstream of a
broken object graph, so "seven trampolines" was never the real variable —
which is exactly the restraint the ruling asked me to hold.

## The four prescribed controls

| # | control | result |
|---|---|---|
| 1 | 6 installed | serializes; trace reaches `END_CODE 1610` |
| 2 | 7 installed | crash; last op `END_CODE 172` |
| 3 | `fn:recognizedish` alone | **serializes** |
| 4 | 7 installed, `recognizedish` moved off the 7th ordinal | **crash, identical `END_CODE 172`** |

Controls 3 and 4 together answer the question the ruling posed:
**`fn:recognizedish` is not uniquely responsible.** It serializes on its own,
and moving it off the boundary ordinal does not prevent the crash. The
failure is not declaration-specific.

(Control 3's `--maot_trampoline_only=fn:recognizedish` matched two
declarations, `recognizedish` and `recognizedishNew`, so it is strictly
"those two alone". It still answers the question.)

## What the serializer trace showed

Code 172 completes every field — `owner_`, `exception_handlers_`,
`pc_descriptors_`, `catch_entry_`, `inlined_id_to_function_`,
`code_source_map_` — and `END_CODE 172` is written. The crash happens before
`BEGIN_CODE 173`, so it is in `MakeDisambiguatedCodeName` /
`AutoTraceObjectName` or the pre-checks for the next Code.

The decisive observation was not the field sequence but the population:

* the crashing run contains **zero** `maot=1` lines;
* the passing run contains **one**.

Seven and six trampolines were installed. By serialization time there is at
most one distinct trampoline object, which is what sent the investigation to
distinctness rather than to another field.

## Not claimed

* No dispatch form is proven. No #64 cell moves.
* The exact serializer operation that faults is still not identified, and
  with a merged object graph it is not worth identifying yet — it is a
  symptom of the invariant above.
* No fix has been made. The obvious direction (force per-declaration
  distinctness) is a mutation and is not taken without a ruling.
