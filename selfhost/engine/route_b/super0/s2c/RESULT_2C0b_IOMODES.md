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

---

## UPDATE — option (b) implemented, controls held, modes published, PREFLIGHT PASSES

### Wording correction, adopted

The earlier note that the stale label "is not in the bytes" over-claimed. What is
proven is narrower: **the release device binary's lineage is the candidate,
despite the stale release `args.gn engine_version`** — its sha1 is H and it
carries the marker. The archives also contain `gen_snapshot_arm64` and
`analyze_snapshot_arm64`, and absence of a revision STRING from
`Flutter.framework` says nothing about those. The justification for accepting
the candidate modes is the full source/build lineage plus identical Dart and
Skia inputs — not the absent string.

### The exception is opt-in, narrow, and one-directional

`package_ios_mode_artifacts.sh` gained:

    --allow-stale-release-engine-version <srcRev>

Default behaviour is UNCHANGED. With the flag, only `engine_version` may differ,
and only from `619fdad1…` to the declared `<srcRev>`; every other field still
refuses. It additionally requires, before packaging: mode `args.gn`
engine_version == `<srcRev>`; engine source HEAD == `<srcRev>`; release
`args.gn` engine_version == the documented stale `619fdad1…`; equal
`dart_version` and `skia_version`; release device binary sha1 == H with marker
and updater exactly once; and this mode's binary with marker and updater exactly
once. Freshness, mode identity, Route B flags, host tools and deterministic
double-packaging all still apply.

### Three-arm control — the checker did not just become permissive

    ordinary invocation                REFUSED
      "engine_version differs from the release build: release=619fdad1… debug=dfa2b24a…"
    wrong declared source (deadbeef…)  REFUSED
      "debug args.gn engine_version is dfa2b24a…, not the declared source deadbeef…"
    exact documented exception         ACCEPTED

### Published under H

    ios/artifacts.zip          5891a6bb82dbb2a4a246da262acc405852f462f85067d069d413bab47ece3d60  24,778,279
    ios-profile/artifacts.zip  c0b922f2491f613cfed5d29abf3f3208b768a493fbaca82dd2c904b3a887425f  16,513,870

Both REPRODUCIBLE (packaged twice, byte-identical). Fetched back through :8085,
200 with `X-Overlay: hit` and `X-Engine-Hash` = H, archive sha256 equal to the
published bytes.

    ios          device c9ce68c8fbc1c477…  marker 1  updater 1
                 gen_snapshot 7754258ddf081ae2…  analyze_snapshot 8348555850392e53…
    ios-profile  device 585e884d410ce8ce…  marker 1  updater 1
                 gen_snapshot 1d5599eef478b94a…  analyze_snapshot 8526b9a2aaff4b0e…

### Policy and protection corrected

`artifact_policy.conf`: both paths are now `macos-ios owned-built required`,
with the measured reason recorded — `_iosBinaryDirs` requires all three modes
for ANY iOS build, and fallback is not a substitute because the unowned path
goes upstream into the mirror's ~10 s deadline.

`@must_be_local_pkgs`: H-scoped protection added for
`H/(ios|ios-profile)/artifacts.zip`. The GLOBAL matcher was deliberately NOT
broadened — older mapped hashes may not have both.

`cdn-cache` recreated (same image); `artifact-proxy` untouched.

    owned-built 14 -> 16   missing-required 0   unprotected 0   denied-present 0
    AUDIT CLEAN for a5a8be5854c529268378ce16762a16d6e31763e9 (macos-ios)

### Pre-release resolution preflight — 7/7 PASS

From an EMPTY candidate-local cache:

    1  CLI Flutter pin f864f6c6 -> 371005c9            PASS
    2  tracked Flutter engine.version = H              PASS
    3  CLI resolver requests H                         PASS (engine.stamp = H)
    4  flutter precache --ios COMPLETES                PASS (no 504)
    5  consumed ios          = banked H debug          c9ce68c8…  MATCH
    6  consumed ios-profile  = banked H profile        585e884d…  MATCH
    7  consumed ios-release  sha1 = H, marker 1, updater 1        PASS

The item-3 blocker is closed: the same command that previously died on
`ios/artifacts.zip` now completes, because the cell owns all three modes.

Compiler-cell resolution is deliberately NOT claimed here — it can only be
observed on the patch path, after a release exists.
