# 2C.0b — the engine.version discrepancy, explained. Neither A nor B as guessed.

## What it actually was

Not skip-worktree, not assume-unchanged, not a cache-management mechanism. **An
ordinary uncommitted working-tree edit**, which `git status` reports plainly:

    ~/.shorebird/bin/cache/flutter/a4a3c0d1…/

      HEAD                       a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
      HEAD:bin/internal/engine.version   69f9831c360d9152862ec3897c67fb09ae843f3b
      working file                       4792f0eca461f3761001a1adbe131b4b115e3684
      git ls-files -v                    H bin/internal/engine.version   (normal)
      git status --porcelain             " M bin/internal/engine.version"
      hidden index flags anywhere        none

So the file was simply modified and never committed. Nothing was hiding it.

## The mistake was mine, in the ledger

`RESULT_2C0b_1to3.md` reported

    source CLI dirty : 0 path(s)

directly above the `engine.version` lines, which reads as though the Flutter
checkout had been checked and found clean. **It had not.** That line was
`git status` on `~/.shorebird` — the *CLI repository* — while the
`engine.version` values came from the *Flutter cache checkouts*, which are
different repositories. Two measurements of two things, printed adjacently as
though they described one state.

The Flutter checkout's dirtiness was never measured until now. Presenting an
unmeasured cleanliness alongside a measured value is exactly the failure this
programme keeps banking, and it was caught by a reader comparing the remote
against the local claim rather than by the harness.

## The three values, stated separately as they should have been

    Git parent content
      a4a3c0d1  →  69f9831c360d9152862ec3897c67fb09ae843f3b

    effective pre-candidate local cache (UNCOMMITTED override)
      a4a3c0d1 working file  →  4792f0eca461f3761001a1adbe131b4b115e3684

    candidate Git revision
      371005c9  →  a5a8be5854c529268378ce16762a16d6e31763e9   = H

The candidate commit's diff against its parent is therefore
`69f9831c → H`, **not** `4792f0ec → H`. The `4792f0ec` value was never committed
anywhere; it existed only as a local edit.

Worth stating plainly: **the installed rig's cell resolution depended on an
uncommitted file.** That is fragile provenance independent of anything this lane
did, and it is recorded here rather than fixed, because `~/.shorebird` is not
this lane's to change.

## The candidate is unaffected, and now verified three ways

    candidate tracked tree vs its own commit    clean, 0 modified paths
    hidden index flags anywhere in the tree     none
    candidate HEAD vs a FRESH CLONE of 371005c9 identical commit

So the copied Flutter tree is not carrying any other inherited override, and the
tree the candidate CLI will use is exactly what the remote holds.

## Status

    isolated CLI                    PASS
    candidate Flutter remote        PASS
    candidate engine.version = H    PASS
    baseline provenance discrepancy RESOLVED — uncommitted edit, no mechanism
    no other hidden divergence      PASS

Ready for step 4: publish the already-built engine artifacts under H.
