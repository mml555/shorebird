# D-SUPER-2C.0b · Step 4 — publish candidate engine under H

    H = a5a8be5854c529268378ce16762a16d6e31763e9

No rebuild. `selfhost/engine/publish_ios_overlay.sh` run with
`OUT=/Volumes/build/route-b/flutter/engine/src/out/ios_release`; the publisher
DERIVED the key from the device slice's own sha1 rather than being told it, and
landed on H.

## VERDICT — PASS on every authorized observable

Fetched through the actual serving path (`http://localhost:8085`, the rig's
canonical `FLUTTER_STORAGE_BASE_URL`), NOT by inspecting the overlay directory.

    path   /flutter_infra_release/flutter/<H>/ios-release/artifacts.zip
    slice  Flutter.xcframework/ios-arm64/Flutter.framework/Flutter

    sha1                    a5a8be5854c529268378ce16762a16d6e31763e9   MATCH
    sha256                  2fa8b808e863552f1ebf9ffaa8b460c299b16241d68cfb19689798534e555f58
                                                                       MATCH
    size                    19,104,576                                 MATCH
    candidate marker        1 occurrence                               MATCH
    updater af6e842ccf87    1 occurrence                               MATCH

Marker/updater counts are exact byte-substring counts over the served bytes,
not `strings | grep`.

## Certified key/artifact — UNCHANGED

    key     4792f0eca461f3761001a1adbe131b4b115e3684
    sha1    cc150ab64dbeef57be41fd7b1bd12bda5cb7e717   MATCH
    sha256  62bd2395005cc3150d504d05b7efd9d3a4f6c14fff728cde49637d9f7f4f801c
                                                        MATCH
    size    19,104,440                                  MATCH
    candidate marker                    0 occurrences — absent, as required
    artifacts.zip mtime                 Aug 27 16:46 (publish ran Aug 31 21:35)

## Ordering held

`H` is present in the overlay and ABSENT from `experimental_hashes.map`. The
map entry remains step 8. The CDN serves an unmapped hash's overlay files
fine, so verification-through-the-serving-path did NOT require the map entry —
there was no ordering conflict to resolve.

## TWO FINDINGS — neither affects the verdict above, both gate later steps

### F1 · `darwin-arm64/font-subset.zip` is NOT published for H

Published set for H vs the certified key:

    missing, MUST fix before step 8   darwin-arm64/font-subset.zip
    missing, expected (step 6)        route-b-compiler-darwin-arm64.zip
    missing, falls through by design  sky_engine.zip, flutter_gpu.zip,
                                      ios/artifacts.zip, ios-profile/artifacts.zip

`@must_be_local` (Caddyfile:165) owns `darwin-arm64/font-subset\.zip$` for ANY
mapped 40-hex hash. So the moment step 8 adds H to the map, that path becomes a
loud 404 — and the script header records the consequence: without OUR
`const_finder` there, the STOCK one wins and every release dies with
"Invalid SDK hash".

`sky_engine.zip`/`flutter_gpu.zip` are scoped per-cell in `@must_be_local_pkgs`
(Caddyfile:207) and H is not listed, so those correctly fall through to the
pinned revision. `ios/` and `ios-profile/` are not in either matcher — fine for
a release-only candidate.

This is exactly the order the Caddyfile itself states: "publish for a hash
FIRST, then protect it."

### F2 · ROOT CAUSE of F1 — the mirror's upstream passthrough is down

`publish_font_subset.sh` sourced OUR `const_finder` from H successfully, then
died fetching the stock font-subset binary. Every passthrough (non-overlay)
fetch currently returns 502:

    /flutter_infra_release/flutter/69f9831c.../darwin-arm64/font-subset.zip  502
    /flutter_infra_release/flutter/83675ed2.../darwin-arm64/font-subset.zip  502

Ruled out:
  * NOT sealed mode — the live mount is `upstream/enabled.caddy`, and a sealed
    refusal returns a `sealed:` body; this 502 has Content-Length 0.
  * NOT caused by today's publish — overlay hits still serve 200.
  * NOT a wrong URL — both the shorebird engine hash and the Flutter engine
    hash (`83675ed2...`, the one the certified publish used per the CDN access
    log of 2026-08-27) 502 identically.

`shorebird-cdn-artifact-proxy-1` is running (`/app/bin/server`, started
2026-08-30, 0 restarts, ~1s CPU) but is not answering, so Caddy's
`reverse_proxy artifact-proxy:8080` fails → 502.

Pre-existing rig state, not a property of H. NOT repaired in this lane: the CDN
stack is shared. It blocks F1, and it will block any release build against H
that needs a passthrough artifact.

---

## UPDATE — F2 REPAIRED (authorized narrow restart), 2026-09-01

Ran only:

    docker compose -f selfhost/cdn/docker-compose.cdn.yaml restart artifact-proxy

No `up --build`, no image rebuild, no Caddy restart, no volume changes.

    BEFORE                                    AFTER
    container e35efc5947c0                    e35efc5947c0   same (restarted, not recreated)
    image     sha256:0719c42487a8              sha256:0719c42487a8   same
    status    running                          running
    started   2026-08-30T18:48:07Z             2026-09-01T02:01:04Z
    restarts  0                                0

    passthrough probe   502  ->  404 (no longer 502)   PASS
    overlay H probe     200  ->  200                    PASS

The passthrough now ANSWERS. The residual 404 is not the outage: shorebird's
bucket genuinely does not carry `darwin-arm64/font-subset.zip` under its own
engine hashes, which is why both shorebird-hash URLs 404 with a real body while
the outage returned a bodyless 502 for everything.

### Step 7 source located and verified reachable

    /gcs/flutter_infra_release/flutter/83675ed2.../darwin-arm64/font-subset.zip
        HTTP 200, size 2,320,692

That is Google's own `flutter_infra_release` (the `/gcs/` prefix bypasses the
shorebird-bucket rewrite), at the FLUTTER engine hash — and the size matches
byte-for-byte the fetch recorded in the CDN access log of 2026-08-27, the run
that produced the certified cell's font-subset.zip. Same source, not a
substitute.

So step 7 must invoke the publisher with BOTH:

    --pinned 83675ed27633283e7fc296c8bca22e841224c096
    --mirror http://localhost:8085/gcs

The script's default `PINNED=69f9831c…` (a shorebird hash) can never work for
this artifact; that default is what made the earlier run fail once the outage
was out of the way.
