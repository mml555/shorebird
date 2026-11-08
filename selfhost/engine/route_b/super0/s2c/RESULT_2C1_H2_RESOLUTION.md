# D-SUPER-2C.1 · H2-RESOLUTION — tracked chain, empty-cache resolution, build PASS

    CLI2 = 50e472a6d8071fb508fd8f6313c3b0918976dbc3
     ->   F2   = 8427e3da6174007d2f654972a014671d09d64468
     ->   H2   = 64ff9f592ae319eea04db6092b71319d4778b873
     ->   map    69f9831c360d9152862ec3897c67fb09ae843f3b

No uncommitted cache edits anywhere. `371005c9` untouched — it permanently
records the old H relationship.

## 1. F2 — the successor Flutter pin

    parent                    371005c93a7c927b34bbd727eb2c4951f0ef090d
    tracked engine.version    64ff9f592ae319eea04db6092b71319d4778b873
    status                    clean, 0 hidden index flags

Banked at `mml555/shorebird-flutter-mirror refs/heads/route-b-2c-h2` and fetched
into `selfhost/cdn/mirrors/flutter.git`. Verified NOT from the working copy: the
object was fetched into a fresh bare repo and its tracked `engine.version` read
back as H2.

## 2. CLI2 — the successor CLI pin

    parent                     f864f6c667397ecba26750a029c03db7620834b3
    tracked flutter.version    8427e3da6174007d2f654972a014671d09d64468
    status                     clean, 0 hidden index flags

Banked at `mml555/shorebird refs/heads/route-b-2c-candidate-cli-h2`, verified the
same way from a fresh bare fetch.

## 3. Empty-cache resolution — the CLI did it, not me

The F2 cache path did not exist beforehand. `shorebird doctor` CLONED it:

    Cloning into .../bin/cache/flutter/8427e3da…

    CLI-produced Flutter HEAD    8427e3da…  == F2
    status                       clean
    engine.version worktree      64ff9f59…  == H2
    engine.version TRACKED       64ff9f59…  == H2
    engine.stamp after precache  64ff9f59…  == H2

`flutter precache --ios` completed from an empty engine cache.

### Consumed BYTES, not stamps or URLs

All three iOS archives compared file-by-file against the H2 manifest archives
(the cache stores them expanded, so content is the honest comparison):

    ios-release   27 files, 0 mismatched
    ios          27 files, 0 mismatched
    ios-profile   27 files, 0 mismatched

    device Flutter sha1     a5a8be5854c529268378ce16762a16d6e31763e9
    candidate marker        1
    updater af6e842ccf87    1
    const_finder            3ebd1f3b9355ea419cd80d7afa3dbfa491cb998956ce1998c8896ef7a5a3380f
    product platform dill   9e8c898a4d
    debug   platform dill   9e8c898a4d

The device Flutter SHA1 is H, not H2, and that is correct: H2 is the v2
WHOLE-CELL address, not a Flutter binary digest. The engine bytes were never the
defect and were carried into H2 unchanged.

## 4. LOCAL CANONICAL B BUILD — the previous STOP is regressed

    flutter build ipa --release --no-codesign      EXIT=0
    "Can't load Kernel binary: Invalid SDK hash"   0 occurrences
    "aot_assembly_release failed"                  0 occurrences
    Built build/ios/archive/Runner.xcarchive (28.7MB)

So the causal story is closed end to end:

    identical app + H  host set  -> Invalid SDK hash
    identical app + H2 host set  -> successful archive

### And it is genuinely the canonical B fixture, not merely "some IPA"

    bundle id   dev.shorebird.selfhost.superFixture

    App.framework sentinels
        TICKER:                    3
        WRAP:                      1
        LEAF:                      1
        APP-STATE                  4
        RELEASE (unpatched)        1
        PATCHED narrow-v1 super    1
        WRONG - virtual dispatch   1

    Flutter.framework
        candidate marker           1
        updater af6e842ccf87       1

`BASE:` is 0, and that is CORRECT rather than a missing sentinel: `Leaf`
overrides `close()` and `target()` exact-calls `super.close()` = `Ticker.close()`,
so `Base.close()` is unreachable and TFA drops it. The three strings the device
run must distinguish are all present, and the shipped engine carries the
candidate marker.

## Not yet claimed

    release                        DOES NOT EXIST
    provenance.engineRevision      NOT CLAIMED
    route-b-compiler H2 consumed   NOT CLAIMED — a patch-path observable
