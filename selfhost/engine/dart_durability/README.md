# DART-DURABILITY-1 (#47)

The producing Dart source for the frozen `selfhost-v1.1.1` cell existed on one
disk, reachable only through a clone whose `origin` was a `file://` path. The
tree that actually built the cell was not even a commit: it was a head commit
plus an uncommitted front-end guard, banked as a patch file. Lose the disk and
the cell becomes unreproducible.

This lane closes that, and nothing else. It is deliberately **not** part of
SEMANTIC-MAP-1's critical path and makes no claim about patchability, cost, or
supported state.

## The identity being preserved

| what | value |
| --- | --- |
| upstream Dart base (DEPS-pinned) | `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` |
| fork revision (head) | `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c` |
| head tree | `aa55ff960f07682fd098195e4884f2cbcb4f5f27` |
| **effective tree — what built the cell** | **`7b04b01bdc10ec990143257f0d28580571c2122f`** |

The effective tree is the head tree plus one uncommitted change to
`pkg/front_end/lib/src/source/source_loader.dart`. The tree hash is the
identity; the commit that carries it is just a container.

## The three scripts, and why there are three

Each one can prove something the others structurally cannot.

**`verify_lineage.sh <dart-git-dir>`** — the precondition. Does the banked
patch still reconstruct the effective tree, and is a one-byte mutation refused?
It reads a clone that already exists locally, so it cannot tell "durable" from
"present on this machine." Verdict: `RECONSTRUCTIBLE_BUT_NOT_DURABLE`. That
finding was correct when made and is not revised by what followed.

**`publish_lineage.sh <dart-git-dir> <owner/repo> [--execute]`** — the
publication. Writes the effective tree into the object database with a
temporary index and commits it with `commit-tree`; without `--execute` it
creates and pushes nothing. It runs inside the clone that already holds every
object, so it cannot prove fetchability either.

**`verify_durable.sh <owner/repo>`** — the acceptance criterion. Clones from
the network into a scratch directory with the global git config discarded,
terminal prompting off, askpass stubbed, `--no-local`, and a throwaway `HOME`,
then asks whether the effective tree resolves *there*. A clone that quietly
used the operator's token would prove the repo is reachable *by this operator*,
which is not the claim.

## What is published

`https://github.com/mml555/dart-sdk-shorebird-lineage` (public)

- annotated tag `route-b-producing-source-selfhost-v1.1.1`
- branch `provenance/route-b-selfhost-v1.1.1`, protected: force-push and
  deletion disabled, enforced for admins

Nothing is added to the tree — no README, no notice file, no provenance stamp.
Any addition changes the tree hash, and the tree hash is the whole point.
Attribution therefore lives in the commit and tag *messages*, which are outside
the tree. Dart's `LICENSE`, `AUTHORS` and `PATENT_GRANT` travel with the tree
unmodified because the tree is unmodified.

`evidence/published_ref.json` records what was actually pushed.

## Two things that are not clean, stated rather than buried

**The published commit is not the deterministic one.** The first `--execute`
run built the provenance commit under the ambient identity and clock, so its
hash was a function of when it ran. The script now pins author, committer and
date to the recorded revision's committer date, making the commit re-derivable
as `3bcdeb3e` anywhere. The published ref (`5f37e75f`) was **not** rewritten to
match: replacing it needs a force-push onto a branch whose purpose is to refuse
one. Both commits carry tree `7b04b01b`, which is the identity #47 turns on, so
the published ref satisfies the requirement and the determinism fix applies to
any future publication.

**The force-push control was not exercised.** `verify_durable.sh` proves an
anonymous push is refused and an authenticated non-fast-forward rewind is
refused, but an ordinary non-fast-forward is refused with or without
protection, so neither isolates branch protection. The force-push variant —
which protection alone can stop — was not attempted, because this environment
blocks force-pushes outright. Protection therefore rests on the configuration
as the GitHub API reports it, and the transcript says so instead of implying
more.

## Re-running

`publish_lineage.sh --execute` is idempotent: if the remote already carries the
recorded ref it pushes nothing, and if the remote carries something *else* it
refuses rather than moving a published provenance ref.
