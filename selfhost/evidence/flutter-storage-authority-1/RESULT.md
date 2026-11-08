<!-- cspell:words getsockname localsend uncontacted -->

# FLUTTER-STORAGE-AUTHORITY-1 — one authority, and the call that was escaping it

2026-09-03. Product change to `packages/shorebird_cli`, re-qualified.
No new cell, no Android release, no device, no fallback bytes copied under the
current cell, no change to `@must_be_local`.

## A premise correction, first, because the brief rested on it

The brief said *"The Android evidence specifically confirms that the proposed
`SHOREBIRD_FLUTTER_STORAGE_BASE_URL` mechanism does not exist today."* Half of
that is right and the half that mattered was wrong, and the wrong half was
**mine**:

* `SHOREBIRD_FLUTTER_STORAGE_BASE_URL` indeed does not exist. It also should
  not — see below.
* But the plain **`FLUTTER_STORAGE_BASE_URL` was already honoured**, and had
  been since `05fc58f5`, the original self-host commit. My
  ANDROID-FINAL-STACK-1 write-up said the CLI "hard-codes the storage URL",
  citing `CDN_INDEPENDENCE.md`'s table — a row that described the behaviour
  *before* that same commit changed it and was never updated. I repeated a
  stale document instead of reading the code.

Both documents are corrected in this lane's commit. The Android finding itself
is untouched: routing was never the Android blocker, because there is no
Android release engine at the cell address to route **to**.

So the brief's escape clause applied — *"unless implementation inspection
reveals a materially better single authority"* — and inspection did. A third
alias for a working standard knob would have been strictly worse than the
problem.

## What the inspection actually found: the authority was SPLIT, not absent

Five places decided an origin, under **two differently-named variables** plus
one hard-coded literal:

| site | governs | authority before |
|---|---|---|
| `shorebird_process.dart` `_environmentOverrides` | the Flutter child's engine artifacts | `FLUTTER_STORAGE_BASE_URL` |
| `third_party/flutter/bin/internal/shared.sh` | the first-run bootstrap | `FLUTTER_STORAGE_BASE_URL` |
| `cache.dart` `storageBaseUrl` / `storageBucket` | `aot-tools.dill`, `patch`, `bundletool` | `SHOREBIRD_STORAGE_BASE_URL` / `SHOREBIRD_STORAGE_BUCKET` |
| `route_b_compiler_cache.dart` (via the above) | **the Route B compiler cell bundle + its v2 descriptor** | same |
| `network_checker.dart` | `doctor`'s reachability probe | **hard-coded** `storage.googleapis.com` |

The fourth row is why this is a correctness problem and not a convenience one:
**a deployment that pointed only the Flutter variable at its own CDN would
still fetch the bytes that DEFINE its compiler cell from Shorebird's.**

Measured, from one run's own log with only the Flutter variable set:

    http://127.0.0.1:59526/flutter_infra_release/…/android-arm-profile/…   <- ours
    https://storage.googleapis.com/download.shorebird.dev/shorebird/…/aot-tools.dill  <- theirs

## What was built

`lib/src/artifact_origin.dart` — the single authority, and the only place an
origin default literal lives. Per value: its own specific variable, then
`SHOREBIRD_ARTIFACT_ORIGIN`, then the upstream default. Every site above now
resolves through it.

`SHOREBIRD_ARTIFACT_ORIGIN` moves the **base** of both halves and deliberately
leaves the **bucket** segment alone, because the self-host CDN mirrors
upstream's `<bucket>/shorebird/<engine>/…` path shape — its `@must_be_local`
matcher literally begins `[^/]+/shorebird/`.

The shell bootstrap resolves the same authority in shell, because it runs before
any Dart exists — it is the download that produces the Dart SDK. A test pins
both orders and both defaults so that duplication cannot drift.

`doctor` now probes the **resolved** storage origin. Hard-coding upstream's was
wrong in both directions: it reported a fault for an air-gapped stack that was
working, and stayed green while the configured origin was unreachable — the one
host the check exists to establish. The control-plane and auth entries are
untouched; this is storage authority, not general endpoint configuration.

An empty value reads as **absent**, so `FLUTTER_STORAGE_BASE_URL=` in a profile
or CI job cannot silently strip the host from every artifact URL.

## THE BUG THIS LANE ACTUALLY FOUND

The live control disagreed with the code reading, which is why it was run:
with `SHOREBIRD_ARTIFACT_ORIGIN` set, the Shorebird half routed and the
**Flutter half still went to `https://download.shorebird.dev`.**

`ShorebirdFlutter._precache` is the one call that actually downloads engine
artifacts, and it was blocked from the injection **twice over**:

1. it passes the target revision's **absolute** binary path, so
   `executable == 'flutter'` never matched;
2. it passes `useVendedFlutter: false` — deliberately, because it runs that
   revision's own binary — so the override was not consulted at all.

My earlier hand-run had looked correct only because I had exported
`FLUTTER_STORAGE_BASE_URL` in my own shell, which the child inherits regardless
of anything the CLI does. **A harness convenience had been standing in for the
mechanism.**

Fixed by matching the Flutter executable by **basename**, and by applying the
origin when one is *configured* even if `useVendedFlutter` is false — that flag
is about which flutter runs, not where its artifacts come from. With nothing
configured the condition reduces to the upstream one exactly, so the upstream
tests that pin `useVendedFlutter: false → {}` still pass unchanged.

## Controls — 10 passed, 0 failed

Live, against the real CLI, with a logging origin so every assertion is on what
the CLI **asked** rather than on what it was configured to ask.
[`qualification.log`](qualification.log),
[`../../scripts/fsa_qualify.sh`](../../scripts/fsa_qualify.sh).

| # | control | result |
|---|---|---|
| 1 | **positive routing** — one variable, both halves | the probe received `flutter_infra_release/…` (2 req) **and** `…/shorebird/…/aot-tools.dill` (1 req) |
| 2 | **poison control** — distinctive 404 | the CLI failed (exit 70), and **zero requests whose HOST is upstream** |
| 3 | **child-process propagation** | the `flutter_infra_release/flutter/cd848320…` request can only have come from the Flutter child; the CLI never fetches that path shape itself |
| 4 | **no fake green** | with nothing listening the probe log is empty, so control 1's assertion is capable of failing; the CLI also fails on an unreachable origin |
| 5 | **default control** — nothing set | upstream hosts used (2 req), no local origin leaked |
| 6 | **all injection sites** | an enforcement test bans origin literals outside the authority |

Control 6 is a unit test rather than a live one, because it is about code that
does not exist yet: a *future* download path that hard-codes an origin would
escape silently and nothing else would notice. It has a reasoned allowlist for
the three places that are not fetched URLs — the authority's own defaults,
`RouteBCompiler`'s manifest **member name** (part of a cell address preimage;
rewriting it would move cell addresses), and the maven URL printed for a
developer's own `build.gradle` — plus a staleness check so an exemption cannot
outlive its reason.

**It earned itself immediately: it caught `network_checker.dart`, which I had
missed.**

CLI suite: **2740 pass**, 2 pre-existing skips.

## Two harness faults of my own, both of which produced a wrong reading

1. **A substring match on a URL is not a host match.** The first clean run
   reported a fallback leak for
   `http://127.0.0.1:PORT/download.shorebird.dev/shorebird/…` — a request that
   went to the configured origin and merely *carries* the upstream name as its
   bucket path segment, which is the documented design. Control 2 now parses
   hosts.
2. **`ls -t … | head -1` returns 141 under `pipefail`** (SIGPIPE when `head`
   closes early), which aborted the first qualification run after control 1 had
   already produced its data. Replaced with an explicit newest-file lookup.

## Re-qualification

This changes CLI product code, so the qualification identity moved, in the
established order: **product commits, then the record commit.**

| | before | after |
|---|---|---|
| `cli_revision` | `cba3501615f80aa2c0f0c631366639899b0a7241` | `5920a8bf0a992618bfe7d1680c5439abd7a4f55f` |
| `packages_shorebird_cli` tree | `e3ebed51cabcc05423b85b4ea4b146fc734a5413` | `6c76e79a3ad1c86658a41b144dececb07ff5d3ca` |

The superseded values are kept in the record, not deleted, so a reader can tell
which product tree an older evidence document was measured against. **No
selector moved** — same Flutter revision, same cell, same compiler archive, same
analyzer, same updater — so this re-qualifies the producer tree, not the
toolchain.

`verify_supported_state.sh`: **SUPPORTED STATE VERIFIED**.

One process note worth inheriting: I first typed the new `cli_revision` from
memory and got it wrong. Banked identities are now taken from
`git rev-parse` output rather than transcribed.

### The negative control the guard exists for

Real product code mutated beneath the new qualification, selectors untouched —
see [`negative_control.log`](negative_control.log). The guard must still fail on
product-tree drift, and it does. Run in a scratch **worktree** so the main tree
was never touched; a `git stash` was correctly refused by this environment's
own destructive-git hook.

## Stop boundary honoured

No new cell. No Android release. No device. No fallback Android bytes copied
under the current cell. `@must_be_local` untouched — the 404 it produces for
`android-arm64-release/` on cell `cd848320…` is still there and still correct.

**Routing is now fixed and `cd848320…` still lacks Android artifacts.** That is
expected, and it is ANDROID-CELL-SUPPLY-1's problem.

## Provenance

| thing | value |
|---|---|
| product commits | `d1db834f` (the authority), `5920a8bf` (the escaping call) |
| qualified CLI tree | `6c76e79a3ad1c86658a41b144dececb07ff5d3ca` |
| runtime checkout | moved to `5920a8bf` with the bootstrap stamp cleared, so the live controls ran the committed code |
| CLI suite | 2740 pass, 2 pre-existing skips |
| live controls | 10 pass / 0 fail |
