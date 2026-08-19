# Commit and PR hygiene

Written 2026-08-18, after retro-splitting 611 commits and 3.8M lines into
reviewable PRs. **The point of this file is that we never do that again.**

## The rules that would have prevented the mess

### 1. Never commit a vendored copy of something we can fetch

`vendor/flutter` was 15,724 files and ~3.7M lines — 98% of our tracked file
count, and the sole reason the fork was unreviewable. It existed for bootstrap
durability, which a bare mirror and an offsite remote already provided.

**Before adding a vendored tree, ask: can this be a git remote, a submodule, or a
mirror instead?** If it must be vendored, it needs a written reason and a note
about what else already covers that need.

`vendor/updater` stays: 221 files we actually build and ship.

### 2. Engine and SDK changes live on BRANCHES, not in `.patch` files

Route B's engine work lived as uncommitted edits on detached HEADs plus 13
hand-maintained `.patch` files. That gave no conflict signal, no bisect, and no
offsite copy — `git apply` either worked or exploded, with no middle ground.

Now:

    Flutter    mml555/shorebird-flutter @ route-b
    Dart SDK   local route-b (base 6b58bb3a, unshallowed to 121,349 commits)

`.patch` files are GENERATED ARTIFACTS for reproducibility. The branch is the
source of truth. A Flutter bump is then a rebase with per-file conflicts —
measured at 5 conflicts across 39 files and ~3,350 upstream commits.

### 3. PR size targets

| content | target |
|---|---|
| **code** | **1-2 files** ideally; 5-8 hard ceiling |
| tests | ship WITH the code they test, same PR |
| shell tooling | grouped by function is fine |
| docs | any size — prose reviews fast |
| evidence / artifacts | any size — data, not logic |

A 20-file code PR is not reviewed. It is approved.

### 4. Use stacked PRs when dependencies force order

Dart modules that import each other cannot each stand alone. Stack them: each PR
based on its predecessor, so its diff shows ONLY its own files.

State the honest limit in the PR body: early PRs in a stack compile standalone,
later ones do not until their base merges. Do not claim otherwise.

Worked example — the Route B core, split into 10 PRs of 2 files:

    layer 0 (no deps)   route_b, container, build_config, capabilities, compiler
    layer 1             compiler_cache<-compiler, coverage<-compiler,
                        provenance<-build_config
    layer 2             release_kernels, producer

### 5. Split by WHAT IT ADDS, not by file path

A PR title should say what the system can now do. "feat(cli): detect whether an
iOS engine can run Route B patches" beats "add route_b.dart".

### 6. Verify a split reconstructs the original

After splitting, prove nothing was lost:

    git rev-parse <stack-tip>^{tree}   ==   git rev-parse <original>^{tree}

or compare file sets. This caught a real bug during the retro-split: an
over-greedy exclusion pattern silently dropped `android_patcher.dart`,
`macos_patcher.dart` and three more. **Always check.**

### 7. Commit messages carry the WHY

The repo's convention, and it earns its keep: state what changed, what it does
NOT claim, and what was checked rather than assumed. Semantic prefix required
(`feat`/`fix`/`chore`/`docs`/`test`/`probe`) — CI enforces it on PR titles.

If a conclusion is later invalidated by a collapsed premise, **supersede the
conclusion and preserve the evidence** — add a header, do not delete or rewrite.
See `selfhost/evidence/g15/gate5_armA_fold_refuted.txt`.

### 8. Check committed state before writing a corrective edit

This repo runs parallel sessions. Another lane may have already recorded the
correction. `git show <sha>:<path>` before editing.

## Branch layout

    main                     reviewed, merged work
    experimental             ALL improvements, unsplit — the integration branch
    <type>/<topic>           PR branches, independent from main
    rb01..rb10, cw01..cw05   stacked PR chains (each based on its predecessor)

Work happens on `experimental`. PRs are carved from it, not the reverse.

## Traps this rig has, that cost real time

* `depot_tools` installs `vpython3` git hooks that block commit AND push in the
  engine trees. Use `git -c core.hooksPath=/dev/null`.
* A stale zero-byte `.git/index.lock` blocks commits silently. Check for a live
  git process first, then remove it.
* `git fetch --unshallow` does NOT resolve a graft whose base is not an ancestor
  of any fetched branch, and unshallowing by SHA returns HTTP 500 from
  googlesource. Bulk-fetch, verify the base's parent object is present locally,
  then drop `.git/shallow` and confirm with `git fsck --connectivity-only`.
* This repo's hooks block `git stash`, `git clean` and forced pushes. They are
  right to. Use `git worktree add`, or build commits with plumbing (`read-tree`
  + `update-index --index-info` + `commit-tree`), which touches no working tree
  at all.
