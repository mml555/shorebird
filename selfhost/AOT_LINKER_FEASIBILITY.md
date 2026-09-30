# Sizing the pinned-layout work by reading the Dart SDK

**Measured 2026-07-31**, against `src/dart-sdk` on the build box — **Dart 3.12.2**
(released 2026-06-09), the revision Shorebird vends. All line numbers below are
from that checkout.

## Why this instead of the binary diff

[`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md) Phase 3 asked for a
version-matched symbol diff of our own `gen_snapshot` against Shorebird's. That
is still blocked, and structurally so: **the fork's linker machinery ships only
in the macOS/iOS toolchain** — Shorebird's `linux-x64/gen_snapshot` is stripped
and contains no `shorebird` strings at all. A Linux-vs-Linux diff therefore
cannot measure the fork, and a matched vanilla *macOS* build needs storage we do
not have yet.

The binary diff would have answered *what symbols the fork adds*. The question
Phase 5 actually turns on is narrower and answerable from source today:

> For each of the four identifier spaces the fork's flags name — class table,
> dispatch table, field table, object pool — is the identifier assigned in **one
> place that can be seeded from a base snapshot**, or scattered across the
> compiler?

Diffuse assignment means months. Localized assignment with an existing
"place it at index N" entry point means weeks. That is the whole question.

## What the flags map onto

The six fork-private options, confirmed twice by version-matched diff, are
`--base_{ct,dt,ft,op}_link_data` and `--patch_{ct,op}_link_data`. Read against
the SDK, the abbreviations are unambiguous: **ct** = class table, **dt** =
dispatch table, **ft** = field table, **op** = object pool. `--base_*` reads the
base snapshot's assignments; `--patch_*` writes the patch's own, so a later patch
can pin against it. There is no `--patch_dt_link_data` or `--patch_ft_link_data`,
which is consistent — a patch consumes those two and never needs to re-emit them.

## The four spaces, measured

| Space | Where the identifier is assigned | Existing "place at chosen index" entry point | Cross-build identity key |
|---|---|---|---|
| **Class table** (`ct`) | `ClassTable::Register`, `runtime/vm/class_table.cc:65` — `classes_.AddRow()` appends | **Yes.** `Register` already honors a pre-set id: `cls.id() != kIllegalCid ? cls.id() : classes_.AddRow(...)`. Plus `AllocateIndex(index, did_grow)` (`class_table.h:176`) and `SetAt(index, cls)` (`:376`) | Library URI + class name — stable, modulo obfuscation |
| **Field table** (`ft`) | `FieldTable::Register`, `runtime/vm/field_table.cc:55` | **Yes, and it is already in the signature:** `Register(const Field&, intptr_t expected_field_id)`, with `ASSERT(expected_field_id == -1 \|\| expected_field_id == top_)` at `:69` | Owner class + field name |
| **Dispatch table** (`dt`) | Greedy interval packer, `runtime/vm/compiler/aot/dispatch_table_generator.cc:267-277` | **Yes.** `AllocateAt(int32_t offset)` (`:125`) forces a row to an offset; `TryFit` (`:149`) and `UpdateFreeSlots` (`:162`) maintain occupancy, so pinned rows can be marked taken before new ones pack into the gaps | Selector = `(class, Name, getter?)` — see below |
| **Object pool** (`op`) | `ObjectPoolBuilder::AddObject`, `runtime/vm/compiler/assembler/assembler_base.cc:705`; index is append order | **Partial.** A parent-pool layering already exists: `parent_`, `used_from_parent_`, `base_index_`, `TryCommitToParent()`, and an `EntryAt()` that resolves low indices into the parent (`object_pool_builder.h:236-300`) | **This is the hard one** — see below |

Three of four already have the entry point. That is the headline: the pinning
work is **localized, not diffuse**.

## The dispatch table is the interesting one, and it is tractable

Offsets are not names or hashes — they come from a **greedy bin-packing
allocator** over cid intervals, with rows sorted by size (`:201`) and class depth
(`:251`). So adding one dynamically-called method, or shifting one cid, can
reshuffle many offsets. That is exactly why the base's offsets must be pinned
rather than recomputed.

`AllocateAt` makes that mechanical. The subtler part is *what to key the pinned
offsets by*, and here the SDK is more helpful than expected:
`TableSelector` (`dispatch_table_generator.h:25`) is keyed by an `int32 id`, and
that id does **not** originate in C++ —
`kInvalidSelectorId = kernel::ProcedureAttributesMetadata::kInvalidSelectorId`
(`:67`) means selector ids come from **kernel metadata written by the front end**.

The assigning pass is Dart, and small: `pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart`,
**156 lines**. Ids are handed out by `metadata.addSelector()` (`:122`) keyed by
`(Class, Name, getter)` through a union-find that merges overriding members into
one selector. `Name` is stable across builds. So pinning selector ids is: for
each `(class, name, getter)` group present in the base, reuse the base's id;
otherwise allocate. A local change to a 156-line Dart file plus a persisted map —
not compiler surgery.

## The object pool is the real risk

Every other space has a stable, nameable key. The object pool does not. Entries
are arbitrary objects, deduplicated by `IsSameObject(a, b)` on the entry and its
`equivalence_` (`object_pool_builder.h:171-172`) through a
`DirectChainedHashMap<ObjIndexPair>`. In one process that is pointer identity. To
pin across two builds days apart, "the same object" needs a **structural key** —
for a `Function` or `Class` a canonical name works, but the pool also holds
immediates, strings, type arguments, stubs and code objects.

This is where the estimate genuinely lives. It is also consistent with the object
pool being one of only two spaces that gets a `--patch_op_link_data` as well as a
`--base_op_link_data`: the patch has to hand its own pool assignments forward,
because they cannot be re-derived.

## Upstream already does the *hard half* of this — in-process

Worth knowing before writing anything: deferred loading units already require
cross-snapshot identifier consistency, and the serializer supports it.

- `LoadingUnitSerializationData` (`runtime/vm/app_snapshot.h:42`) retains a unit's
  ordered `objects()` array — the ref-id → object mapping.
- `Serializer::InCurrentLoadingUnitOrRoot` (`app_snapshot.cc:8136`) gates whether
  an object belongs to this unit or is referenced from elsewhere;
  `RecordDeferredCode` (`:8147`) defers rather than emits.
- Call sites at `app_snapshot.cc:2638, 2652, 2711, 2967, 2985` show code, object
  pools and source maps all already tolerating "lives in another unit".

**The gap is persistence, not concept.** `objects()` is a Zone array, so all units
are serialized in one `gen_snapshot` process. Base→patch spans separate builds, so
the mapping must be written to disk and reloaded — which is precisely what
`--base_*_link_data` does, and confirms our reading of the flags.

Confirmed by absence: `link_data`, `base_snapshot` and `reused_instructions` match
**nothing** in `runtime/vm/flag_list.h` or `runtime/bin/gen_snapshot.cc`. Upstream
persists no snapshot identifier data. The fork's additions are genuinely additions.

The precedent for the file format is already in-tree, though:
`--save_obfuscation_map` (`gen_snapshot.cc:117`, written at `:738-744`) writes a
compile-time table to disk. Same shape, and we will need it anyway — under
obfuscation, every name-based key above depends on the base's obfuscation map.

## What this changes about the estimate

The plan's Phase 5 estimate was "**weeks** for the host side, **months** for the
pinned-layout VM work". This measurement supports keeping that range but sharpens
where the months are:

- **Class table, field table, selector ids** — the entry points exist and the keys
  are names. Small, and mostly plumbing plus a file format.
- **Dispatch table packing** — mechanically supported by `AllocateAt`; the work is
  correctness under a partially-occupied table.
- **Object pool** — the structural-key problem is the one item that can still eat
  months. **Scope this first**, because it dominates the estimate.
- **Serializer/deserializer** — follow the loading-unit path rather than inventing
  one; it already carries "reference an object in another unit" end to end.

## What this does *not* establish

This is a source read, not a build. It establishes that the pinning work has
localized entry points and a viable design; it does **not** prove a patch snapshot
links or runs. The gate in Phase 5 is unchanged: a patch changes behavior on a
physical iPhone running our engine, reports a sane link percentage, and rolls back
cleanly.

It also does not replace the binary diff as an enumeration of the fork's symbols —
that remains blocked on a macOS build, and stays worth doing when storage allows,
now as a cross-check on this design rather than as the primary sizing instrument.
