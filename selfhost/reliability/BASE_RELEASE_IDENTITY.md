# The investigation base release — identity, banked once

Banked before patch rotation begins, so every later run can be tied to a base
installation that is never re-cut. **Leave this installation alone while rotating
patches.**

## Identities

    app                  firstactivation-probe  235a9d93-ef97-6372-d78a-ce88f798a726
    release              1.3.0+1                server id 138
    published xcarchive  88bd19eeef3ebf659fa1fdfb4814930a0e50df9766caa0a47c158048bf2a11b2
                         fetched from the control plane, HTTP 200, 11,091,913 bytes

    cell                 4792f0eca461f3761001a1adbe131b4b115e3684
    engine source        619fdad176ff457331b50230b9511e7230a6ed93   mml555/shorebird-flutter
    updater source       af6e842ccf87a083d1598b1e7c9e0868c5731931   mml555/shorebird-updater-mirror
    updater wire         af6e842ccf87                               present in the shipped bytes

## How the shipped engine is tied to the cell — and why not by raw bytes

An app-embedded `Flutter.framework/Flutter` is **not** byte-equal to the cell's
published engine, and it does not become equal by stripping the signature:

    embedded, as shipped        fa84b532d97ef991…
    embedded, sig stripped      89bae84ff786752a…
    cell published              62bd2395005cc315…
    cell, sig stripped          62bd2395005cc315…   (unchanged: never signed)

`codesign --remove-signature` does not fully normalise a Mach-O — the signature
load command and `__LINKEDIT` padding survive — so equality after stripping is
the wrong test here. It IS the right test for the case it was established for:
two app bundles built from ONE build, compared on their AOT payload
(`selfhost/scripts/make_track_clients.sh`).

The identity that does hold, and is stronger than a digest of re-signed bytes:

| property | embedded | cell | |
|---|---|---|---|
| `LC_UUID` | `4C4C440D-5555-3144-A180-FDDC512EAE1E` | same | **IDENTICAL** |
| size | 19,104,440 | 19,104,440 | same |
| arch | arm64 | arm64 | same |
| `af6e842ccf87` | present | present | |
| `Preparing next boot` | present | present | |
| `Next boot candidate rejected` | present | present | |
| `f729f958e9be` | absent | absent | |

`LC_UUID` is emitted by the linker over the linked image, so an identical UUID
means the **same linked binary** — re-signing and embedding do not change it. This
project already relies on that property from the other direction: cloned bundles
sharing an `LC_UUID` broke local-network permission attribution for the whole
set (`selfhost/scripts/set_macho_uuid.py`).

So the chain is: the producer gate verified the *cached* engine byte-identical to
the published cell at release time; the guard re-verifies that at every `arm`;
and the shipped app carries the same linked image by `LC_UUID`.

## The rule this establishes

> To tie an **app-embedded** framework to a published engine, compare `LC_UUID`
> (plus size, arch and revision strings). Raw or signature-stripped byte equality
> is the wrong test — Xcode re-signs on embed and stripping does not normalise
> the Mach-O. To tie a **cached** engine to a published one, compare bytes: that
> path is unsigned on both sides and byte equality holds exactly.
