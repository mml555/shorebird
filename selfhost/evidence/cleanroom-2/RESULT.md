<!-- cspell:words seatbelt armv PREREQ prereq CLEANROOM cleanroom -->

# SELFHOST-CLEANROOM-2 — the stack reproduces from durable sources

2026-09-04. **CLEANROOM REPRODUCIBLE.** The negative result of
SELFHOST-CLEANROOM-1 is closed.

    CLEANROOM REPRODUCIBLE
    proven at revision  df037532d3ce613651e22274abbd82bedf1820e2

[`cleanroom2_run.log`](cleanroom2_run.log),
[`bootstrap.log`](bootstrap.log),
[`origin_requests.jsonl`](origin_requests.jsonl),
[`seatbelt_profile.sb`](seatbelt_profile.sb).

## The same hostile room, not a friendlier one

Same denials as CLEANROOM-1, asserted per path, with the control that keeps the
assertion from being vacuous — those same paths **are** readable outside the
sandbox, so it is the kernel refusing:

    PASS  denied: /Volumes/build/route-b
    PASS  denied: /Users/mendell/shorebird
    PASS  denied: /Users/mendell/.shorebird
    PASS  denied: /Users/mendell/.pub-cache
    PASS  denied: /Users/mendell/.gradle
    PASS  5 of them ARE readable outside the sandbox, so the denial is what stops them

Fresh `HOME` with no `.shorebird`, `.pub-cache` or `.gradle`; `env -i` with a
six-variable allowlist. The room is re-checked at the END of the run too, so a
mid-run relaxation could not go unnoticed.

## The acceptance table

| | |
|---|---|
| immutable selfhost tag | **RESOLVES** anonymously |
| record | **CURRENT** (cell `f85251f3…`) |
| record format | **duplicate-free**, checked with no external dependency |
| `cli_revision` | **RESOLVES** |
| `flutter_selector` | **RESOLVES** |
| selector → `f85251f3…` | **MATCH** — read at the *recorded* revision |
| engine producers | **RESOLVE** (both, at refs pointing AT the commit) |
| cell durable distribution | **AVAILABLE** |
| cell members | **30/30** |
| cell address | `f85251f344600ae08196925a174e9cff8f0ff18e` |
| **SUPPORTED STATE VERIFIED** | **YES** |

The bootstrap completed from the tag alone — clone, read the record, create the
runtime checkout at `cli_revision`, download the cell and check the bundle
against the digest **committed in the record**, hydrate 30/30, fetch the exact
selector and confirm its `engine.version` selects the recorded cell, derive
`SHOREBIRD_ROOT`, verify.

## The work CLEANROOM-1 could not reach

    flutter precache --ios      exit=0    release-side artifacts hydrated
    flutter precache --android  exit=0    release-side artifacts hydrated

No physical devices. No inherited cache — `pub get` rebuilt 559 MB of
`.pub-cache` from nothing inside the room. No `/Volumes/build` read, re-asserted
after the fact.

### Attribution, which is the part that matters

    requests total                              36
    for objects IN the distribution             18
      served from the hydrated overlay          18
      served by upstream                         0
    for objects NOT in the distribution         18
      of those, under the cell path (rewritten) 10
    non-200 responses                            0

Every object the distribution contains came **from** the distribution. The
eighteen that fell through are the ones it deliberately excludes — including the
ten `CACHE/TRANSPORT` objects ANDROID-CELL-SUPPLY-1 measured as not
identity-bearing — and they are counted separately so the two cases cannot be
confused. A distributed object answered by upstream fails the run, because it
would mean the distribution was never used.

## The cleanroom found four faults before it passed

Three were mine and one was the product's. This is the argument for running it
rather than reasoning about it.

1. **`selfhost-v1.1.0`'s bootstrap cannot complete.** It hydrated the cell into
   `$ROOT/overlay` while `verify_supported_state.sh` reads members from the
   clone's `selfhost/cdn/overlay` and the CDN compose file mounts that same
   directory. The first hostile run failed with *"no published compiler
   archive"* and was right to. **That tag must not be pinned.** It is kept
   rather than deleted — refs are provenance — and `bootstrap_selfhost.sh`
   auto-discovers the *newest* `selfhost-v*`, so an operator following the
   documented path does not land on it.
2. **`audit_route_b_compiler.sh` read a path on the qualification machine** —
   `/Users/mendell/shorebird/selfhost/cdn/overlay`. On any other checkout it
   inspected a directory that does not exist and reported *"no bundle published
   for this engine hash"* while the bundle sat in the clone's own overlay. The
   same defect class as the `SHOREBIRD_ROOT` default, and the last hard-coded
   absolute path on the supported verifier path. **This one is a product
   defect,** not a harness fault.
3. **My hydration origin was a bare static server.** Precache died on
   `flutter/fonts/<hash>/fonts.zip`, a stock Flutter asset no engine cell
   contains. The real CDN serves the overlay and falls through. Replaced with an
   operator-shaped origin that also records the SOURCE of every response — which
   upgraded the step from an exit code to the attribution table above.
4. **That origin's rewrite target was wrong, twice.** Upstream has never
   published our cell, so a non-overridden artifact must be resolved under
   another revision. My first guess was `experimental_hashes.map`'s *fallback
   engine* — measured, 404, because that engine's artifacts are not in the
   `flutter_infra_release` bucket. What the production CDN actually answers:

       GET /flutter_infra_release/flutter/f85251f3…/android-arm-profile/darwin-x64.zip
       302 -> /gcs/flutter_infra_release/flutter/83675ed2…/android-arm-profile/darwin-x64.zip

   The target is `flutter_engine_revision`, and it is **not outside
   knowledge**: it lives in the cell's own `artifacts_manifest.yaml`, one of the
   30 distributed members. Validated standalone before spending another
   six-minute run.

And one process fault worth recording: a wait-for-this-string guard matched a
**previous** run's log twice, the second time after I had already said I fixed
it. Waits are now on the process, and every run stamps the log with a UTC
timestamp and pid so a stale read is visible to a reader too.

## What this does and does not establish

**Does:** a machine that has never seen this stack can obtain it from an
immutable tag plus a durable release, verify the supported state, and hydrate
release-side artifacts for both supported platforms — with the qualification
machine provably unreadable.

**Does not:** physical device activation (unchanged, and separately qualified),
the hydrated tree exercised through Caddy's own rewrite and `@must_be_local`
rules inside the cleanroom (proven in SELFHOST-DISTRIBUTION-1 gate 3c against a
tree measured byte-identical), and the CLI's own translation of
`SHOREBIRD_ARTIFACT_ORIGIN` into `FLUTTER_STORAGE_BASE_URL` (proven by
FLUTTER-STORAGE-AUTHORITY-1; the cleanroom sets the Flutter-native variable,
which is the documented operator knob).

Operator prerequisites reduced from three to zero blocking ones: the tag is
auto-discovered, `SHOREBIRD_ROOT` is derived by the bootstrap, and PyYAML is no
longer needed.
