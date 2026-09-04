<!-- cspell:words armv gclient prebuilt ninja depot cipd openjdk riscv ddm pathed -->

# ANDROID-CELL-SUPPLY-2 · Gates 1–2 — the lineage DOES produce the Android engines

2026-09-04. Supersedes this lane's earlier `GATE1_STATUS.md`, which stopped for
the armv7 decision. Option A was authorized; the narrow fix is made, qualified,
and all three architectures build.

    arm    configures ✓  builds ✓   (was: could not configure)
    arm64  configures ✓  builds ✓
    x64    configures ✓  builds ✓
    14/14 identity-bearing members produced from our own lineage

Nothing minted or published. `cd848320…` untouched, `@must_be_local` unchanged,
no product code changed yet.

## Provenance

| | value |
|---|---|
| engine source, **before** | `dfa2b24ac38477f3705ff0357530f33fe09474b8` |
| engine source, **Android members** | `f1a59b8a1609c51397601c36d586ad7763d57153` — parent is exactly `dfa2b24a…` |
| the change | one file, `engine/src/flutter/lib/snapshot/BUILD.gn`; banked as [`../../engine/route_b/patches/0001-gate-macos-analyze-snapshot-applicability.patch`](../../engine/route_b/patches/0001-gate-macos-analyze-snapshot-applicability.patch) |
| Dart | HEAD `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c` + 2 local modifications, `git diff` digest `6b358f71…` — **byte-identical to the tree that produced `cd848320…`** |
| DEPS identity | the original `.gclient`: Dart fork via `file://`, `download_dart_sdk: False`. Android deps added by `gclient sync`; all four CIPD packages public and pinned |
| GN args | `--android --android-cpu={arm,arm64,x64} --runtime-mode=release --no-prebuilt-dart-sdk`; `enable_lto = true`, `is_official_build = true`, `dart_version = 9e8c898a…` |
| ninja targets | `zip_archives/android-<abi>-release/{darwin-x64,artifacts,symbols}.zip`, `flutter/shell/platform/android:{embedding_jars,abi_jars}` |
| host | macOS arm64, 10 cores / 64 GB |
| location | `/Volumes/build/route-b/acs2/` — the qualified tree at `/Volumes/build/route-b/flutter` was never written to |

**`--dart-dynamic-modules` is deliberately NOT used.** With it, every archive is
re-pathed to `android-<abi>-release-`**`ddm`**`/`, while the Supply-1 closure
measured `android-<abi>-release/`. Non-ddm is the only configuration that emits
the paths the closure requires — so upstream's published release artifacts are
non-ddm builds. It is also right on the merits: Android patches are bidiff and
never interpret. `shorebird_use_interpreter` defaults to `is_ios` and is already
false on Android.

## The fix, and why not the condition the brief suggested

Gated on **Dart's own applicability predicate**, expressed with `target_cpu` to
match the surrounding code:

    target_cpu == "x64" || target_cpu == "arm64" || target_cpu == "riscv64"

That is identical to `build_analyze_snapshot` in
`third_party/dart/runtime/runtime_args.gni` — *"The analyze_snapshot tool is
only supported on 64 bit AOT builds"* — so it **cannot broaden**
`analyze_snapshot` to any target Dart declines to build.

The brief said to use "the same applicability condition already used by the
correct upstream block". Taken literally that is
`(host_os == "linux" && (x64 || riscv64)) || target_cpu == "arm64"` — and it is
**false for a macOS-host x64 build**:

| target_cpu | upstream `:52` condition | Dart applicability |
|---|---|---|
| arm64 | true | true |
| **x64** | **false** | **true** |
| arm | false | false |

Using it would have dropped `analyze_snapshot` from the x64 build and changed
artifacts this fix is required to leave alone. The predicate above is the
applicability condition the upstream block is *approximating*; it is the one
that is exactly right here. Recorded because it is a deliberate deviation.

Two places needed it, because `create_macos_analyze_snapshots` is referenced
exactly once (`:39`) and consumes the two instantiations: gating only the
instantiations would have left the action's `deps` dangling.

## Qualification of the fix

| # | required | result |
|---|---|---|
| 1 | pre-change armv7 reproduces the unresolved dependency | ✓ [`gate1_pre_armv7.log`](gate1_pre_armv7.log) — file provably unmodified (`git status --porcelain` empty), source `dfa2b24a…`, exact error text |
| 2 | post-change armv7 configures | ✓ `gn exit=0`, `Unresolved dependencies` count **0** |
| 3 | arm64 remains configurable | ✓ `gn exit=0`, all 10 `create_macos_analyze_snapshot` targets still present |
| 4 | x64 remains configurable | ✓ `gn exit=0`, all 10 still present |
| 5 | diff limited to the applicability gate | ✓ 4 hunks, both in the two affected regions, nothing outside; **76 changed lines** (47 added, 29 removed) of which the substance is two `if` guards and their comments, the rest being the indentation a wrapping `if` forces (normalised with the engine's own `gn format`). *Corrected: this first read 81, which counted the patch's two `+++`/`---` file-header lines and three of its trailer lines as content.* |
| 6 | condition does not broaden beyond Dart | ✓ identical to `build_analyze_snapshot`'s predicate |

Per-architecture effect, measured:

    arm    gn exit=0  create_macos_analyze_snapshot targets=0   unresolved=0
    arm64  gn exit=0  create_macos_analyze_snapshot targets=10  unresolved=0
    x64    gn exit=0  create_macos_analyze_snapshot targets=10  unresolved=0

## The non-impact control, and a control of mine that was INVALID

The ruling asked whether an armv7-only fix changes arm64 output. Two attempts:

**Attempt 1 — byte comparison. INVALID, and reported rather than quietly
dropped.** Pre- vs post-patch arm64 archives differ slightly (`darwin-x64.zip`
+1 byte, `artifacts.zip` −307, `symbols.zip` +62), with **identical member
lists** and a **byte-identical `gen_snapshot`** (`8ed5fe89…`). `libflutter.so`
differed by 6,633 bytes of 171 MB, first at offset 736 — the GNU build-id note —
and the revision string is present exactly once in each (`dfa2b24a` in the old,
`f1a59b8a` in the new).

To isolate the stamp I rebuilt arm64 from the patched source with
`engine_version` forced back. That experiment was **wrong**: it copied the out
dir and rewrote `args.gn`, which produces an inconsistent partial rebuild —
78% of `libflutter.so` differed and even `gen_snapshot` diverged from both
earlier builds. With `enable_lto = true`, byte-identity is not reliable evidence
in either direction. The result is discarded and stated here so nobody cites it.

**Attempt 2 — build-graph comparison. VALID and decisive.**
[`gate1_graph_control.log`](gate1_graph_control.log). Same git HEAD, so
`engine_version` is constant; only `lib/snapshot/BUILD.gn` differs between the
two generations:

    patched: 21856 targets
    parent : 21856 targets
    IDENTICAL — the gate changed nothing in arm64's build graph

That is the sound form of the control: the gate's condition is *true* for arm64,
so GN evaluates the same statements, and the target lists confirm it by
evaluation rather than by argument. Immune to LTO nondeterminism.

## Gate 2 — the 14 identity-bearing members, all ours

Built from `f1a59b8a…`. No substitution from fallback or upstream bytes; the
Maven coordinates carry our own revision, not the fallback's.
[`gate2_member_hashes.txt`](gate2_member_hashes.txt).

| member | sha256 (16) |
|---|---|
| `android-arm-release/darwin-x64.zip` | `d0e60fea5c90ccae` |
| `android-arm-release/artifacts.zip` | `ff4e115f51343280` |
| `android-arm64-release/darwin-x64.zip` | `fbc51de0ad3c6c03` |
| `android-arm64-release/artifacts.zip` | `9e0a69bc8531b770` |
| `android-x64-release/darwin-x64.zip` | `c9541e455fbba22a` |
| `android-x64-release/artifacts.zip` | `9afb110ddbb66cfe` |
| `armeabi_v7a_release-1.0.0-<rev>.jar` | `ea7df3dc79e1590e` |
| `armeabi_v7a_release-1.0.0-<rev>.pom` | `6719b9408b1a659d` |
| `arm64_v8a_release-1.0.0-<rev>.jar` | `428f7c5489d53190` |
| `arm64_v8a_release-1.0.0-<rev>.pom` | `dbd5a4932ebd93da` |
| `x86_64_release-1.0.0-<rev>.jar` | `4ca1387cc8d4425c` |
| `x86_64_release-1.0.0-<rev>.pom` | `c2d384046f3a46b7` |
| `flutter_embedding_release-1.0.0-<rev>.jar` | `cd75b85e12839fb3` |
| `flutter_embedding_release-1.0.0-<rev>.pom` | `d014d9ba2a12c071` |

The Maven packaging came from the engine's own pipeline
(`shell/platform/android:{embedding_jars,abi_jars}`, POMs via
`tools/androidx/generate_pom_file.py`), not hand-assembled — so the `.pom`
version strings and the AAR layout are the product's, not mine.

## What remains in this lane

Gate 2's mutation controls, gate 3 (the `%H` POM canonicalization rule and the
30-member descriptor with truthful per-platform provenance), gate 4
(`@must_be_local` for `android-arm-release/` and `android-x64-release/`), gate 5
(mint, publish, fetch-back), gate 6 (24-object closure against the new cell).

The members are staged at `/Volumes/build/route-b/acs2/members_f1a59b8a/` and
are still carrying the **engine revision** in their Maven coordinates. Gate 5's
`%H` render is what turns those into the cell address.
