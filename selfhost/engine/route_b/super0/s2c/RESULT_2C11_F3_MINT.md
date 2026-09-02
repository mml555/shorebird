# D-SUPER-2C.1 · F3-MINT — selector minted, F2→H2 vs F3→H3 proven

    F2 = 8427e3da6174007d2f654972a014671d09d64468   engine.version H2
    F3 = ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e   engine.version H3

No release 141. Releases 139/140 untouched. H2 and H3 both unchanged and clean.

## Gate 1 — exact Flutter delta

    F2 banked   commit 8427e3da…  tree c5934645298cc1eb81f4cd8043a74d8b61de41de
                engine.version 64ff9f59…  clean, 0 hidden index flags
                parent 371005c9…

    F3          commit ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e
                parent 8427e3da…  == F2
                engine.version d4c0dbc2…  == H3
                clean

    git diff F2..F3
      bin/internal/engine.version | 2 +-
      1 file changed, 1 insertion(+), 1 deletion(-)
      -64ff9f592ae319eea04db6092b71319d4778b873
      +d4c0dbc2905286eb4537d5f9a7802693096ca1fd

Exactly one tracked file, one line. Nothing else moved.

## Gate 2 — remote durability, verified independently

Pushed to `mml555/shorebird-flutter-mirror refs/heads/route-b-2c-h3` and fetched
into a FRESH bare repo, so nothing is read from the working copy:

    object type     commit
    engine.version  d4c0dbc2905286eb4537d5f9a7802693096ca1fd
    parent          8427e3da6174007d2f654972a014671d09d64468
    changed files   bin/internal/engine.version   (count 1)
    ls-remote       ab29aee0…  refs/heads/route-b-2c-h3

## A MISTAKE I MADE AND CORRECTED

F3 was committed INSIDE the directory named for F2
(`bin/cache/flutter/8427e3da…`), which moved that directory's HEAD to F3. The
F2 COMMIT was never altered — it is immutable and is F3's parent — but the
first real selection attempt then read `engine.version` from that directory and
refused:

    ENGINE_ARTIFACTS_STALE: engine.stamp is 64ff9f59… but engine.version is d4c0dbc2…

That looked like a coherence finding about H3 and was not: it was my own stale
directory. Restored with `git checkout F2`; the directory is F2 again, clean,
and `engine.version == engine.stamp == H2`. This is exactly the stale-cache
ambiguity the ruling told me to eliminate, and it did produce a misleading
reading before I caught it.

## Gate 3 — real CLI selection, no release

Through the actual `shorebird release ios --flutter-version <F3>`:

    Installing Flutter null (ab29aee059)…   Done
    installed dir  bin/cache/flutter/ab29aee0…
    HEAD           ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e   == F3
    engine.version d4c0dbc2905286eb4537d5f9a7802693096ca1fd   == H3

The checkout was removed beforehand, so this is a genuine fresh install, not a
primed cache. "Flutter null" is cosmetic — `getVersionForRevision` finds no
release tag for a candidate commit.

### A REAL BLOCKER FOUND IN THE NORMAL WORKFLOW

`installRevision` then failed:

    Failed to precache Flutter null
    /…/flutter/8427e3da…/bin/flutter precache --android --ios  (cwd = F3 dir)
    Failed to download …/flutter/64ff9f59…/android-arm64-release/darwin-x64.zip
    Exception: 404

Two facts, both measured:

1. `installRevision` precaches with the CLI-PINNED flutter binary (F2's), not
   the revision being installed — hence the H2 URL while installing F3.
2. `precacheArgs` is `--android --ios`, and `android-arm64-release/` is in the
   GLOBAL `@must_be_local` matcher. A mapped macos-ios cell owns no Android
   bytes, so that path hard-404s by design.

So the fresh-install path cannot complete on this rig for ANY iOS-only cell —
it would equally block `--flutter-version F2`. Release 140 escaped it only
because F2's directory already existed and `installRevision` returns early.

This CORRECTS my Gate 1 recommendation: `--flutter-version` selects correctly,
but its install step is blocked here. It is not H3-specific and not a defect in
H3.

Worked around WITHOUT changing any product or policy: the F3 checkout already
existed from the failed attempt, so `flutter precache --ios` was run in it
directly (exit 0, `engine.stamp` = H3). Declared here rather than hidden.

## Gate 4 — chained resolver proof, real workflow

`shorebird release ios --no-codesign --flutter-version <F3>`, H3 compiler cache
emptied first:

    no "Installing" line        installRevision returned early
    no coherence refusal        engine.version == engine.stamp == H3
    Downloading Route B compiler for engine d4c0dbc2…   Done
    refused: existing ios release for version 1.0.1+2   -> NO release 141

    consumed archive   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    analyzer in cell   18862acd7de2af6381205064a7290b5fb67a6b9c707eabad8d645cff04c4eccb
    producer lineage   a5a8be5854c529268378ce16762a16d6e31763e9

### SELECTOR SENSITIVITY CONTROL — the same command with F2

    Downloading Route B compiler for engine 64ff9f59…   Done
    consumed archive   9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
    analyzer in cell   799a0796c4d20596c40d9742c662ad1644aa1c39485181591d42d51c1f537236

One argument changed, and the whole chain moved:

    F3 -> H3 -> 39ad75dd…/18862acd…
    F2 -> H2 -> 9d4ace27…/799a0796…

Same CLI, same app, same command. That is the selection distinction the ruling
asked for, mechanically demonstrated rather than logged.

## Not claimed

The compiler was RESOLVED and its archive downloaded and validated by the real
release workflow, but no release was created, so nothing yet proves the release
EXECUTED it to completion. That is the next claim.

## Recommendation carried forward

Because the fresh-install precache path is blocked on this rig, the cleanest
route to the first H3 release is one of:

  a) keep `--flutter-version <F3>` and accept the one-time
     `flutter precache --ios` priming of the F3 checkout, declared in evidence
     (what was done here); or
  b) move the CLI pin to F3, which is how F2 was materialized and which avoids
     `installRevision` entirely.

(b) mints one more artifact but needs no manual priming; (a) mints nothing but
requires a declared manual step. Bringing the choice back rather than assuming.
