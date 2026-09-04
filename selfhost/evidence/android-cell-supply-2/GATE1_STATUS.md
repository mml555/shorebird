<!-- cspell:words armv gclient prebuilt ninja depot cipd openjdk riscv -->

# ANDROID-CELL-SUPPLY-2 · Gate 1 — STOPPED for a decision on armv7

> **SUPERSEDED CONCLUSION — 2026-09-04.** The stop this document asked for was
> ruled on: Option A authorized. The armv7 blocker below is real and its
> reproduction is still the evidence of record, but the conclusion *"arm CANNOT
> CONFIGURE"* no longer holds — a narrow, PM-authorized applicability gate in
> `flutter/lib/snapshot/BUILD.gn` fixed it and all three architectures now
> configure and build. See [`GATE1_RESULT.md`](GATE1_RESULT.md). Nothing below
> is edited.

2026-09-04. The scratch build is the load-bearing gate and it has produced a
definite, partial answer.

    arm64  configures ✓   building (8730 targets, in progress)
    x64    configures ✓   not yet built
    arm    CANNOT CONFIGURE — precise blocker below

## What is established

**A new checkout at the exact source, without touching the qualified one.**
Made by copying rather than re-cloning, so the source bytes are identical — a
fresh `gclient sync` could resolve a floating DEPS entry differently and quietly
change the lineage.

| | value |
|---|---|
| engine source revision | `dfa2b24ac38477f3705ff0357530f33fe09474b8` — exact |
| Dart tree | HEAD `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c`, 2 local modifications, `git diff` digest `6b358f71…` — **byte-identical to the original tree** |
| Android deps | synced: `android_tools/{sdk,ndk,platform-tools,build-tools,cmake}`, `android_embedding_dependencies`, `trace_to_text`, CIPD `openjdk` |
| location | `/Volumes/build/route-b/acs2/` — the qualified tree at `/Volumes/build/route-b/flutter` was never written to |

`gclient sync` exited 1, and **the failure is benign and load-bearing in our
favour**: the only error is `cannot rebase: You have unstaged changes` on the
Dart dep, so gclient declined to move it. The Dart tree therefore still carries
exactly the fork state the qualified cell was built from — confirmed by
comparing HEAD, dirty-file count and diff digest against the original.

**GN configuration, from the engine's own publish pipeline.** The closure
members are emitted by real archive targets, not hand-assembled:

    zip_archives/android-arm64-release/darwin-x64.zip        gen_snapshot
    zip_archives/android-arm64-release/artifacts.zip         flutter.jar
    zip_archives/download.flutter.io/io/flutter/…/1.0.0-<engine>/…{jar,pom}

**A flag decision the evidence forced.** Building with `--dart-dynamic-modules`
(the iOS configuration) re-paths every archive to
`android-arm64-release-**ddm**/`. The closure measured
`android-arm64-release/`, so upstream's published release artifacts are
**non-ddm** builds, and non-ddm is the only configuration that emits the paths
the closure requires. Dropped it — which is also correct on the merits, since
Android patches are bidiff and never interpret. `shorebird_use_interpreter`
defaults to `is_ios` and is already false on Android, so it needs no override.

## THE BLOCKER — armv7 cannot be configured from this lineage on a macOS host

    ERROR Unresolved dependencies.
    //flutter/lib/snapshot:create_macos_analyze_snapshot_arm64_arm(//build/toolchain/android:clang_arm)
      needs //flutter/third_party/dart/runtime/bin:analyze_snapshot(//build/toolchain/mac:clang_arm64)
    //flutter/lib/snapshot:create_macos_analyze_snapshot_x64_arm(…)
      needs …:analyze_snapshot(//build/toolchain/mac:clang_x64)

Isolated: it fails **with and without** `--dart-dynamic-modules`, while arm64
configures cleanly in the same tree with the same flags. Not a flag interaction.

**Root cause, read from the source.** Two gates that disagree:

* `flutter/third_party/dart/runtime/runtime_args.gni:101-104` —
  *"The analyze_snapshot tool is only supported on 64 bit AOT builds"*:
  `build_analyze_snapshot = dart_target_arch == "x64" || "arm64" || "riscv64"`.
  For `dart_target_arch == "arm"` it is **false**, so the target does not exist.
* `flutter/lib/snapshot/BUILD.gn:52-58` gates the *upstream* dependency
  correctly — `if ((host_os == "linux" && …) || target_cpu == "arm64")`.
* But the **Shorebird-added** block at `:265-307`, commented *"Added by
  shorebird … to allow us to include analyze_snapshot in the artifacts generated
  for create_ios_framework.py"*, instantiates
  `build_mac_analyze_snapshot("create_macos_analyze_snapshot_{arm64,x64}_${target_cpu}")`
  **ungated**, and depends on `analyze_snapshot` unconditionally.

So a block added for **iOS** is pulled into every macOS-host configuration,
including Android-armv7, where the tool it wants cannot exist. This is a
pre-existing defect in the engine fork, dormant because it only fires for a
32-bit target on a mac host — a combination Shorebird's own CI evidently does
not build (its published `android-arm-release/` artifacts exist, and the
upstream gate at `:52` implies Android is built on Linux).

## Why this needs a decision rather than a patch

The fix looks like a three-line `if` around the Shorebird-added instantiations,
mirroring the gate that already exists 250 lines above in the same file. That is
an **engine source change**, and the brief is explicit: *do not start changing
engine source to make the build work without another PM decision.* Stopped here.

The options, with what each costs:

| option | consequence |
|---|---|
| **A · gate the Shorebird-added block** on the same condition as `:52` | 3 lines in `flutter/lib/snapshot/BUILD.gn`. Changes the engine source, so the new cell's lineage is no longer byte-identical to `dfa2b24a` and the change must itself be qualified. Smallest technical fix |
| **B · drop armv7 from the cell** | No source change. But `flutter build appbundle` defaults to `--target-platform=android-arm,android-arm64,android-x64`, and the Supply-1 closure measured `armeabi_v7a_release` as required — so a default release would still ask for armv7 Maven artifacts the cell cannot authenticate. Needs either a documented `--target-platform` restriction or accepting a fallback for armv7, which reintroduces exactly the identity hole this programme is closing |
| **C · build Android on a Linux host** | The mac templates are not instantiated there, so the defect does not fire — consistent with how upstream evidently builds it. No source change and no lineage change. Requires a Linux x64 host with this checkout; none is in evidence on this rig |

I have no recommendation that does not turn on information I do not have: B's
cost depends on whether armv7 is in scope for the product at all, and C's
feasibility depends on whether a Linux host is available.

## What is still running

The **arm64** build is in progress and is needed under every option, so it is
not speculative work. Status at the time of writing: 8730 ninja targets, Skia
compiling, and the Java `flutter_shell_java` action already succeeded — which
independently confirms the synced NDK and the CIPD `openjdk` are usable.

Nothing has been minted, published, or addressed. `cd848320…` is untouched,
`@must_be_local` is unchanged, and no product code has been modified.
