<!-- cspell:words seatbelt sandboxed pubcache prebuilt armv canonicalization CLEANROOM cleanroom PREREQ -->

# SELFHOST-CLEANROOM-1 — the supported stack is NOT reproducible from durable sources

2026-09-04. **STOP AND REPORT.** Six productization defects, three of them hard
blockers. Nothing was copied from the qualification machine to make anything
pass — the sandbox could not have, and that is the point.

    CLEANROOM NOT REPRODUCIBLE
    operator prerequisites encountered   3
    productization defects               6   (3 hard blockers)
    SUPPORTED STATE VERIFIED             NO
    minimal release-side hydration       NOT REACHED — the CLI cannot bootstrap

Harness: [`../../scripts/cleanroom1.sh`](../../scripts/cleanroom1.sh). Run:
[`cleanroom_run.log`](cleanroom_run.log).

## The isolation is proven, not promised

A macOS Seatbelt profile ([`seatbelt_profile.sb`](seatbelt_profile.sb)) denies
`file-read*` on `/Volumes/build`, the development checkout, and every inherited
cache. Each denial is asserted **per path**, and the control that stops it being
vacuous is asserted too: those same paths **are** readable outside the sandbox,
so it is the kernel refusing and not the paths being absent.

    PASS  denied: /Volumes/build
    PASS  denied: /Users/mendell/shorebird
    PASS  denied: /Users/mendell/.shorebird
    PASS  denied: /Users/mendell/.pub-cache
    PASS  denied: /Users/mendell/.gradle
    PASS  5 of those paths ARE readable outside the sandbox, so the denial is what stops them

Plus a fresh `HOME` (asserted to be a different inode, with no `.shorebird`,
`.pub-cache` or `.gradle`) and `env -i` with a six-variable allowlist, dumped
into the log so the environment under test is on the record.

Two of my own mistakes here were themselves inherited state: the profile denied
the metadata lookup needed to *create* anything under the cleanroom's parent
volume, and the driver inherited a working directory inside the denied
checkout — `git` failed with *"Unable to read current working directory"*. An
inherited cwd is inherited state.

## What DID work

| | |
|---|---|
| both repositories clone **anonymously** | ✓ — no dependence on this machine's credential helper |
| the supported `cli_revision` is in the durable repo | ✓ |
| both engine producers are advertised by the durable engine repo | ✓ `f1a59b8a…` and `dfa2b24a…` |
| the cell **descriptor** is committed | ✓ — membership and all 30 digests are durable |
| `v2 manifest recomputes to the cell address` | ✓ **in the cleanroom** |
| the engine-producer durability checks | ✓ both pass in the cleanroom |

So the *identity* of the supported stack is durable. What is not durable is the
**bytes**.

## Defect 1 — no immutable ref names the current record

    CANDIDATE                                  REVISION       cell_address named there
    selfhost-v1.0.0                            32e14c710a82   <no record here>
    5920a8bf… (the record's own cli_revision)  5920a8bf0a99   cd848320…  (superseded)
    origin/experimental (tip)                  654e595daffc   f85251f3…  (current)

`CLAUDE.md` says releases are cut as `selfhost-vX.Y.Z` — *"the whole
distribution, the tag users pin"*. The newest such tag is from 2026-07-28 and
carries no supported-state record at all. Only the **mutable tip of a
non-default branch** describes the current stack.

Worth stating precisely: checking out `cli_revision` **rewinds the record
itself**, because the record lives in the same repository and has moved since.
That is two different identities wearing one field — the revision that carries
the record, and the revision the record pins for the product tree.

## Defect 2 — the 30 cell members exist nowhere durable *(hard blocker)*

    addressed members: 30   present in a fresh clone: 0   ABSENT: 30
    gitignore: .gitignore:30:selfhost/cdn/overlay/*

`selfhost/cdn/overlay/*` is gitignored, the repository publishes **no release
asset at all**, and the record names no location to fetch them from. The CDN
that serves them reads that same local directory, so it is not an independent
source — it is the local state wearing a different hat.

## Defect 3 — and they cannot be rebuilt instead *(hard blocker)*

The cell address is a digest over exact bytes, and the repository's own comment
says the Route B compiler archive is **`non-byte-reproducible`**. A rebuild
therefore yields a *different address*. So cell `f85251f3…` cannot be re-derived
from source; it can only be distributed as bytes — which turns Defect 2 from a
slow path into a hard blocker.

## Defect 4 — the supported Flutter selector is not fetchable *(hard blocker)*

    https://github.com/mml555/shorebird-flutter.git      not fetchable
    https://github.com/shorebirdtech/flutter.git         not fetchable
    https://github.com/flutter/flutter.git               not fetchable

And the consequence is not theoretical — the CLI bootstrap fails outright
([`cli_bootstrap_failure.log`](cli_bootstrap_failure.log)):

    Cloning into '…/bin/cache/flutter/e64eb0af…'
    fatal: remote error: upload-pack: not our ref e64eb0af52e1c43c3b21a39556d789538d0df9b3
    fatal: unable to read tree (e64eb0af…)

On the qualification machine that revision is cloned from
`file:///…/selfhost/cdn/mirrors/flutter.git` — 447 MB, gitignored, on
`refs/heads/selfhost/3.44.8-v13`. It is **our own commit** (author *Shorebird
selfhost*, 2026-09-02, *"candidate(6d): pin engine.version to the v13 cell
cd848320"*), never pushed. Same defect class as the engine producer that was
fixed this morning, and it stops everything downstream.

## Defect 5 — the record names a Flutter revision that selects the WRONG cell

[`flutter_revision_gap.log`](flutter_revision_gap.log). This one I own: it is a
consequence of my own promotion step earlier today.

    record flutter_selector        e64eb0af…   its engine.version -> cd848320…  SUPERSEDED
    runtime checkout HEAD          5b180d22…   its engine.version -> f85251f3…  SUPPORTED
    refs pointing at that HEAD     0
    present in the local mirror    NO — it exists only in the runtime checkout

The verifier's check *"Flutter engine.version (committed blob) selects the
recorded cell"* reads **HEAD's** blob, so it is satisfied by whatever HEAD
happens to carry the right bytes — it does not pin a revision. The supported
state therefore depends on an unrecorded, unpushed commit, and an operator who
cloned the **recorded** selector would select the superseded cell.

This is the same shape as two lessons already in this programme: ancestry is not
identity, and a branch is not provenance. Here, *HEAD is not an identity*.

## Defect 6 — the verifier's default root is a path on this machine

    the verifier's default SHOREBIRD_ROOT is: /Volumes/build/route-b/shorebird-candidate

An operator elsewhere must know to override it, and nothing in the record says
so.

## A misattribution the cleanroom exposed, and I fixed

The first run reported **`record is not cleanly machine-readable`** against a
record that is perfectly well-formed. Cause: the cleanroom's stock `python3` has
no PyYAML, so the checker could not run — and its inability was reported as a
defect *in the subject*. Verified directly: with a Python that has PyYAML,
`duplicate keys: none`.

`verify_supported_state.sh` now distinguishes three states — ok / **cannot
check, and why** / malformed. Both "cannot check" states still FAIL, because an
unchecked claim is not a verified one; they just no longer blame the record.
That is the mirror image of the vacuous-pass problem: a check that cannot run
must not produce a *misdirected* failure either.

## Operator prerequisites encountered

1. **Check out the exact revision that carries the record.** A bare
   `git clone` lands on `main`; the newest `selfhost-v*` tag is stale.
2. **Provide a runtime CLI checkout** (`SHOREBIRD_ROOT`) with a bootstrapped
   `bin/cache/flutter/<selector>` whose Flutter `engine.version` is committed to
   the supported cell. Undocumented.
3. **Install PyYAML.** The stock macOS `python3` has none.

Not reached, and therefore not inventoried: Xcode, the Android SDK/NDK, Docker
for the CDN, and JDK versions. The CLI bootstrap fails before any of them is
consulted, so listing them would be speculation rather than measurement.

## The acceptance criteria, answered plainly

| criterion | result |
|---|---|
| fresh environment reaches `SUPPORTED STATE VERIFIED` | **NO** — 9 failed checks, all traceable to defects 2–6 |
| minimal release-side hydration for both platforms | **NOT REACHED** — defect 4 stops the CLI before a build can start |
| every input traceable to a durable source | **NO** — the 30 cell members and the Flutter selector are local-only |

## The remedy, named but NOT applied

Per the lane's rule, a missing local-only dependency is a stop-and-report
defect. I did not push anything, publish anything, or relax any check to make
the run pass. The remedy each defect implies:

1. cut a `selfhost-vX.Y.Z` tag that carries the current record, and separate
   "the revision carrying the record" from `cli_revision`
2. publish the 30 cell members as durable, addressable objects (release assets
   or an object store), and record where
3. accept that the cell is distribution-only, and say so in the record — or make
   the compiler archive reproducible, which is a much larger change
4. push the Flutter selector branch to the durable engine fork
5. record the exact Flutter **revision** the supported cell depends on, push it,
   and make the verifier pin it rather than accept any HEAD
6. drop the machine-specific `SHOREBIRD_ROOT` default, or make it required

## Boundary

No physical device qualification was rerun. No cell or compiler semantics were
changed. No Add-to-App or language-coverage work. The two product changes made
are confined to the verifier's own self-checks: the three-state format check
described above, and `STATE` becoming overridable so those checks can be
falsified against a deliberately malformed copy.
