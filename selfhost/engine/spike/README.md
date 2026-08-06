# Spike A — object-pool cross-build identity (Route A's crux)

The question, from `AOT_LINKER_FEASIBILITY.md`: can every global-object-pool
entry be assigned a structural key that (a) is deterministic, (b) is
collision-free within a build, and (c) re-derives identically in a patch
build — so a base `key→index` map could pin the patch pool? Three of the four
link spaces (class/field/dispatch tables) already have keys and placement
entry points; the pool was "the item that can cost months".

Judged on **patch relevance**, not aggregate percentage (a single unkeyed
entry class that participates in ordinary edits kills it; irrelevant shared
infrastructure does not).

## RESULT — day 0 + delta matrix, 2026-08-05 (small program)

Rig: `out/host_release_arm64` (dart_dynamic_modules=true — Track E's config;
re-run on the shipping `_nodm` config before final judgement). Program: the
killgate binding target (`../killgate/binding/target_binding.dart`), pool
len 1511. **Zero VM edits needed for day 0**: vanilla `gen_snapshot
--disassemble --elf=/dev/null` dumps the pool (`precompiler.cc:668-671`).

| Experiment | Result |
|---|---|
| P0/P0 determinism | **Byte-identical** modulo raw addresses, two runs |
| P0/P1 — one function **body** edit (the canonical patch) | **Diff = 1 entry**: the changed string literal, **at the same index**. Zero displacement, zero renumbering. |
| P0/P2 — added function + call site | Pool +1. As a **multiset: P0 + exactly `EXTRA`** (the new literal). Pure insertion mid-pool; the tail shifts by one slot, every entry survives content-identical. |
| P0/P3 — added const string | Same shape: multiset = P0 + the new string, pure insertion. |

Ambiguity under naive text keying (P0, 1511 entries): 525 (34%) unique-text.
But the duplicate mass is **identical, interchangeable objects** — `null`
×306, canonicalized string literals (`value` ×99, `function result` ×76, …),
`LinkNativeCall`/`CallBootstrapNative` stub pairs ×104 — for which any
consistent mapping is correct. The *genuinely* ambiguous classes:

| Class | Count | Key available to a structured dump |
|---|---|---|
| `_ImmutableList len:5` (ArgumentsDescriptor) | 27 (1.8%) | decoded argdesc contents |
| `SubtypeTestCache(6, 0)` | 22 | regenerable runtime cache — a patch can take fresh ones |
| anonymous closures / `Function '<anonymous closure>'` | 19 | owner + source position |

None of these moved under P0/P1; collision rate among patch-relevant entries
for the 1-function edit: **0**.

## Reading

The pinning-pass premise holds on this program: body edits are in-place;
additive edits are pure insertions a seeded `ObjectPoolBuilder` (place
matched entries at base indices, append novel ones — the parent-pool layering
in `object_pool_builder.h` already demonstrates index-stable composition)
would absorb. The "months" risk has not yet materialized anywhere.

**Honest limits, still open before a verdict:**

1. The structured JSONL dump (`--dump_global_object_pool_to`, spike-only
   patch in the killgate convention) — needed to key argdescs/closures
   properly instead of arguing from ToCString text.
2. The same matrix on a **medium program** (async + collections + consts) —
   the small program cannot show cross-library emission-order effects.
3. A run on the `_nodm` shipping config.
4. This proves identity/mapping feasibility, **not** that a linked snapshot
   runs — same epistemic status `AOT_LINKER_FEASIBILITY.md` assigns itself.

## Context: Spike B already passed

Route B's crux (bytecode→base binding) passed decisively on 2026-08-05 — see
`../killgate/README.md` §"RESULT — run 2026-08-05 (Spike B)". Under the
plan's rubric a both-pass outcome defaults to **Route B with two vetoes**
(perf: size/frame-time on a real app; product: hot-path patching), with
Spike A's artifacts kept as Route B's link-percentage analog.
