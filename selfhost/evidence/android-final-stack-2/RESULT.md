<!-- cspell:words armeabi bidiff vmcode uiautomator bmgr pristine armv unmutated keyguard -->

# ANDROID-FINAL-STACK-2 — Android is physically qualified on cell `f85251f3…`

2026-09-04. All three stages passed and the supported selector has moved.

    lineage.cell_address   cd848320d605ff8af5060cabf9a8d1b35853f752
                       ->  f85251f344600ae08196925a174e9cff8f0ff18e
    standalone_flutter_app.android   UNSUPPORTED ON THIS CELL -> SUPPORTED

    first launch    AFS2-V1-RELEASE
    after download  AFS2-V1-RELEASE   <- the mandatory middle observation
    after restart   AFS2-V2-PATCHED

`verify_supported_state.sh` is green after the move — 27 checks, including the
new cell's 30 members and the engine-producer durability checks.

## Stage A — the release, bound to the new cell

[`stage_a_release.log`](stage_a_release.log)

| | |
|---|---|
| app | `90068cb6-80e3-c102-a9d9-8fe6aeaa09b4` |
| release | id 1, version `1.0.0+1` |
| Flutter selector | `e64eb0af52e1c43c3b21a39556d789538d0df9b3` |
| `engine.version` | `f85251f344600ae08196925a174e9cff8f0ff18e`, a **committed blob** in a clean checkout |
| APK | sha256 `27827fe11c0a6a094386959d1ca40d323ed9bced619e95d6daeb25f6d1158782`, 47 MB |

Release artifacts as the control plane records them
([`release_artifacts.json`](release_artifacts.json)):

    arm                 3,195,468   7a7e74ebfb75deedc4196f34dc18ec11
    aarch64             2,884,496   4b0bb057043092b346465663b30e2c49
    x86_64              3,015,568   e065acea70bca0e2f9f9bd7ac078fae9
    aab                46,728,030   b877799973da5cdc9a65a4ec45d4c323
    android_supplement        244   2abca4e849385898544d8061407773bd

Hydration was from an **empty engine artifact cache and an empty Gradle home**,
so nothing could be satisfied from a warm cache.

### The shipped engine, proven before installing anything

AGP strips debug symbols, so the packaged `libflutter.so` is 6–9% of the cell
jar's and can never be byte-identical. The discriminator that survives
stripping is the engine revision string, asserted in both directions:

    arm64-v8a     13,878,552 (8% of jar)   producer x1   fallback x0
    armeabi-v7a    9,870,112 (6% of jar)   producer x1   fallback x0
    x86_64        15,572,672 (9% of jar)   producer x1   fallback x0

`producer` = `f1a59b8a…`, `fallback` = `69f9831c…`. The negative is not vacuous:
the fallback engine's own jar was checked first and names *its* revision exactly
once.

### Network attribution

[`artifact_requests.jsonl`](artifact_requests.jsonl) — every request through a
recording origin that logs the body digest, because a 200 says only that
*something* answered.

    android identity members : 14 / 14 from the new cell
    not requested            : 0
    wrong bytes              : 0
    answered via a redirect  : 0
    fallback-served paths    : 10  — exactly the cache/transport set

Only two non-200/302 answers in the whole build: a `400` on `/` and the `404` on
`aot-tools.dill`, already proven incidental by ANDROID-CELL-SUPPLY-1.

## Stage B — the ordinary bidiff patch

[`stage_b_patch.log`](stage_b_patch.log),
[`patch_identity.json`](patch_identity.json)

**A precondition first**, because a patch is only meaningful against the
artifact the device actually runs: each release artifact's recorded hash equals
the sha256 of the corresponding `libapp.so` **inside the APK** — 3 of 3 MATCH.
Without that, the diff could be computed against something other than what is
installed and every later observation would be about the wrong pair.

    patch id=1  number=1  status=ready  channel=stable
      arm       6,126 B   76991f2dab762a0f38a6b30755be0b7bbba62ec50b32a30067739ebc502a8685
      aarch64   6,082 B   b514bb25aa2cdeae0c7f118b29eb4c4bc0f44187d5f336fcf30ba36d67fa1f86
      x86_64    6,144 B   e9e0d7849abf90e3d3e65b6ceed609ba71dc04c3cdad7decd7b8c5bbbd0f9960

Each is **~0.2%** of the release artifact it patches — a diff, not a snapshot.

**"Ordinary producer" is evidence, not a grep.** A first version of this control
grepped the build log for `route.b|aot-tools|analyze_snapshot` and reported two
failures, *neither real*: the CLI unconditionally **attempts** `aot-tools.dill`
and warns on the 404, and the string `route-b` appears in this rig's own scratch
**path**. A log line mentioning a tool is not the tool running. What replaced it:

- `aot-tools.dill` requested **7 times, every one a 404**, and the patch still
  succeeded — so the AOT linker cannot be load-bearing here
- **0** Route B compiler or `dart2bytecode` artifact requests
- the artifacts are diffs, by the size ratio above

## Stage C — the physical sequence, CPH2551 wired over USB

[`stage_c_device.log`](stage_c_device.log)

Markers are read **mechanically** from the accessibility tree (`uiautomator
dump`), never from a picture; screenshots are kept as corroboration and pulled
as files, because `exec-out screencap -p` shares stdout with this device's
"[Warning] Multiple displays" line.

| step | result |
|---|---|
| screen awake and unlocked | ✓ (a secured keyguard makes every marker read empty) |
| app data gone after uninstall | ✓ |
| backup manager disabled | ✓ — see the incident below |
| updater started from **no state file** | ✓ |
| first patch check `current_patch_number: None` | ✓ |
| this launch booted the **base release** | ✓ |
| **first launch marker** | **`AFS2-V1-RELEASE`** ([screenshot](1_first_launch.png)) |
| `/api/v1/patches/check` → 200 | ✓ |
| patch `/download` → 200 | ✓ |
| `/api/v1/patches/events` → 204 | ✓ |
| requests answered 4xx/5xx | **0** |
| updater: `Patch successfully applied`, `output_written=2884496b` | ✓ — equals the release artifact size |
| updater: `Update installed`, *"will be launched when the app next restarts"* | ✓ |
| **marker after download, before restart** | **`AFS2-V1-RELEASE`** ([screenshot](2_after_download.png)) |
| **marker after restart** | **`AFS2-V2-PATCHED`** ([screenshot](3_after_restart.png)) |

Updater counters ([`updater_metrics.json`](updater_metrics.json)):

    patch 1  downloads=1  installs=1  install_failures=0  update_failures=0
             unique_clients=1

The middle observation is the load-bearing one. Without it, a changed marker is
equally consistent with a rebuilt install, a hot reload, or the wrong APK.

## Two of my own controls were wrong, and one of them said PASS

**A crash that looked exactly like a broken cell.** The first attempt aborted
with `Wrong full snapshot version, expected '21139db2…' found '839937dd…'`. I
measured rather than guessed which version was whose: `21139db2` is **our**
engine's and appears in our `libflutter.so` and the APK's `libapp.so`;
`839937dd` is the **fallback** engine's. So our engine had loaded a snapshot
from the fallback lineage.

Cause: `dev.selfhost.app` was a package name reused from ANDROID-FINAL-STACK-1,
which ran against a different engine, and Android's backup manager restored
`files/shorebird_updater/` from that app on reinstall — a `dlc.vmcode` inflated
for the wrong engine. With `bmgr enable false` and nothing else changed, the
same APK and the same patch installed cleanly. Full diagnosis:
[`backup_restore_incident.log`](backup_restore_incident.log). Fixed at the root
(a lane-specific org) and made detectable (the run now disables backup and
asserts the updater's own fresh-state lines).

**A check that passed vacuously — worse than the crash.** My
install-failure assertion read a top-level `install_failures` this schema does
not have, so `or 0` supplied a zero and it printed PASS while the real nested
counter said `install_failures: 1, unique_clients: 3`, polluted by the poisoned
attempt. The corrected check exits 1 on those same metrics, which is how I know
the earlier PASS was worthless — and it is why every stage was re-run against a
fresh app record rather than reported with a caveat.

**A stale-file wait guard.** A background waiter matched the *previous* run's
`STAGE A PASSED` before the new job truncated the log, so it reported completion
immediately. Waits are now on the process, not on a file's contents.

## The supported-state move

- `lineage.cell_address` → `f85251f3…`; the predecessor is recorded as
  **SUPERSEDED — the previous iOS-qualified cell**, retained and not rewritten,
  because every iOS qualification in that file was measured against it
- the selector chain names the new cell, and records that the Route B compiler
  archive digest is **unchanged** across the move — it is one of the members
  carried over byte-for-byte, so the compiler the iOS work was qualified with is
  the same file
- the qualified runtime checkout's Flutter `engine.version` was re-pointed and
  **committed** there, so the verifier's committed-blob check binds
- `product_surfaces.standalone_flutter_app.android` → **SUPPORTED**, with the
  prior UNSUPPORTED assessment kept as `superseded_assessment` and with what is
  *not* covered stated: iOS Add-to-App, Play Store distribution, and any ABI
  beyond the three shipped

## Boundary

Not done: any Play Store submission; any ABI beyond armeabi-v7a, arm64-v8a and
x86_64; iOS Add-to-App, which remains UNSUPPORTED with its four measured
blockers; any change to `cd848320…`, which is untouched and still verifies
16/16.
