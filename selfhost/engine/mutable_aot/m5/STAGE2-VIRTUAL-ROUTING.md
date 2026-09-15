# MAOT-5 (#69) — virtual routing: FAIL, and the reason is structural

## Result

A declaration reached **only** by instance dispatch gets **no trampoline at
all**, so no runtime dispatch structure can route through one.

```text
[maot] no pool entry for the cell of Function 'v':.; no trampoline
[maot] installed 0 dispatch trampolines (1 skipped)

tramp.identity = 0          <- no trampoline
virt.0         = OLD-ALPHA
virt.warm      = OLD-ALPHA
swap.1         = -2
virt.1         = OLD-ALPHA
virt.warm.1    = OLD-ALPHA
beta.v         = BETA
```

The `-2` from the diagnostic swap is a second, separate finding: the
replacement declarations (`AlphaNew::v`, `AlphaNew2::v`) are not in the
registry at all — only one entry exists. They are never called, and being
reachable only as replacements did not keep them registered here.

## Why: the trampoline depends on #67's static-call lowering

`cls:Alpha::method:v` at precompile time:

| field | value |
|---|---|
| `selected` | `True` |
| **`indirect_call_sites_emitted`** | **`0`** |
| `dispatch_cell_length` | `2` |
| `dispatch_cell_has_code` | `True` |
| `installable` | `False` |
| `optimizer_escapes` | `1` |
| escape reason | *a selected instance member is reachable through dispatch forms #68 does not model* |

The cell exists and is well-formed. What is missing is a **pool entry**:

1. `Alpha.v` is only ever called virtually, never statically.
2. #67's call-site lowering emits the dispatch-cell load for **static calls
   only**, so it never ran — `indirect_call_sites_emitted = 0`.
3. `LoadUniqueObject(cell)` in that lowering is the *only* thing that puts a
   cell into the global object pool, so this cell never entered it.
4. The trampoline generator can only **name an existing** pool entry — that
   was the fix for the pool-lifetime defect, because by generation time the
   builder is Reset and the pool sealed.
5. No entry → no trampoline → nothing for `FinalizeDispatchTable` to capture.

The virtual call therefore reaches the ordinary **release body `Code`**,
exactly as before #69, through the dispatch table. That is the answer to
"which runtime structure retains it": none retains a trampoline, because no
trampoline was ever built.

### The dependency is circular for #69's purpose

The trampoline currently requires the cell to be in the object pool, and the
cell only gets there because some **static** call site referenced it. The
declarations #69 exists to serve are precisely the ones with no static call
sites. Every earlier success — `tiny`, `constantish`, `OnlyShape::describe` —
had static call sites (m4's `Shape` has one implementor, so TFA devirtualizes
it into a static call). That is why the mechanism looked complete.

## The #68 blocker is untouched and still justified

`installable: False` with one `instance-dispatch / UNMODELED_BLOCKING`
escape. Nothing here argues for reclassifying it: the warmed virtual path
does **not** converge on a trampoline, so the blocker is doing exactly what
it was built to do. No disposition was changed.

## Proposed direction, not implemented

Put every selected declaration's cell into the global object pool **while the
builder is still live** — during seeding, independent of whether any static
call site references it — so a trampoline can name it later.

That is a small change, but it is a real design decision: it adds one pool
entry per selected declaration to every snapshot whether or not anything
loads it, and it changes what "the cell is in the pool" means from *a
consequence of #67 lowering* to *an invariant of selection*. It needs a
ruling.

## Not claimed

* No #64 cell moves. No dispatch form is proven.
* The fixture is new (`m5/lib/fixture_m5.dart`): two implementors and an
  environment-chosen receiver, so neither CHA nor TFA can pin the type and
  the call stays a genuine instance call. m4 is untouched.
* The serializer population threshold remains parked and unexplained.
