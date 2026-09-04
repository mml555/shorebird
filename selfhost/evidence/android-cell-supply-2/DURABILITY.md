<!-- cspell:words armv canonicalization -->

# ANDROID-CELL-SUPPLY-2 addendum — the engine producer is now remotely durable

2026-09-04, in response to the ruling's one blocker. Evidence:
[`durability.log`](durability.log). Verifier:
[`../../engine/route_b/verify_engine_producer_durable.sh`](../../engine/route_b/verify_engine_producer_durable.sh).

    ENGINE PRODUCER DURABLE: f1a59b8a1609c51397601c36d586ad7763d57153
    parent AS PUBLISHED    : dfa2b24ac38477f3705ff0357530f33fe09474b8

**No rebuild.** The pushed commit is the commit that produced the 14 Android
identity members — established by measurement, not by assertion: the diff read
back from the remote hashes to `ab667fa27cbf73a4f03ef48c43361217d4836d18`, the
same digest as the patch this repo banked. A rebuilt or amended commit carrying
the same message would fail that check.

## Where it lives

| producer | refs on `github.com/mml555/shorebird-flutter` |
|---|---|
| Android members `f1a59b8a…` | `refs/heads/route-b-2c-android`, `refs/tags/acs2-android-producer` |
| macOS/iOS members `dfa2b24a…` | `refs/heads/route-b-2c-candidate`, `refs/tags/acs2-macos-ios-producer` |

The existing branch was **not moved**. `route-b-2c-candidate` still points at
`dfa2b24a…`, because 16 of the 30 members were produced by it and their
provenance dies with that ref.

I also tagged `dfa2b24a…`, which the ruling did not ask for. It was reachable
only through a *branch*, and a branch can move — so the producer of the
currently supported cell's members had no immutable-intent ref. Both producers
now have one.

## What the verifier actually checks, and at what strength

It does **not** trust the local checkout. Everything is fetched from the remote
into a throwaway repository and compared against bytes banked in this repo, so
"pushed" is established by reading the remote rather than by the absence of an
error from a push.

It checks **identity, not ancestry** — commit sha, parent sha, tree contents.
And it demands a ref that points **at** the commit, not mere reachability:
GitHub will serve a reachable object to a direct fetch, but reachability is a
property of some ref's current tip and a force-push takes it away.

Two strengths, because the two producers are different kinds of thing:

- **Android producer — full.** Advertised at a ref; fetches into a fresh repo;
  exactly one parent, and it is exactly `dfa2b24a…`; changes exactly one file
  and nothing else; the published diff equals the banked patch; and both
  applicability-gate sites are present **in the published source**.
- **macOS/iOS producer — reachability.** This repo banks no patch for it (it is
  upstream-derived), so a content check there would be a check that cannot fail
  for the right reason. Claiming more would be the vacuous shape this programme
  keeps naming.

## Falsification — three controls

| control | result |
|---|---|
| a real local commit **never pushed**, on no ref — its tree *and* parent are both already on the remote, so only the commit itself is absent | `no ref on the remote points at 03583fa1…`, `does not fetch` → **2 failures** |
| the right revision, a **wrong claimed parent** | `the published parent is dfa2b24a…, not 03583fa1…` → **5 failures** |
| a reachable revision with **no banked patch**, run at full strength | fails on content (`touches shell/common/shorebird/shorebird.cc`, diff ≠ banked patch, 0 gate sites) → **5 failures** |

The first control is deliberately the narrowest possible absence. An earlier
version used an abbreviated sha of a real ancestor, which failed — but for the
wrong reason: that commit *is* reachable from the remote's tip, so the control
was not testing absence at all.

## It is now part of the supported-state check

`verify_supported_state.sh` runs it for every producer revision the record
names, at the appropriate strength. Being **offline is a failure, not a skip** —
that file's rule is that missing evidence must never produce a pass.
`SKIP_DURABILITY=1` exists for a deliberately offline run and prints, in place
of a result, that the run establishes nothing about durability.

## A number corrected

`GATE1_RESULT.md` said the gate diff was "81 changed lines". It is **76** (47
added, 29 removed); 81 counted the patch's `+++`/`---` file-header lines and
three trailer lines as content. Corrected in place. The file path in that
document was also written `flutter/lib/snapshot/BUILD.gn`; the repository path
is `engine/src/flutter/lib/snapshot/BUILD.gn`.
