# D-SUPER-2C.0b · PREFLIGHT-IO-MODES — build STOP at the per-mode gate

    H = a5a8be5854c529268378ce16762a16d6e31763e9

## Builds — DONE, and the candidate observables hold

Built from `dfa2b24ac38477f3705ff0357530f33fe09474b8` on branch
`route-b-2c-candidate`, via `build_ios_debug_profile.sh`, detached under screen.
`ios_release` was NOT rebuilt.

"ALL DONE" was not accepted as evidence. Each mode's own ninja exit was read:

    ios_debug    ninja exit=0   2026-09-01T04:12:49Z
    ios_profile  ninja exit=0   2026-09-01T04:16:13Z

Candidate-specific observables, both modes:

    ios_debug    sha1 2c8ee5440ab042b4bf001bad19c30574c467a508  marker 1  updater 1
    ios_profile  sha1 831852a7014702242ca24977adbc2f380cc463b3  marker 1  updater 1
    ios_release  sha1 a5a8be58…(H)                              marker 1  updater 1

Each binary is newer than its own `args.gn`. Debug/profile SHA-1s differ from H,
as expected for sibling runtime modes.

### The marker observable earned itself immediately

`out/ios_debug` and `out/ios_profile` ALREADY existed — from **Aug 27**, with
**0** candidate markers. They are certified-lineage builds predating the marker
commit. Every other qualification field would have passed on them. Publishing
them under H would have shipped the wrong engine lineage as the candidate's
debug/profile, silently. They were rebuilt rather than reused.

## STOP — `package_ios_mode_artifacts.sh --mode debug --hash H` refuses

    ERROR: engine_version differs from the release build:
           release=619fdad176ff457331b50230b9511e7230a6ed93
           debug=dfa2b24ac38477f3705ff0357530f33fe09474b8

The gate is doing its job; it is the REFERENCE that is stale. Measured scope —
exactly one of the three compared fields disagrees:

    engine_version   release 619fdad1…   debug/profile dfa2b24a…   DIFFER
    dart_version     9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c      all three equal
    skia_version     e9ed4fc9f1544c58d8a9347c1fc9471d8dd7c465      all three equal

### Why the release's label is stale

    out/ios_release/args.gn   mtime Aug 27 16:08:34   engine_version 619fdad1…
    out/ios_release binary    mtime Aug 31 20:57:20   marker 1  -> built from dfa2b24a

The candidate release was rebuilt on Aug 31 by running ninja against the Aug 27
`args.gn` without re-running gn. So the artifact that EARNED H declares the
CERTIFIED engine revision in its build config while its bytes come from the
candidate tree. Debug and profile, configured fresh today, carry the truthful
`dfa2b24a`.

### The label is not in the bytes

    embedded 619fdad1…   ios_debug 0   ios_profile 0   ios_release 0
    embedded dfa2b24a…   ios_debug 0   ios_profile 0   ios_release 0

`engine_version` is stripped from iOS device binaries in all three modes. That
is the same measurement that made the explicit `no_dead_strip` candidate marker
necessary in 2C.0a. So this is a build-config label disagreement, not a
difference in shipped code — all three modes genuinely come from one tree.

### Why this is not resolved unilaterally

The gate's stated intent — "SAME PINNED TREE as the release" — is satisfied in
substance. But H is frozen and its `args.gn` cannot be corrected without
rebuilding `ios_release`, which would change H. So the only ways to make the
LABELS agree are:

  (a) rebuild debug/profile declaring `engine_version = 619fdad1…`, matching the
      frozen release. All three then agree — at a value none of them was built
      from. Cheap (~3 min/mode), no gate change, no touching ios_release. But it
      means deliberately writing a provenance label that is false for all three.

  (b) record a documented, cell-scoped deviation for this one field, proving
      tree identity directly instead (same source commit, marker present in all
      three, dart/skia identical). Honest, but it needs a change to the checker
      mid-gate, which the standing ruling forbids.

Nothing was published. Not overridden. Raised for ruling.
