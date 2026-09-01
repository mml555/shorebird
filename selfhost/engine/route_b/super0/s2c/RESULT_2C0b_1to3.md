# 2C.0b steps 1–3 — isolated CLI, candidate Flutter pin, both remote-banked.

`~/.shorebird` untouched throughout. Nothing published, mapped, or released.

## 1 · Isolated candidate CLI

    path            /Volumes/build/route-b/shorebird-candidate   (9.0 G)
    CLI revision    e6e17095e434f2aeb88cfdf6d970bd440c0c6a38     (fixed, detached)
    remote          repointed to https://github.com/mml555/shorebird.git
                    (the copy inherited a LOCAL path remote; a candidate must
                    not depend on this machine's filesystem for provenance)
    shorebird.stamp removed, so it rebuilds its own snapshot on first run

`shorebirdRoot` derives from the running script's path, so this copy is a fully
independent installation with no environment variable involved.

**Source verified unchanged after the copy:**

    ~/.shorebird HEAD    207c4a7ac91f937ed39c08f3e3cc13d860cb612c   (unchanged)
    dirty                0 paths
    shorebird.stamp      167685e7c1b14c1e9e…                        (unchanged)

## 2 · Candidate Flutter revision

Inside the isolated cache, never in `~/.shorebird`:

    parent          a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    candidate       371005c93a7c927b34bbd727eb2c4951f0ef090d
    engine.version  a5a8be5854c529268378ce16762a16d6e31763e9   (was 4792f0ec…)

The pin is a lookup key derived from bytes this run actually built and measured,
not an invented token. The commit also carries `SHOREBIRD_2C_CANDIDATE.md`
recording the full chain — engine source, artifact sha1/sha256/size, and that
runtime semantics are intended unchanged while artifact identity is deliberately
distinct.

## 3 · Remote durability, verified independently

    remote   mml555/shorebird-flutter-mirror
    branch   route-b-2c-candidate
    tip      371005c93a7c927b34bbd727eb2c4951f0ef090d

Checked two ways, neither of them the push's own output: `git ls-remote`, and a
**fresh clone** of the branch whose `bin/internal/engine.version` reads back

    a5a8be5854c529268378ce16762a16d6e31763e9

So the Flutter pin is now as durable as the engine source, which is the rule the
added step 3 exists to enforce.

## The chain so far

    mml555/shorebird-flutter  route-b-2c-candidate  dfa2b24a   ← remote
            ↓ built
    iOS device slice  sha1 a5a8be58…  sha256 2fa8b808…  19,104,576 B
            ↓ pinned by
    mml555/shorebird-flutter-mirror  route-b-2c-candidate  371005c9  ← remote
            ↓ consumed by
    isolated CLI  e6e17095  at /Volumes/build/route-b/shorebird-candidate

Every arrow is measured, and every source end is independently retrievable.

## Still held

    engine artifacts under H     NEXT
    qualified cell under H       then
    experimental_hashes.map      LAST
    resolution preflight         then
    candidate release            then

## Ledger

    ~/.shorebird            207c4a7a…, 0 dirty, stamp unchanged
    published cell 4792     0696da541c2b9a9d…  unchanged
    compatibility.yaml      42a970f46a234794…  unchanged
    experimental map        7bdc97bf9ed27082…  unchanged
