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

## RESULT — medium program on the shipping config, 2026-08-05: **SPIKE A PASSES**

The three open items above were closed the same day:

- **Structured JSONL dump**: `0001-dump-global-object-pool.patch` (spike-only,
  killgate convention — never ship it) adds
  `gen_snapshot --dump_global_object_pool_to=<file>`, walking the FINALIZED
  pool at the same site as `FLAG_disassemble`: per entry — type, patchability,
  cid, ToCString, array elements (ArgumentsDescriptors), qualified name +
  token position (Functions/Closures), raw value (immediates).
- **Medium program**: `medium/` — async + collections + consts + closures +
  generics + enums across two libraries; pool len 1,575. Driver:
  `run_matrix.sh`; differ: `pool_diff.py` (reports exactly the five
  patch-relevance metrics).
- **Shipping config**: everything below ran on `host_release_arm64_nodm`
  (dart_dynamic_modules=false).

| Comparison | Result |
|---|---|
| P0/P0 determinism | 0 collisions, 0 moved, 0 unmatched — perfect |
| P0/P1 body edit | **0 moved indices**; delta = the edited string + two same-file anonymous closures whose token-position key component changed |
| P0/P2 added function | 269 uniquely-keyed entries change index (mid-pool insertion) but **every one key-matches**; genuinely new keys: 1 (`EXTRA-PROBE`) |
| P0/P3 added const | Same shape; genuinely new keys: **0** (reuses existing pool material; one argdesc key's multiplicity +1) |

The five criteria:
(a) **100% keyed** — 644 unique + 931 interchangeable duplicates of identical
canonical objects (any consistent mapping is correct); (b) **no unkeyed class
remains** once the dump exposes structure — the two apparent residues were
dump artifacts (`_List` vs `_ImmutableList` empty arrays distinguished by
cid; native-function entries carry the gen_snapshot process's ASLR'd
trampoline address, relocated at load, so they key by type); (c) nothing
moves under the canonical edit; (d) unmatched keys ARE the delta;
(e) **collision rate among patch-relevant entries: 0**.

One design note for the eventual pinning pass: closure keys include token
position, so an edit ABOVE a closure in the same file re-keys it. The base
entries persist (unchanged code is unaffected); a linker either matches
closures by owner+ordinal or accepts same-file closures rebinding as part of
the patch delta.

Honest limit, unchanged: this proves identity/mapping feasibility on a
1.5k-entry program, **not** that a linked snapshot runs, and not the behavior
of a full Flutter app's ~100k-entry pool — that measurement belongs to
whichever route proceeds.

> **Selected is not built.** The rubric below picks the architecture. It does
> not deliver iOS Dart code push: the call-emission mode, symbol retention,
> a versioned payload header (NOT the provisional `*.vmcode` filename),
> updater integration, the physical-device gate and the two veto measurements
> are all still ahead. See the capability statement in `selfhost/README.md`.

## Rubric applied — both spikes PASS → Route B selected as default

Spike B (binding) passed decisively — `../killgate/README.md` §Spike B.
Spike A (this file) passed on patch relevance. Per the plan's rubric, the
both-pass row selects **Route B (Track E) as the default**, on the grounds
that Spike A's pass only de-risks months of serializer/aot_tools work that
remains months, while Route B's remainder is a bounded compiler feature
(the call-emission mode, already specified with file:line pointers) plus
integration on Google-maintained machinery.

**Two vetoes stand between "default" and "committed", both owned by Route B's
first milestone:**
1. *Perf veto*: benchmark a release build with the call-emission mode +
   dynamic-interface retention on a real app — if snapshot size grows beyond
   ~10% or steady-state frame time regresses beyond budget, take Route A
   (patched code stays native there).
2. *Product veto*: if hot-path patching is a requirement, take Route A.

Spike A's artifacts (this dump flag + differ) are kept either way — they are
Route B's link-percentage analog. The `*.vmcode` filename contract remains
PROVISIONAL (bring-up only); production identifies patch payload type via
explicit metadata or a versioned header.
