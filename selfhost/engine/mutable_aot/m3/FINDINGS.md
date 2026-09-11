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

## Acceptance: one item not met

`#64` rows `EB-01` (top-level function body) and `EB-02` (static method body)
are the rows this milestone should move to `PROVEN`. They remain `UNMODELED`.

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
