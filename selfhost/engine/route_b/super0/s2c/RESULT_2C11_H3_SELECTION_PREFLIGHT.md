# D-SUPER-2C.1 · H3-SELECTION-PREFLIGHT — Gates 1 and 2

No production mutation. H2, H3, and releases 139/140 all unchanged; both
negative controls restored the descriptor and H3 still audits CLEAN.

## GATE 1 — the authority that selects H2, traced in code

    release_command.dart:306      targetFlutterRevision = resolveTargetFlutterRevision()
    release_command.dart:493      flutterVersionArg == 'latest'
                                    -> shorebirdEnv.flutterRevision
    shorebird_env.dart:89-99      flutterRevision reads
                                    <shorebirdRoot>/bin/internal/flutter.version
    shorebird_env.dart:108-112    flutterDirectory =
                                    <shorebirdRoot>/bin/cache/flutter/<flutterRevision>
    shorebird_env.dart:77-86      shorebirdEngineRevision reads
                                    <flutterDirectory>/bin/internal/engine.version
    ios_releaser.dart:553         engineRevision = shorebirdEnv.shorebirdEngineRevision
                                    -> recorded in route_b.json
                                    -> and used to resolve the compiler cell

So for releases 139 and 140:

    CLI bin/internal/flutter.version = 8427e3da (F2)
      -> flutterDirectory bin/cache/flutter/8427e3da
      -> that checkout's engine.version = 64ff9f59 (H2)
      -> engineRevision = H2

Confirmed against release 140's own recorded metadata, which carries
`flutter_version_override: "latest"` — i.e. the CLI pin was the authority, not
a command-line choice.

### THE AUTHORITATIVE SELECTOR IS `engine.version` INSIDE A FLUTTER COMMIT

Not the CLI pin directly. The CLI pin only chooses WHICH Flutter checkout is
consulted. So selecting H3 requires a Flutter commit whose tracked
`engine.version` is H3. That artifact is unavoidable.

### A NEW CLI PIN IS **NOT** REQUIRED

`--flutter-version` already overrides the pin, and it accepts a BARE GIT HASH,
not only a semver:

    release_command.dart:326      flutterRevisionOverride: targetFlutterRevision
    shorebird_flutter.dart:248    resolveFlutterRevision(versionOrHash)
                                    tryParseVersion -> null for a hash
                                    _gitHashPattern matches
                                    git revParse in _workingDirectory()
    release_command.dart:497      fetchRemoteRefs() runs FIRST for any
                                    non-'latest' argument
    shorebird_flutter.dart:56     installRevision clones flutterGitUrl into
                                    bin/cache/flutter/<revision>

Measured, not assumed: the F2 checkout was cloned `--filter=tree:0`, so it holds
the full COMMIT graph and can already `cat-file -t` unrelated pins such as
`309dd657…` that are nowhere in its own history. With `fetchRemoteRefs()`
running before resolution, a newly pushed F3 becomes resolvable there.

    minimal legitimate successor:

      shorebird release ios --flutter-version <F3>
        -> fetchRemoteRefs from the mirror
        -> revParse F3
        -> installRevision clones F3
        -> flutterRevisionOverride = F3
        -> flutterDirectory = bin/cache/flutter/F3
        -> engine.version = H3
        -> engineRevision = H3

    ONE new immutable artifact (F3). NO new CLI pin. No new lineage beyond
    what the selector mechanically requires.

## GATE 2 — H3 resolves, before any release exists

Through the PRODUCTION `RouteBCompilerResolver` against the real CDN, empty
cache:

    REQUESTS, in order
      1  /download.shorebird.dev/shorebird/cell-manifests/<H3>.v2
      2  /download.shorebird.dev/shorebird/<H3>/route-b-compiler-darwin-arm64.zip

    RESULT                    ACCEPTED
    consumed archive sha256   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    analyzer in the cell      18862acd7de2af6381205064a7290b5fb67a6b9c707eabad8d645cff04c4eccb
    producer lineage          a5a8be5854c529268378ce16762a16d6e31763e9
    dual-kernel capability    true

The lineage is `a5a8be58…` and the address is `d4c0dbc2…` — different values,
accepted together. That is the v2 split doing its job.

### NEGATIVE CONTROLS — not a log line saying "H3"

    SUBSTITUTED  H2's descriptor served at H3's URL
        REFUSED  "the cell descriptor addresses 64ff9f59…, not the cell it was
                  requested for"
        1 request only — the compiler was NEVER fetched

    REMOVED      no descriptor at H3's URL
        REFUSED  falls to v1, which refuses because "the bundle records engine
                  a5a8be58…, not the engine it was published under"
        No silent v1 acceptance.

Both restored afterwards; the descriptor still self-authenticates to H3 and the
cell still audits CLEAN.

## DECISION BROUGHT BACK

    F3 (Flutter commit with engine.version = H3)   REQUIRED — the selector
                                                    lives there
    new CLI pin                                     NOT REQUIRED —
                                                    --flutter-version <F3>
                                                    is the existing mechanism

Recommend minting F3 only, then cutting the release with an explicit
`--flutter-version <F3>`, which also records the selection in the release
metadata rather than leaving it implicit in a pin.

Not yet claimed: that a normal release workflow selected H3 and EXECUTED the
compiler. Gate 2 proves the resolver does; the release path has not run.
