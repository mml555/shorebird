# D-SUPER-2C.0b · Resolution preflight

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## VERDICT

    1  candidate Flutter HEAD / tracked engine.version   PASS
    2  CLI resolved engine = H                           PASS
    3  served engine bytes consumed by the CLI           BLOCKED
    4  CLI resolved compiler cell = H                    NOT REACHED

    candidate release cut                                BLOCKED (fail closed)

## Banked before execution

    candidate CLI HEAD (before)   e6e17095e434f2aeb88cfdf6d970bd440c0c6a38
    candidate CLI HEAD (after)    f864f6c667397ecba26750a029c03db7620834b3
    candidate CLI dirty           0
    CLI snapshot sha256           93bb33031caee66e9ec15ebc948ef1627408f53ef9f40d9a8a23bf61fcb797dc
    FLUTTER_STORAGE_BASE_URL      http://localhost:8085
    SHOREBIRD_STORAGE_BASE_URL    http://localhost:8085
    SHOREBIRD_STORAGE_BUCKET      download.shorebird.dev
    SHOREBIRD_FLUTTER_GIT_URL     file:///Users/mendell/shorebird/selfhost/cdn/mirrors/flutter.git

`~/.shorebird` untouched throughout.

## FINDING 1 — the CLI RESETS the Flutter checkout. A tracked commit is not enough.

The ruling's approach — check out 371005c9 in the isolated Flutter cache — does
not survive contact with the CLI. `shorebird doctor` moved it straight back:

    reflog: checkout: moving from 371005c9… to a4a3c0d1…

The CLI enforces its OWN tracked pin, `bin/internal/flutter.version`, and
discards whatever that checkout's HEAD was. That pin read `a4a3c0d1`, whose
tracked `engine.version` is the stock `69f9831c`. So with the old pin the CLI
could never resolve the 2C candidate engine, no matter what the Flutter working
tree said — and any hand-set `engine.version` would have been silently reverted,
which is precisely the uncommitted-pin defect this lane is avoiding.

Nothing was lost: `371005c9` still existed as a commit and the tree stayed clean.

### Fix — one tracked line, on the CLI side

    shorebird-candidate  bin/internal/flutter.version
      a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
      -> 371005c93a7c927b34bbd727eb2c4951f0ef090d      (committed, f864f6c6)

Now the engine revision is a TRACKED value on both sides: the CLI tracks the
Flutter commit, and that Flutter commit tracks `engine.version = H`.

### Sub-finding — the clone URL

The first retry failed with `upload-pack: not our ref 371005c9`. The CLI defaults
to `https://github.com/shorebirdtech/flutter.git`
(`shorebird_flutter.dart:38`) and only uses the local mirror when
`SHOREBIRD_FLUTTER_GIT_URL` is set. Upstream has never heard of our candidate
commit. The partial checkout it left behind was removed and the resolution
re-run with the mirror; `371005c9` was first fetched into
`selfhost/cdn/mirrors/flutter.git` from the remote bank
(`mml555/shorebird-flutter-mirror refs/heads/route-b-2c-candidate`).

## 1 — candidate Flutter identity  PASS

Produced BY THE CLI's own checkout, not by hand:

    HEAD                       371005c93a7c927b34bbd727eb2c4951f0ef090d
    dirty paths                0
    engine.version worktree    a5a8be5854c529268378ce16762a16d6e31763e9
    engine.version TRACKED     a5a8be5854c529268378ce16762a16d6e31763e9

## 2 — CLI resolves engine H  PASS

From the resolver's own request, not from `cat`:

    http://localhost:8085/flutter_infra_release/flutter/
        a5a8be5854c529268378ce16762a16d6e31763e9/ios/artifacts.zip

The CLI selected H as the engine revision and addressed the mirror with it.

## 3 — BLOCKED. H owns only ONE of the three iOS engine modes.

`flutter precache --ios` aborts on the FIRST sub-artifact, the debug engine:

    Failed to download …/a5a8be58…/ios/artifacts.zip
    Exception: 504

Nothing reached the engine cache — `artifacts/engine/` is empty — so there are
no consumed bytes to verify, and item 3 cannot be answered honestly.

Root cause, measured:

    overlay 4792f0ec (certified)   ios   ios-profile   ios-release
    overlay a5a8be58 (candidate)                       ios-release

The candidate built only `out/ios_release`. `ios/` and `ios-profile/` are
therefore unowned under H and fall through to upstream — and the fallback cannot
deliver them. The mirror's cache handler has a hard ~10 s deadline:

    followed redirect: HTTP 504, 21-byte body, time=10.005 s

Reproduced on three attempts and with a 900 s client timeout, so this is the
gateway's deadline, not client patience. The same 504 also made the step 8
part-3 fallback probe vacuous, and it is the same class of failure recorded on
2026-08-28 (`Souin; fwd=bypass; detail=DEADLINE-EXCEEDED`).

This is why the certified cell works and the candidate does not: 4792f0ec owns
all three modes locally and never needs the slow path.

The audit does not catch it because `ios/` and `ios-profile/` are not in the
macos-ios required set — the policy assumes fallback works for them. For a large
artifact through this mirror, it does not.

## 4 — NOT REACHED

Cell resolution happens on the patch path, which needs a release, which item 3
blocks. The cell's SERVED identity is already proven independently in step 6 and
step 8 (`9d4ace27…9c59`, capability true from the served archive), but that is
not the same claim as "the CLI resolved and consumed it", so it is NOT counted.

## Fail closed

Per the ruling, the release cut is blocked. Not because anything disagreed about
H — everything that resolved, resolved to H — but because resolution cannot
complete.

## Recommended next lane, NOT started

Build the iOS debug and profile modes from the candidate tree and publish them
under H. Tooling already exists:

    selfhost/engine/route_b/build_ios_debug_profile.sh
    selfhost/engine/route_b/package_ios_mode_artifacts.sh

This is the same principle sky_engine just vindicated: own the bytes per hash
rather than trusting a fall-through. Copying 4792f0ec's ios/ios-profile is NOT
an option — `mint_route_b_cell.sh` forbids copying artifacts between engine
hashes, and that is exactly the foreign-artifact defect recorded in
`EPOCH_CROSSING_STOP.md`.

The alternative — raising the mirror's fetch deadline — is a CDN config change
that would make releases depend on a slow upstream path at build time, and it
does not give H artifacts that are actually its own.
