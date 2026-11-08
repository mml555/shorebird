# D-SUPER-2C.1 · CLI-F3 / RELEASE-141 — Gate A PASS, Gate B STOP

    CLI4 = fb7ab8735e3020059a02d43a675ae3b0fa7e00c1   pin -> F3
    F3   = ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e   engine.version -> H3

No release 141. Releases 139/140, F2, H2, F3, H3 and archive `39ad75dd…` all
unchanged. No manual precache was performed for certification.

## GATE A — PASS

    banked predecessor   CLI3 6f97de7e7bd97355de517fb63a9c2f9b6a0f2243
                         tracked flutter.version 8427e3da… (F2)
                         clean, 0 hidden index flags
                         snapshot 93b6a30960bd8015140da201485cc97ffa7e557e681cf39cc6501c620cc39675

    CLI4                 fb7ab8735e3020059a02d43a675ae3b0fa7e00c1
                         parent 6f97de7e…  == CLI3
                         tracked flutter.version ab29aee0… == F3
                         clean

    git diff CLI3..CLI4
      bin/internal/flutter.version | 2 +-
      -8427e3da6174007d2f654972a014671d09d64468
      +ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e

Exactly one tracked file, one line. Banked at
`mml555/shorebird refs/heads/route-b-2c-cli-h3` and verified from a FRESH bare
fetch: correct parent, correct pin, one changed file.

### The default path selects F3 and H3 with no override

The F3 checkout was DELETED first, so this is not a primed cache:

    Updating Flutter...
    Cloning into .../bin/cache/flutter/ab29aee0...
    HEAD             ab29aee0598b5a0d63cdfca1ddbe153ab8a5265e   == F3
    engine.version   d4c0dbc2905286eb4537d5f9a7802693096ca1fd   == H3
    engine.stamp     d4c0dbc2905286eb4537d5f9a7802693096ca1fd

No `--flutter-version`, no manual precache. Gate A's four requirements hold.

## GATE B — STOP. The pinned path cannot complete either.

    shorebird release ios --no-codesign        (CLI4, pin F3, no overrides)

    COHERENCE_UNDETERMINABLE:
      .../flutter/ab29aee0.../bin/cache/artifacts/engine/ios/gen_snapshot_arm64 is missing
      ... ios-profile/gen_snapshot_arm64 is missing
      ... ios-release/gen_snapshot_arm64 is missing
      ... ios/…/Flutter.framework/Flutter is missing, so the ios engine identity
          was not established. An absent engine is not a matching one
      ... ios-profile/… missing
      ... ios-release/… missing
    Refusing to build.
    EXIT=78

The checkout has the Dart SDK — the bootstrap log shows only
"Downloading Darwin arm64 Dart SDK from Flutter engine d4c0dbc2…", which is why
`engine.stamp` is H3 — but NO iOS engine artifacts.

### Why no product path fills them, measured

Three behaviours interact:

1. The shell bootstrap clones the pinned Flutter and fetches the DART SDK only.
2. `installRevision` (`shorebird_flutter.dart:58`) is
   `if (targetDirectory.existsSync()) return;` — the bootstrap just created that
   directory, so its precache NEVER runs.
3. Shorebird's coherence gate requires the iOS engine present BEFORE any build,
   so Flutter's normal lazy download at build time never happens.

And when `installRevision` DOES run (fresh `--flutter-version`), its
`precacheArgs` is `['--android', if (isMacOS) '--ios']`
(`shorebird_flutter.dart:41`), and `android-arm64-release/` is owned by the
GLOBAL `@must_be_local` matcher — so a mapped iOS-only cell hard-404s, which is
the Gate 3 finding.

There is also no supported populate command: `shorebird cache` offers only
`clean`, `shorebird flutter versions` only `list`, and `installRevision` is
reachable solely from `release` and `patch`.

So `flutter precache --ios` is currently the ONLY way to populate an iOS-only
cell's engine artifacts, and it is not a Shorebird command.

## The contradiction I must surface rather than resolve myself

The ruling moved to the pin specifically to remove the undocumented
`precache --ios` prerequisite. Measurement shows pinning does NOT remove it:
the pinned path needs those artifacts too and has no way to obtain them.

Also worth recording plainly: **release 140 had the same dependency.** F2's
checkout was populated by a manual `flutter precache --ios` during
H2-RESOLUTION. So this prerequisite is pre-existing and is not introduced by
F3, H3, or CLI4 — but it means "the normal pinned workflow" cannot be claimed
today without either the manual step the ruling rejected, or a product fix.

I did NOT precache, because doing so would produce exactly the weaker claim the
ruling refused: "H3 works on a specially prepared rig."

## The minimal product fix, if that is the chosen route

Two one-line-ish changes, both in `shorebird_flutter.dart`:

    a) precacheArgs should be scoped to the release's platform rather than
       always including --android. An iOS release does not need Android
       artifacts, and demanding them makes any mapped iOS-only cell unusable.

    b) installRevision should not early-return on directory existence alone.
       The directory existing is not the same claim as the engine artifacts
       being present — the same absent-vs-established distinction the coherence
       gate itself already makes ("An absent engine is not a matching one").

With (a) and (b), the pinned path would materialize its own iOS engine and
release 141 could be cut with no manual preparation at all.

## State

    Gate A            PASS — CLI4 minted, banked, verified; default path
                      selects F3 -> H3 with no override
    Gate B            BLOCKED — coherence refuses; no product path populates
                      the iOS engine for a new cell
    Gate C            NOT REACHED — no execution claim made
    release 141       DOES NOT EXIST
    precache defect   OPEN, and now known to block the PINNED path too, not
                      only --flutter-version

App version is staged at `1.0.2+3` for the eventual release; nothing was
published.
