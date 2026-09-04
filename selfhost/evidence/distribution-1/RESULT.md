<!-- cspell:words seatbelt armv canonicalization PREREQ prereq Requalified serveable -->

# SELFHOST-DISTRIBUTION-1 — the distribution is repaired

2026-09-04. Every defect SELFHOST-CLEANROOM-1 found is closed, and each repair
is proven rather than asserted. `SELFHOST-CLEANROOM-2` is the hostile re-run
that decides whether the end-to-end claim holds; its result is recorded in
[`../cleanroom-2/RESULT.md`](../cleanroom-2/RESULT.md).

    gate 0  distribution status banked, platform statuses untouched   DONE
    gate 1  the qualified Flutter revision is durable                 DONE
    gate 2  the CLI selects it; the verifier reads it at that revision DONE
    gate 3  the exact cell bytes are durably distributed              PROVEN
    gate 4  one bootstrap path; no machine-specific default           DONE
    gate 5  an immutable selfhost tag carries all of it               DONE
    gate 6  no ambient PyYAML on the supported path                   DONE

## Gate 0 — capability qualified ≠ product distributable

`distribution:` is a new top-level field, deliberately separate from
`product_surfaces`. Those statuses are about mechanisms physically qualified on
the supported cell and they stand; this one is about whether a third party can
deploy, and it did not. Collapsing them would let a reader conclude from
"iOS: SUPPORTED" that someone else can deploy iOS.

## Gate 1 — the Flutter revision, and a precondition that did not hold

[`gate1_preconditions.log`](gate1_preconditions.log)

The gate's first precondition was *"it is exactly the Flutter checkout used for
AFS2"*. **It is not, and the difference is recorded rather than smoothed over:**

    the commit ANDROID-FINAL-STACK-2 built from   7b253b2a  (made in a clone)
    the qualified checkout's HEAD                 5b180d22
    both parents                                  e64eb0af
    both trees                                    0c265f64   <- IDENTICAL

Flutter reads the *blob in the tree*; which commit object points at that tree is
metadata. So the source is byte-identical to what the physical qualification
built from, and this programme's own rule is to freeze tree objects rather than
ancestry. The delta from the parent is exactly one file and one line:
`bin/internal/engine.version`, `cd848320…` → `f85251f3…`.

Made durable with **no rebuild**: the commit was moved into the complete local
mirror from the runtime checkout (0 missing objects) and pushed from there — 6
commits — to `refs/heads/selfhost/3.44.8-v13-cell-f85251f3` and the annotated
tag `selfhost-flutter-cell-f85251f3`. Proven by a fresh **anonymous** fetch into
an empty repo with `HOME=/nonexistent`: both `5b180d22` and its parent resolve,
carrying tree `0c265f64` and `engine.version = f85251f3`.

## Gate 2 — the selector alone would not have helped

The CLI cloned Flutter from `shorebirdtech/flutter`, which does not carry our
selector — CLEANROOM-1 measured a clean bootstrap dying on `upload-pack: not our
ref`. So `shared.sh` now defaults to the fork that has it, with
`SHOREBIRD_FLUTTER_GIT_URL` still overriding for a local mirror.

Requalified, because this is a real product-tree change:

    cli_revision       5920a8bf -> 46ee70af
    bin_internal tree  67bb0a85 -> 8ae6081f
    flutter_selector   e64eb0af -> 5b180d22

The runtime checkout was advanced and re-bootstrapped, and reported
`Flutter • revision 5b180d22` / `Engine • revision f85251f3` — the clone-URL fix
proven end to end rather than asserted.

### The verifier repair, which is the load-bearing part

    record.flutter_selector -> blob AT THAT REVISION -> engine.version
                            -> record.cell_address

plus a check that the checkout's HEAD **is** the recorded selector. It formerly
read `HEAD:bin/internal/engine.version`, which pins nothing.

**Falsified against the exact state CLEANROOM-1 found** — recorded selector
`e64eb0af`, checkout HEAD `5b180d22`:

    repaired:  FAILED  engine.version at the RECORDED selector … artifact is cd848320…
    repaired:  FAILED  the Flutter checkout's HEAD IS the recorded selector
    old check: HEAD:bin/internal/engine.version = f85251f3  -> would have PASSED

## Gate 3 — the cell bytes, and the reason a rebuild is not an option

[`gate3_proof.log`](gate3_proof.log), [`cell_LAYOUT.txt`](cell_LAYOUT.txt),
[`cell_CELL.txt`](cell_CELL.txt)

Published as release `cell-f85251f3`: the 550,801,920 B bundle of the exact 30
member bytes, plus the descriptor, `LAYOUT.txt`, `MANIFEST.sha256` and
`CELL.txt`. **Not a rebuild** — the address is a digest over exact bytes and the
repository records the compiler archive as non-byte-reproducible, so a rebuild
is a different cell. Both digest sets ship because they differ for the three
members that embed the address: raw digests in `LAYOUT.txt` (what a download
must match), canonical-form digests in the descriptor (what the address is
computed over).

The integrity guarantee is the digests **committed in the record**, not a
promise from the host: a replaced asset stops matching `bundle_sha256` and stops
reconstructing the address. The proof checks the download against both the
digest shipped beside it and the one in `SUPPORTED_STATE.yaml`.

| proof | result |
|---|---|
| download into an empty directory, anonymously, no HOME | ✓ 528 MB |
| matches the digest shipped beside it **and** the one committed in the record | ✓ |
| descriptor recomputes to the address | ✓ |
| 30/30 members match their recorded raw bytes | ✓ |
| `verify_cell_members` against the hydrated overlay | **30/30** |
| serveable over plain HTTP from the reconstructed tree | 30/30 |
| identical to what the production CDN serves | 30/30 |
| **through a real Caddy CDN whose `/overlay` IS the reconstructed tree** | **30/30** |

Four negative controls, each refusing for the right reason:

| control | refusal |
|---|---|
| a missing `LAYOUT.txt` | *the distribution is incomplete* |
| one flipped bundle byte | *does not match MANIFEST.sha256* |
| another cell's descriptor | *recomputes to cd848320…, not f85251f3…* |
| **the local overlay Seatbelt-DENIED** | **still succeeds, 30/30** |

The last is the lane's whole point, and it asserts the denial first — so a pass
cannot come from an inert sandbox. The wrong-descriptor control regenerates
`MANIFEST.sha256` deliberately, so it cannot pass merely because the checksum
file disagreed.

**One step needed three attempts.** The intended form — a second Caddy over the
hydrated overlay — could not be reached through Docker's port mapping on this
host (compose builds never finished, `docker ps` stopped answering). It was
finally measured from *inside* the container, which exercises the same Caddy and
skips only Docker's port forwarding. The weaker 3a/3b forms are retained rather
than deleted.

## Gates 4 and 6 — bootstrap, and the ambient dependency

`bootstrap_selfhost.sh` constructs state instead of assuming it: resolve the
newest immutable tag, clone at it, read the record, create the runtime checkout
at `cli_revision`, download the cell from the **recorded** distribution and
check the bundle against the committed digest, hydrate 30/30, fetch the exact
selector and confirm its `engine.version` selects the recorded cell, derive
`SHOREBIRD_ROOT`, verify. Operator-supplied things are printed as `PREREQ` lines
rather than assumed.

`SHOREBIRD_ROOT` has **no machine-specific default**: environment, then
`.runtime_root` written by the bootstrap, then a failure naming both. Proven:
with neither present the verifier says *"no runtime checkout"* instead of
probing a path on this machine.

PyYAML is gone from the supported path. `lib/record_lint.py` is pure stdlib and
catches the two defects that actually happened here. Falsified four ways,
including the one that matters for false positives: a key repeated in
**different sibling mappings** is not flagged — the real record has six such
keys and lints clean — while the same key twice in **one** mapping is caught at
its line. When PyYAML is present a real load runs as an additional check, so
nothing is lost; it is simply never required.

## Two of my own faults, both caught by the cleanroom

**`selfhost-v1.1.0` carries a bootstrap that cannot complete.** It hydrated the
cell into `$ROOT/overlay`, while `verify_supported_state.sh` reads members from
the clone's `selfhost/cdn/overlay` and the CDN compose file mounts that same
directory. The first hostile run failed with *"no published compiler archive"*
and was right to. The tag is kept — refs are provenance — but must not be
pinned; `bootstrap_selfhost.sh` auto-discovers the **newest** `selfhost-v*`, so
an operator following the documented path does not land on it.

**`audit_route_b_compiler.sh` read a path on the qualification machine.** It
defaulted `OVERLAY` to `/Users/mendell/shorebird/selfhost/cdn/overlay`, so on any
other checkout it inspected a directory that does not exist and reported *"no
bundle published for this engine hash"* — while the bundle sat in the clone's own
overlay. The same defect class as the `SHOREBIRD_ROOT` default, and the last
hard-coded absolute path on the supported verifier path. Now derived from the
script's own location.

Both were found by the cleanroom rather than by me, which is the argument for
running it at all.

## What is NOT repaired, because it is a property

The cell is **distribution-only**. The address is a digest over exact bytes and
the compiler archive is non-byte-reproducible, so it can be distributed but never
re-derived. Recorded in `SUPPORTED_STATE.yaml` as
`cell_is_distribution_only: true` so nobody plans a "rebuild it" recovery path.

## Boundary

No cell minted, `f85251f3…` not rebuilt, no physical qualification rerun, no
Route B or compiler semantics touched, no Add-to-App, no language-capability
work.
