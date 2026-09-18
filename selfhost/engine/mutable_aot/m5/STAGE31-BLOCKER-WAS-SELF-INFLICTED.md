# STAGE31 — REALAPP_MAOT_SELECTION_PRECOMPILER was my own diagnostic

Fork `66d33eb23bf` (clean), stamped.

## 1. Result

**The blocker is not a product defect. I caused it.**

```
ARM A control (normal selection, install OFF)
  snapshot rc=0   7.6 MB

ARM B MAOT_SELECT_ALL_NON_SDK=1, install ON
  snapshot rc=0   32.3 MB
  selected=5098  eligible=4771  refused=327
  installed=5098  distinct=5098          (no identity collapse)
  PINNED_TRAVERSAL bodies=4473 visited_once=4473 never_visited=0
                   multiply_visited=0 unbound_entries=0
                   non_leaf_bodies=4134  verdict=PASS
```

## 2. The cause

The destination-provenance block I added to `CodeRelocator::ScanCallTargets`
during STAGE20 ran **unconditionally**. Only the `MaotRelocTrace` calls inside
it were flag-checked; the work around them was not.

That block calls `MaotRegistry::ClassifyCodePointer`, which walks the **entire
registry for every call target**, calling `FieldAt`, `HasCode`, `CurrentCode`
and `id.ToCString()` — the last of which copies string characters. On the m5
fixtures the registry holds 4-5 entries and this is invisible. Under
`MAOT_SELECT_ALL_NON_SDK` it is a 5098-entry walk with allocation, per call
target, inside the relocation loop.

Gating the block behind `--maot_trace_serializer` removes the crash in both
builds.

That also explains the two facts that made the defect look exotic:

* **ASCII-looking fault addresses** — `ToCString` copies of declaration-id
  strings were in play, not a String being dereferenced as a pointer.
* **The manifestation point moving between builds** — a diagnostic with that
  cost and allocation profile perturbs layout differently under LTO and ASan.

## 3. Cost of the mistake

Four PM rounds, a dedicated ASan build, and three refuted hypotheses
(target-slot shape, kind/offset shape, caller Code validity) were spent on a
defect I introduced. Each refutation was correct and each narrowed the search,
but the search itself was of my own artifact.

**What would have caught it sooner:** the very first question asked of any
diagnostic should be whether it runs when not requested. I checked what the
instrumentation *printed* and never checked what it *executed*. The STAGE29
lesson — a trace's last line reports where instrumentation stops — had the same
root and I did not generalise it.

## 4. Does this invalidate established results?

**No, and the reason is specific rather than reassuring.** The block is
read-only: pointer comparisons and string formatting, no mutation of Code,
cells, or registry state. It cannot change routing identities or replacement
semantics. The #69 fixtures carry 4-5 registry entries, so its cost there is
negligible.

What it **does** contaminate is **timing**. Every snapshot duration recorded
before this fix included this overhead, including the STAGE27 scale ladder
(~1.5s per rung at 512 declarations) and the real-app numbers. Those are not
clean performance measurements and should not be reused as a baseline.

## 5. Remaining open items, unchanged by this

* **Runtime gate still inconclusive.** `shorebird_cli` exits with
  `Could not read .../flutter.version` because it wants its install tree. A
  second, runnable subject is still needed for the runtime half.
* **installed (5098) vs eligible (4771)** is the normal state, not a
  violation: every selected declaration gets a trampoline, while *eligible*
  counts those that can additionally accept a replacement. The harness printed
  this as "MISMATCH", which would have manufactured a stop condition; that
  label is fixed.
* **The 625 gap** between installed (5098) and pinned bodies (4473) remains
  unexplained and still open.
