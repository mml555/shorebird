<!-- cspell:words MAOT precompiler dartaotruntime dlsym rdynamic canonicalize -->

# MAOT-3 (#67) — measured findings

Authorized after #66 was independently accepted at Shorebird
`cdbeb05f03a0c4bca2ebd71e672877efc6a2fd2d` / Dart fork
`a6d5fe956214c480c29b0b6e6edfd92a3d1df124`.

## The mechanism

```
release direct/static call site
  -> LoadUniqueObject  the descriptor's dispatch cell   (object pool)
  -> load element 0    the current implementation Function
  -> blr [fn + Function::entry_point_]
```

The cell is a field of the #66 descriptor (`kDispatchCell`). The **only**
thing that writes it is the #66 commit path, so installing a replacement is a
descriptor state change. Nothing rewrites machine bytes, and nothing touches
`Function::entry_point_` of either the old or the new implementation — which
is what separates this from the Route B attach semantics already in this fork.

The cell reference is placed in the object pool at compile time, from the
Function the Kernel metadata bound. It is never re-found at run time.

## First end-to-end result

One process, no restart:

```
top.before=OLD              top.version.before=1      (AOT v1)
install.top=0
top.after=NEW               top.version.after=-102    (PATCH_CODE v2)
static.after=OLD-STATIC     untouched.after=UNTOUCHED
```

The static and untouched declarations are unchanged by a top-level install,
which is the scoping requirement.

## Three defects found getting here

### 1. A scoped handle in the object pool

`Array::Handle(zone(), ...)` looks equivalent to `Array::ZoneHandle(zone(),
...)` and is not. The object pool builder stores a **pointer** to the handle
and dereferences it later, when the pool is serialized; a scoped handle dies
with the enclosing `HANDLESCOPE`, and the pool is left holding a dangling
pointer. It surfaced as a segmentation fault inside `LoadObject`, nowhere near
the mistake.

### 2. `LoadObject` canonicalize-hashes an `Array`

Fixing the handle did not fix the crash. The non-patchable pool path dedups
through `ObjIndexPair::Hash` → `ObjectHash`, which sends any `Instance` to
`Instance::CanonicalizeHash` — and an `Array` is an `Instance`. Hashing a cell
whose element is a VM `Function` walks it as if it were a Dart value.

`LoadUniqueObject` uses `kPatchable`, and `AddObject` does not insert
patchable entries into the dedup table, so the hash is never computed. It is
also the right meaning: each declaration's cell is a distinct identity that
must never be merged with another's.

### 3. An exported symbol that was compiled, linked, and invisible

The harness installs a replacement between two calls inside one process, over
`dart:ffi` and `DynamicLibrary.process()`. Two things were needed, and the
first without the second is silent:

* the name must match `runtime/bin/BUILD.gn`'s `export_api_symbols` config,
  which on macOS exports exactly `-Wl,_Dart_*`;
* the definition needs `__attribute__((used))`, because nothing inside the
  binary references it and the linker dead-strips it before the export list is
  applied.

`nm -g` on the object file showed all three symbols; `nm -g` on the binary
showed none. Route B's `Dart_RouteBActivatePatchTraced` had already solved
this, and the fix was to read how rather than to change the build.

## Chosen replacement representation

For #67 the replacement implementation is **another AOT-compiled Dart
implementation present in the release image**, selected by descriptor.
Delivering an externally-built body is #72/#77; this milestone proves a
precompiled caller selects the descriptor's current implementation, not that a
body can be shipped.

## #67 reintroduced a #66 defect, and #66's gate caught it

Re-running the #66 gate against the #67 fork failed every m2 fixture snapshot:

```
app_snapshot.cc: 2787: error: expected: !FLAG_precompiled_mode
```

`kReleaseCode` is captured at materialization, which runs *before*
`ProgramVisitor::Dedup`, so it can hold a `Code` that Dedup later merges away
— and two `Code` objects with identical `Instructions` reachable at once is
exactly what the serializer refuses. It is the same defect #66 fixed for
`kCurrentCode`, reintroduced through a new field.

`RepinMutableAotImplementations` now re-pins both.

Nothing in #67's own lane would have noticed: its fixture has no two bodies
that dedup merges. The regression run is what caught it, which is what the
regression run is for.

## The hold repair: hardening the proof, not the mechanism

Independent review accepted the mechanism and held the milestone. Seven of the
eight items were about the evidence disagreeing with itself.

### The verdict was one claim doing two jobs

`direct_static_replacement = ESTABLISHED` was simultaneously "the mechanism
works" and "the issue may close" — while `FINDINGS.md` said an acceptance item
was unmet and the record said `findings: []`. A record that disagrees with its
own prose is worse than one that reports a failure.

There are now two:

| verdict | what it means |
|---|---|
| `arm64_aot_direct_static_vertical_slice` | the mechanism, on this architecture, for this call form |
| `issue_67_closure` | that, **and** every acceptance item met |

An unmet item is a blocking `ACCEPTANCE_ITEM_NOT_MET` finding. It blocks
closure and deliberately does not sink the slice: the milestone is incomplete,
the mechanism is not broken.

### The performance condition was false-safe

It tested that a field was non-null. The field held a *sentence* saying the
measurement had not been taken, and there was no static-call figure at all.

The fixture now runs real loops — two million calls per arm, three samples
each, against non-selected controls marked `vm:never-inline`, because an
inlined control is not a call and would make the indirection look arbitrarily
expensive. `G16` falsifies it in both directions: a prose value fails, and so
does dropping the static arm.

Two measurement defects surfaced on the way:

* the fixture divided microseconds by two million **in integers**, so every
  arm rounded to 0 or 1 — a measurement destroyed by its own units;
* a single sample at ~1 ns/call is dominated by scheduling noise. One arm
  measured *faster than its own control*. That is a coin flip, not a speedup.

So the honest statement is recorded as such: the indirection costs **two extra
instructions per call**, and its cost is **not resolvable above noise** at this
iteration count. `overhead_is_within_noise` is in the record. A resolvable
figure needs a quieter harness, which belongs with #68.

### Build provenance was weaker than #66's

The m3 gate named the Dart commit but did not bind the binaries to those exact
source bytes. It now uses the same content digest #66 learned it needed —
mtimes are useless on a shared rig, where switching branches rewrites every one
without changing a byte — and `G17` shows the guard firing against one edited
source.

Extending the digest to cover `flow_graph_compiler_arm64.cc` and `inliner.cc`
immediately made **#66** fail: its own source list did not know about #67's
lowering, which ships in the same binaries it measures. The guard was right and
#66's list was incomplete.

### Replacement identity was a spelling

The descriptor named its current implementation with a Function-name
diagnostic. #66 spent an arm proving two declarations can share one. The
install path knows the replacement's #65 DeclarationId, so the descriptor
records `current_implementation_id`, `release.implementation_id` and
`current_implementation_is_the_declaration_itself` — and the identity
condition reads those, not the diagnostic.

### The result is architecture-scoped, and says so

The lowering is in `flow_graph_compiler_arm64.cc`. No other architecture has
one. `target_arch=arm64` is in the record, in the verdict name, and in
`not_claimed`.

## Acceptance: one item not met, and it was mis-specified

`#64` rows `EB-01` (top-level function body) and `EB-02` (static method body)
remain `UNMODELED`, and the acceptance item as written was itself an overclaim.

Those rows are not "direct top-level" and "static direct". Each requires the
`direct`, `tearoff_pre`, `tearoff_post` and `dynamic` dispatch modes, across
JIT and AOT and cold and hot. #67 exercises **one** of those cells, so
promoting either row would overclaim by a wide margin.

The record therefore carries a `t0_row_linkage` that states exactly what is
covered — `direct`, AOT, cold and hot, on arm64 — what is not, and that each
row still reports `UNMODELED`. `G18` refuses a whole-row promotion.

This is not a matter of editing a row. All 104 T0 rows are `UNMODELED` because
`mechanism.py` has two backends — `none`, which refuses everything, and
`mock`, whose results are stamped `MOCK_ONLY` and can never be proof. Moving a
row requires a third, real backend, and the backend interface is
`install(fixture, pre_observations)` — the runner collects the pre-observations
*before* calling install, which a real mechanism cannot satisfy: OLD, install
and NEW all have to happen inside one process.

So the promotion needs a `maot` backend **and** a restructure of how #64's
runner collects observations for a real mechanism. That is a change to a
closed lane's gate, including the adversarial controls that keep `MOCK_ONLY`
out of proof, and it is not something to do unilaterally inside #67. The
evidence #67 produces is exactly what such a backend would report; what is
missing is the harness seam, not the result.

## What is NOT claimed

No virtual/interface/super dispatch. No universal no-bypass claim — #68 owns
the optimizer contract, and the posture here is the blunt rule that a selected
declaration is not inlined. No additions, no class-shape work, no transaction
architecture beyond what #66 exposes, no production CLI or package format.
