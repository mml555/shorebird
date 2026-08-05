<!-- cspell:words tearoff tearoffs precompiler dartaotruntime selfhost Ddart Devirtualization bodyless closurize frontends genkernel nodm upstreamable -->

# Why TFA under-reports, and what it means for the four compiler patches

**Status 2026-08-05: root cause located and reproduced. Not yet fixed.**

The four patches in `engine/0004`, `0005`, `0006` exist because the AOT compiler
trusts three fields of the dill's TFA metadata — `call_count`, `torn_off`,
`has_tearoff_uses` — and in our builds those fields do not describe reality. The
retirement criterion was:

> Explain why `call_count`, `torn_off` and `has_tearoff_uses` omit uses that are
> introduced or required downstream, then determine which compensating patches
> can safely be removed.

The first half is answered. The second half is answered conditionally, below.

## The finding

**The metadata is broken in the `frontend_server` path and correct in the
`gen_kernel` path.** Same app, same platform dill, same `--aot --tfa
--target=flutter -Ddart.vm.product=true`, same package config — only the
frontend binary differs:

| | `List.length` (getter) | `List.[]` (method) |
|---|---|---|
| `frontend_server` — what Flutter actually uses | sid 5195, **call_count 0** | sid 5196, **call_count 0** |
| `gen_kernel` — one-shot compiler | sid 5222, **call_count 200** | sid 5223, **call_count 416** |

Whole-table view of the same two dills:

| | selectors | with call_count > 0 | torn_off | implausible |
|---|---|---|---|---|
| `frontend_server` | 13675 | 1695 | 597 | **86** |
| `gen_kernel` | 13783 | 874 | 238 | 0 |

"Implausible" means a `call_count` that cannot be a count — the largest are
**1,040,450,688**, **1,040,187,906**, **1,006,632,961**. `callCount` is only
ever written by `selector.callCount++`
(`pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart:138,145`);
no run of TFA reaches a billion increments. `gen_kernel` produces none of these.

So this is not "TFA is conservative". **The counts are real but mis-associated
with selector IDs in the `frontend_server` path**, and a handful of entries hold
values that are not counts at all.

## Why that produces a `NoSuchMethodError`

The chain, all verified rather than assumed:

1. `transformer.dart:664-681` registers a selector use only when
   `selector is InterfaceSelector && !_callSiteUsesDirectCall(node)` — i.e. only
   for calls TFA modelled *and* left virtual. `_callSiteUsesDirectCall` is just
   `_directCallMetadataRepository.mapping.containsKey(node)`.
2. `Map._fromLiteral`'s body **is** analyzed — the dill shows
   `@vm.inferred-type.metadata=int` on `elements.length` and direct-call
   metadata on `map.[]=` and the integer arithmetic — and `elements.length` /
   `elements[i]` are left **virtual** (no direct-call metadata).
3. Those two sites therefore should have incremented the `length` and `[]`
   selectors. Under `gen_kernel` they do (200 / 416). Under `frontend_server`
   the counts read 0.
4. `SelectorMap::GetSelector` treats `call_count == 0` as "no row"; the AOT
   compiler then leaves the call virtual with nothing in the dispatch table. Its
   own `#if defined(DEBUG)` branch states the assumption: *"Target functions were
   removed by tree shaking. This call is dead code, or the receiver is always
   null."*
5. AOT product snapshots carry no `Class::functions()`, so there is no
   name-based fallback. The call lands on the no-such-method stub. Observed as
   `NoSuchMethodError: get:length / [] on _ImmutableList` while building the map
   literal in `PlatformDispatcher._`.

Devirtualization itself is healthy — instrumenting `DirectCallMetadataHelper`
counted **140,000 hits against 13,766 misses**, so the compensations are not
masking broken metadata plumbing generally. It is specifically the
table-selector association.

## A second, independent defect in the same area

`TableSelectorAssigner._selectorIdForMember` (`table_selector_assigner.dart:102`)
returns **the co-named getter's selector id when asked for a setter's getter
id**. `_getterMemberIds` is keyed by Kernel `Name`, which does not distinguish
setters, so the lookup hits the getter's entry; the guarding `assert` only fires
when the name is absent entirely, which cannot happen when a same-named getter
exists.

Upstream is safe only because `SelectorMap::SelectorId` never asks a setter for
its getter id. Our first attempt at `0004` did exactly that, via
`GetMethodExtractor(Field::GetterName(name))` on a setter — so the extractor for
`set:_data` was written into `get:_data`'s dispatch row, and `_table._data` then
returned a fresh `(List<dynamic>) => void` closure on every read. That is what
produced the bogus `ConcurrentModificationError`. It is why `0004` is now
restricted to `IsRegularFunction()`, and the restriction is load-bearing
independently of everything above.

## What this means for the four patches

| # | Patch | Retire when the metadata is fixed? |
|---|---|---|
| 1 | Never closurize an implicit accessor (`0004`) | **No — keep.** A language invariant; `object.cc:8762` asserts it. Independent of TFA. |
| 2 | Drop the `IsUsed()` (`call_count > 0`) gate on selector rows (`0004`) | **Yes** — this exists solely to survive zeroed counts. |
| 3 | Extractors for regular methods only, ignoring `torn_off` / `has_tearoff_uses` (`0004` + `0005`) | **Partly.** The "ignore the flags" half can go. The "regular methods only" half must stay until `_selectorIdForMember` stops returning a getter's id for a setter. |
| 4 | Never dispatch-call the `_HashVMBase` graph-intrinsic slot accessors (`0006`) | **No — keep.** `external` bodyless accessors are only ever valid inlined; unrelated to TFA. Arguably upstreamable as-is. |

So a metadata fix retires roughly **one and a half of four**, not all four. The
other two are genuine backend invariants that happened to be discovered while
chasing this.

## Next steps, in order

1. **Find where the association breaks in `frontend_server`.** The selector IDs
   are correct in both paths (`List.length` resolves to the same member and the
   VM reads the same id TFA wrote), so ID assignment is fine; it is the
   increments that land elsewhere. Note the two dills contain a *different
   number of selectors* (13675 vs 13783) for the same program, which points at
   the `TableSelectorAssigner` being constructed over a different set/ordering
   of libraries than the annotation pass later walks — the assigner assigns IDs
   eagerly in its constructor by iterating `component.libraries`.
2. **Check whether upstream Flutter is affected.** If plain `flutter build apk`
   on stock everything also yields `call_count == 0` for `length`, this is an
   upstream bug that stock tolerates only because Shorebird's fork retains far
   more (their snapshot of our dill was **44 % larger**). If upstream yields
   real counts, something in our invocation differs.
3. **Test the cheap workaround**: compile the app with `gen_kernel` instead of
   `frontend_server` and rebuild with patches 2 and 3a reverted. If it runs, the
   diagnosis is confirmed end to end and the fix may be a frontend_server
   change rather than four compiler patches.

## Reproducing

```bash
D=<dart tree>; O=<out/host_release_arm64_nodm>
# same app through both frontends
$O/dart-sdk/bin/dartaotruntime $O/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
  --platform <flutter_patched_sdk_product>/platform_strong.dill \
  --aot --tfa --target=flutter -Ddart.vm.product=true \
  --packages <app>/.dart_tool/package_config.json -o app_genkernel.dill package:<app>/main.dart
# then compare the tables
$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  scratchpad/probe_length.dart <dill>
```

`scratchpad/probe_length.dart` reads `TableSelectorMetadataRepository` and
`ProcedureAttributesMetadataRepository` out of a dill and prints, for
`dart:core` `List`/`Map`, the selector id each member was assigned and the
`call_count` sitting at that id. `dump_selectors.dart` beside it prints the
whole-table summary. Both are worth keeping.
