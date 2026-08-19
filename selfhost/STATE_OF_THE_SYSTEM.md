# State of the system — practical, 2026-08-18

What we have actually achieved, how it compares to upstream Shorebird, and which
parts would mean anything to them. Uses `PARITY.md`'s status vocabulary.

---

## 1. WHAT WE HAVE ACHIEVED

### Android code push — PROVEN, and effectively done

Release → patch → download → execute → persist → roll back, on our own engine,
our own artifacts, our own control plane. Device-verified (CPH2551 / Android 16 /
arm64). **No known gap in the core loop.** What is unvalidated is configuration
surface — flavors, defines, signing, tracks — not mechanism.

### iOS code push — PROVEN end to end, without upstream's private linker

This is the headline achievement. Upstream's iOS code push depends on
`aot-tools.dill`, their **private** AOT linker. We do not have it and do not need
it: Route B replaces a function's body with bytecode executed through the
interpreter, and the whole chain runs unattended.

    shorebird release ios -> edit one function -> shorebird patch ios
      -> control plane -> updater -> inflate -> install -> lifecycle promotion
      -> native pre-main activation -> patched Dart running -> relaunch still
      patched -> rollback to pristine AOT

Cost: **+4.5% size, +0.3% median frame time, zero added jank.** Both original
vetoes are closed.

**8 device-proven specimens**, 4 with screenshots showing the patched value
alongside `code patch: N` and unpatched control fields still at release values.

### Self-hosting independence — BUILT/PROVEN across 10 upstream dependencies

| # | upstream dependency | our replacement | status |
|---|---|---|---|
| 1 | `api.shorebird.dev` | `packages/code_push_server` | **Built** |
| 2 | `shorebirdtech/dart-sdk` (private) | vanilla Dart + 57-line shim | **Built** |
| 3 | private prebuilt Dart SDK (401s for us) | build from source | **Built** |
| 4 | `shorebird_cli` | forked, pinned, `+selfhost.N` | **Built** |
| 6 | `patch` binary | `vendor/updater/patch` — **byte-identical output** | **Done** |
| 7 | **their private AOT linker** | **Route B** | **replaced** |
| 8 | engine artifacts | own every artifact whose correctness we depend on | **Built** |
| 9 | artifact manifest | generated ourselves | **Built** |
| 10 | `shorebirdtech/flutter` git | mirror + our fork | **Built/Mirrored** |

**We can operate with upstream switched off.** That was the goal and it is met.

### The G15 investigation — mechanism closed

The long-running "patch attaches but the old value executes" mystery is
**explained and repairable**:

> A foldable constant-return target has its result substituted at every call
> site, so no call reaches the `Function`, nothing references it in the object
> pool, Route B attaches perfectly — and nobody ever calls it. Give the same
> target an opaque body and the call survives, the pool reference appears, and
> the patched value renders.

Demonstrated in both directions: synthetically on a matched pair, and by one-line
repair on the target that had failed for the entire investigation
(`ABSENT -> UNIQUE`, `OLD-kill -> NEW-kill`).

### Infrastructure achieved this session

* engine work moved from detached HEADs + `.patch` files onto real branches
  (`mml555/shorebird-flutter@route-b`; Dart SDK unshallowed to 121,349 commits);
* the cost of catching up to upstream Flutter **measured**: 5 conflicts across 39
  files and ~3,350 commits, `updater_rev` unchanged so the wire contract is safe;
* repo reduced from 16,930 tracked files to 1,206;
* publish durability content-read on both halves.

---

## 2. PARITY WITH UPSTREAM

### Where we EXCEED upstream (SUPERSET)

| capability | note |
|---|---|
| **Self-hosted control plane** | upstream is SaaS-only; we run the whole thing |
| **iOS code push without the private AOT linker** | upstream's iOS path requires `aot-tools.dill`; ours does not |
| **Air-gapped operation** | mirrors, overlay CDN, no outbound dependency |
| **Provenance/audit tooling** | measured ancestry per engine cell; upstream has no equivalent |

### Where we MATCH upstream

Android code push end to end; release/patch/rollback lifecycle; tracks and
channels; the patch differ (byte-identical output); artifact serving.

### Where upstream EXCEEDS us

| gap | status | why it matters |
|---|---|---|
| **iOS Dart language surface** | **PARTIAL** | upstream's linker patches arbitrary Dart. Route B accepts a defined subset and REFUSES the rest. Refusal is the designed failure mode — a rejected patch, never a wrong one |
| **Foldable-constant targets** | **KNOWN GAP** | a constant-returning function is optimised away at its call sites; a patch attaches and silently does nothing. Mechanism understood; the CLI does not yet refuse it |
| **Workflow surface** | **INHERITED** | flavors, defines, obfuscation on iOS, signing, tracks/rollouts, manual update API, add-to-app, CI runs — upstream code present in the fork, never exercised on our stack |
| **Windows / Intel-Mac hosts** | deliberately `compat-mirrored` | not built |
| **Multi-platform breadth** | upstream ships macOS/Windows/Linux paths we have not validated | |

### The honest summary

**We match upstream on Android, exceed it on self-hosting and on iOS-without-
their-linker, and trail it on iOS language coverage and on the long tail of
workflow features we inherited but never validated.**

---

## 3. WHAT IS PRODUCT vs WHAT IS EXPERIMENT

| area | status | would a user depend on it? |
|---|---|---|
| Android code push | **PROVEN** | yes |
| Self-hosted control plane | **BUILT** | yes |
| Independence from upstream services | **BUILT/PROVEN** | yes |
| iOS Route B, accepted language subset | **PROVEN** | yes, within the subset |
| iOS Route B, general Dart | **EXPERIMENTAL** | no — not in the supported contract |
| Engine patches `0001`-`0013` | **EXPERIMENTAL** | no |
| Tombstone/retry lifecycle semantics | **IN TESTING** | one manual tap outstanding |
| Inherited workflow surface | **INHERITED** | unknown — never validated here |

`compatibility.yaml` is the contract, and it deliberately does NOT list Route B.
That is correct: Route B is a proven mechanism inside a defined subset, not a
general capability.

---

## 4. IF WE PUSHED UPSTREAM — WHAT WOULD ACTUALLY MATTER

Most of this is not upstream-shaped, and saying so plainly is more useful than
pretending otherwise.

### Not upstream-relevant

`code_push_server` (they sell the hosted plane), the mirrors/overlay CDN, the
selfhost docs and evidence tree, our fork pinning. These exist because we do not
want their SaaS. That is not a contribution to them.

### Genuinely upstream-relevant

| what | why they would care | readiness |
|---|---|---|
| **The foldability finding** | a patch can attach successfully and silently not execute. This applies to THEIR linker path too wherever a target is optimised away — and today nothing warns | **PROVEN**, needs no code |
| **A CLI refusal for un-patchable targets** | turn the above into "we refuse this patch" instead of shipping a no-op. Small, self-contained, defensible | **NOT BUILT** — the highest-value upstream contribution available |
| **`aot_tools` link-failure diagnostics** | we already consume their `119406bb` | theirs, not ours |
| **Route B itself** | an iOS code-push path that needs no private linker. Strategically significant to them — possibly unwelcome | **EXPERIMENTAL**, large |
| **Boot-lifecycle safety (`0009`/`0010`)** | a patch retired by two ordinary process deaths is a false backout; the threshold work addresses it | **IN TESTING** |

### The one thing worth finishing for upstream credibility

**Detect and refuse a target whose call sites have been optimised away.** Today
Route B ships a patch that attaches, reports success, and does nothing. We have
the instrument that detects it (`TPOOL_ABSENT`, plus static call-site probing
that already reproduces the condition). Turning it into a pre-publication refusal
would convert the project's most embarrassing failure mode into its most
defensible feature — and it is small.

---

## 5. NEXT STEPS, ranked by value

1. **CLI refusal for foldable/optimised-away targets** — closes the KNOWN GAP,
   upstream-relevant, small.
2. **Finish the tombstone/retry lane** — one manual tap; operational safety.
3. **Batch-validate the INHERITED workflow surface** — flavors, defines,
   obfuscation, signing, tracks. Cheap per item, many items; converts a large
   INHERITED block into PROVEN or KNOWN GAP.
4. **Apply the Flutter bump** — cost already measured; do it after any
   hybrid-dependent measurement, since `SNAPSHOT_HASH` will move.
5. `TPOOL_AMBIGUOUS`, pragma effects — parked until they block something.
