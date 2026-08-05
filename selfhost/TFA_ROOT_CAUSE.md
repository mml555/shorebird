<!-- cspell:words tearoff tearoffs precompiler dartaotruntime selfhost Ddart Devirtualization bodyless closurize frontends genkernel nodm upstreamable stockfe ourfe assetprobe misparse -->

# Why the dispatch-table metadata is wrong, and what it means for the four compiler patches

**Status 2026-08-05: root cause located and reproduced. Not yet fixed.**

The four patches in `engine/0004`, `0005`, `0006` exist because the AOT compiler
trusts three fields of the dill's TFA metadata — `call_count`, `torn_off`,
`has_tearoff_uses` — and in our builds those fields do not describe reality. The
retirement criterion was:

> Explain why `call_count`, `torn_off` and `has_tearoff_uses` omit uses that are
> introduced or required downstream, then determine which compensating patches
> can safely be removed.

Both halves are answered below. The answer is not the one the earlier draft of
this document gave.

## The finding

**We are pairing Shorebird's forked `frontend_server` with our vanilla
`gen_snapshot`, and the two disagree about `vm.table-selector.metadata`.**

TFA is not under-reporting. `frontend_server` as a *mode* is not at fault
either — that was the earlier draft's error, drawn from a `gen_kernel` A/B that
changed two variables at once. Holding the mode fixed and swapping only the
frontend binary isolates it:

| frontend | `List.get:length` | `List.[]` | `Map.[]` | selectors | `call_count > 0` | `torn_off` |
|---|---|---|---|---|---|---|
| **stock** — Shorebird fork, Dart `db98bdaa` | 0 | 0 | 0 | 13641 | 1696 | 595 |
| **ours** — vanilla Dart `d684a576` + our patches | **200** | **413** | **93** | 13641 | 869 | 237 |

Identical app, identical `--sdk-root` platform dill, identical argument list
(the exact one `flutter_tools` builds for an iOS release), one-shot in both
cases — no `--incremental`, so this is not the resident compiler. Both dills
compile: 18,748,598 vs 18,787,252 bytes of assembly out of our `gen_snapshot`.

The two frontends assign **the same 13641 selectors and the same selector IDs**
(`List.get:length` is 5185 in both). Only the payload at those IDs differs.

## The divergence is semantic, not a misparse

The obvious hypothesis — Shorebird added a field, so our reader reads
misaligned — does not survive. Seven candidate binary layouts were tried against
the stock dill, scored by how many records come out with a `flags` byte greater
than 3 (only two bits are defined, so a high `flags` byte means the read is off):

| layout | `flags > 3` | implausible `call_count` |
|---|---|---|
| **A — vanilla: `uint30 cc`, `byte flags`** | **1023** | **85** |
| B — + trailing byte | 3175 | 199 |
| C — + trailing `uint30` | 3106 | 56 |
| D — `cc`, `uint30` extra, `flags` | 3107 | 375 |
| E — `uint30` extra, `cc`, `flags` | 3107 | 56 |
| F — + trailing `uint32` | 4949 | 482 |
| G — leading `uint32`, then vanilla | 4947 | 483 |

Vanilla's own layout fits best by a wide margin, and the `flags` histogram is
dominated by legal values (`0` × 12141) rather than the uniform spread a
drifting read would give. The same scan on our frontend's dill returns
`flags > 3` = **0**, implausible = **0**, three distinct flag values.

So the stock table parses in the vanilla layout and simply contains different
data:

- **85 entries** whose `call_count` cannot be a count — 654,640,129;
  1,040,450,688; 1,006,632,961. `callCount` is only ever written by
  `selector.callCount++`
  (`pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart:138,145`).
- **1023 entries** setting flag bits vanilla does not define — `0x04` on 416
  records, `0x80` on 550, and combinations; vanilla defines only
  `kCalledOnNullBit` (`0x01`) and `kTornOffBit` (`0x02`).
- **Hot core selectors left entirely empty.** `List.get:length` is `cc=0,
  flags=0` — not a hidden "used" bit under `0x04`, just zero.

Direct evidence of the fork divergence, from the stock snapshot's own symbol
table: it contains **`TableSelectorAssigner._getSelectorHash`**, which does not
exist anywhere in vanilla Dart. Shorebird's code push needs selector identity to
be stable across a release/patch pair, which is exactly the kind of change that
would repurpose these fields. Their `gen_snapshot` understands the result. Ours
does not.

## Why that produces a `NoSuchMethodError`

1. `SelectorMap::GetSelector` treats `call_count == 0` as "no row". The AOT
   compiler then leaves the call virtual with nothing in the dispatch table. Its
   own `#if defined(DEBUG)` branch states the assumption: *"Target functions were
   removed by tree shaking. This call is dead code, or the receiver is always
   null."*
2. AOT product snapshots carry no `Class::functions()`, so there is no
   name-based fallback. The call lands on the no-such-method stub. Observed as
   `NoSuchMethodError: get:length / [] on _ImmutableList` while building the map
   literal in `PlatformDispatcher._`.

Everything else in the metadata pipeline is healthy — instrumenting
`DirectCallMetadataHelper` counted **140,000 hits against 13,766 misses**, so
devirtualization is fine and the compensations are not masking a broad plumbing
failure. It is the selector table specifically.

## A second, independent defect in the same area

`TableSelectorAssigner._selectorIdForMember` (`table_selector_assigner.dart:102`)
returns **the co-named getter's selector id when asked for a setter's getter
id**. `_getterMemberIds` is keyed by Kernel `Name`, which does not distinguish
setters, so the lookup hits the getter's entry; the guarding `assert` only fires
when the name is absent entirely, which cannot happen when a same-named getter
exists.

This one is in vanilla, not the fork. Upstream is safe only because
`SelectorMap::SelectorId` never asks a setter for its getter id. Our first
attempt at `0004` did exactly that, via
`GetMethodExtractor(Field::GetterName(name))` on a setter — so the extractor for
`set:_data` was written into `get:_data`'s dispatch row, and `_table._data` then
returned a fresh `(List<dynamic>) => void` closure on every read. That is what
produced the bogus `ConcurrentModificationError`. It is why `0004` is now
restricted to `IsRegularFunction()`, and the restriction is load-bearing
independently of everything above.

## The fix is a frontend swap, not a compiler change

**We already build the frontend we need and are not using it.**
`out/host_release_arm64_nodm/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot`
is the one that produced the clean column above. Flutter takes its frontend from
`bin/cache/dart-sdk/`, populated by `bin/internal/update_dart_sdk.sh`:

```sh
DART_SDK_URL="$DART_SDK_BASE_URL/flutter_infra_release/flutter/$ENGINE_VERSION/$DART_ZIP_NAME"
```

— `update_dart_sdk.sh:131`, keyed on `$FLUTTER_STORAGE_BASE_URL` and our engine
hash. That is the same path the overlay CDN already intercepts for
`ios-release/artifacts.zip` and `flutter_patched_sdk.zip`. Publishing our own
`dart-sdk-darwin-arm64.zip` (and `dart-sdk-linux-x64.zip` for the Android rig)
under our engine hash needs no new mechanism.

Note the pairing constraint recorded earlier: `frontend_server_aot.dart.snapshot`
must ship with the `dartaotruntime` built from the same tree, or it dies with
`Wrong full snapshot version`. Publish the whole `dart-sdk` directory, not the
snapshot alone.

## What this means for the four patches

| # | Patch | Retire? |
|---|---|---|
| 1 | Never closurize an implicit accessor (`0004`) | **No — keep.** A language invariant; `object.cc:8762` asserts it. Independent of all of the above. |
| 2 | Drop the `IsUsed()` (`call_count > 0`) gate on selector rows (`0004`) | **Yes — but only together with the frontend swap.** It exists solely to survive the stock frontend's zeroed counts. |
| 3 | Extractors for regular methods only, ignoring `torn_off` / `has_tearoff_uses` (`0004` + `0005`) | **Partly.** Restore the flags, keep "regular methods only" — the latter guards the vanilla setter/getter collision above and is not about metadata quality. |
| 4 | Never dispatch-call the `_HashVMBase` graph-intrinsic slot accessors (`0006`) | **No — keep.** `external` bodyless accessors are only ever valid inlined; unrelated to any of this. Arguably upstreamable as-is. |

**Patches 2 and 3a are coupled to the frontend swap and must not be retired
before it.** Retiring them against the stock frontend re-opens the original
`NoSuchMethodError` immediately. The retirement bar is unchanged: clean rebuild
with no diagnostics in any shipped artifact, app to first frame, and an
on-device patch round-trip on both platforms.

## Next steps, in order

1. **Publish our host `dart-sdk` to the overlay** under the current engine hash,
   both `darwin-arm64` and `linux-x64`.
2. **Rebuild `gen_snapshot` with patch 2 and patch 3a reverted** and run the full
   retirement bar against a build that uses our frontend.
3. **Check what else Shorebird's frontend was providing.** The DD two-pass build
   (`App.dispatch_table.json`, `App.dt.link`, and friends in
   `.dart_tool/flutter_build/`) is fork-specific. We already disable it via
   `--dd-max-bytes=0` and our patcher does not use the AOT linker, so the
   expected impact is none — but confirm rather than assume before swapping.
4. **Decide whether `_selectorIdForMember` is worth an upstream bug report.** It
   is a real latent defect in vanilla Dart, currently unreachable there.

## Reproducing

`engine/tools/fe_ab.sh` runs both frontends over the same app with the exact
`flutter_tools` release argument list. Then:

```bash
D=<dart tree>; O=<out/host_release_arm64_nodm>
$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  engine/tools/probe_length.dart  <dill>          # per-member selector id + count
$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  engine/tools/dump_selectors.dart <dill>         # whole-table summary
$O/dart-sdk/bin/dart --packages=$D/.dart_tool/package_config.json \
  engine/tools/layout_scan.dart   <dill> A        # layout fit + alignment metrics
```

See [`engine/tools/README.md`](engine/tools/README.md).
