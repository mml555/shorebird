# Flutter 3.47 (9056dae9) promotion: the frozen chain, run on ci-build

Date 2026-11-10. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`. Candidate CLI commit for the
bootstrap runs: `0c8e34239d337cb14fd61d4d4a2f2620662ba9cc` (fork/main `f4b2e7f60`
plus `bin/internal/flutter.version` -> `9056dae9`, nothing else).

    flutter_revision   9056dae9e28761f7508191146ae2469ba014be08   shorebird-flutter shorebird/dev, PR #8
    engine.version     7806e0fb68242dbef74e224bdaa81bd62b0d988e
    release candidate  flutter-3.47-candidate.0, Dart 3.13.7
    CLI                1.6.138+selfhost.1 (was 1.6.115+selfhost.1; bin/internal/flutter.version was 5b180d22)

Everything ran on ci-build in `/srv/ci-cache/shorebird-engine/promo-347` (logs in `logs/`,
ledgers in `evidence/`). Copies of the small evidence files are in `promotion-9056dae9/`.

## Setup, and how the mirror was kept cold

- **Cold sealed mirror** `r12-cdn-sealed`: compose project `r12cold`, the production
  Caddyfile and overlay mounted read-only, `upstream/sealed.caddy`, its **own empty cache
  volume**, ports 8086 (http) and 8087 (https). The warm production mirror
  `shorebird-cdn-cdn-cache-1` was not restarted or reconfigured. Origin is read from
  `X-Overlay: hit` in the access log, not from a 200.
- **Owned Flutter mirror**: bare clone of `mml555/shorebird-flutter` at
  `promo-347/mirrors/flutter.git`, served over `git://` by `r12-flutter-git`.
- **Control plane**: a throwaway `code-push-server:1.4.0` (`r12-cps`, fresh volume, random
  key, bound to the docker bridge address only), with an app row carrying the fixture's
  app id so the fixture stays unmodified.
- **Builder**: `r12-builder:substrate` built from `selfhost/ci/r12/Dockerfile`. Flutter
  3.47's `FlutterExtension.kt` still asks for compileSdk 36, minSdk 24 and NDK
  28.2.13676358, so the substrate needed no change.
- A CA minted for the run (the one from `cdn/tls/generate.sh` has name constraints that
  Dart's TLS rejects, `unsupported name constraint type`; the first release attempt
  failed on that, not on an artifact).
- The r12 scripts needed fixes to run on Linux and on a newer pin. They are in a separate
  PR (`selfhost/r12-linux-host`).

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `9056dae9` is on `shorebird/dev`, 107 ahead of `e2c965ff`, 0 behind | mirror at `promo-347/mirrors/flutter.git` |
| 2 | exact `engine.version` | PASS: `7806e0fb68242dbef74e224bdaa81bd62b0d988e`, `release-candidate-branch.version` `flutter-3.47-candidate.0` | `git show 9056dae9:bin/internal/engine.version` |
| 3 | SEALED + COLD bootstrap discovery | PASS, **0 additions needed**. The bootstrap asked for `dart-sdk-linux-x64.zip`, `engine_stamp.json` and a HEAD of `linux-x64/font-subset.zip`; all overlay hits | `promotion-9056dae9/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 3 rows (size, SHA-256, provenance) in `bootstrap_closure.tsv`, manifest digest in `proxy_mapping.tsv` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK`, 3 artifacts size + SHA-256 verified, proxy mapping pinned (`e750b145...` -> `7806e0fb`), run on the final `compatibility.yaml` | `promotion-9056dae9/guard_final.log` |
| 6 | fresh sealed cold bootstrap | PASS: `launch.sh` in bootstrap-only mode, fresh container, no host mounts, exit 0. 3 overlay hits, 0 `/gcs/` passthroughs, 0 non-overlay 200s; one 502 for `GET /`, the harness's CA probe of the mirror root, not an artifact | `fresh_bootstrap_launch.log`, `boot1_access.txt` |
| 7 | sealed release/patch artifact discovery | PASS after 13 imports (below); the last round refused nothing and release and patch completed | `release_patch_closure_7806e0fb.tsv`, `release_patch_discovery_last.log` |
| 8 | fresh Linux release/patch smoke | PASS for release and patch, see the caveat | `armA_launch.log`, `armA_access.txt` |

### Gate 8 in detail

`launch.sh A 1.0.0+1` from a fresh container against the sealed cold mirror over https:
release `1.0.0+1` published, patch 1 published, `--json` patch published (`interactive_prompt_required`
0), 37 overlay hits, 0 `/gcs/`, 0 refused (the single 502 is `GET /`, as in gate 6).

**The frozen harness's own verdict was FAIL**: arm 3 (`shorebird patch android --no-confirm`
with no `--release-version`) exits 0 and publishes patch 3 against the latest release, where
the harness expects 64 (the chooser refusing to prompt). Arm 3 itself never touches an
artifact, so this is not a closure finding. It is the workflow semantics changing between
CLI 1.6.115 and 1.6.138. See the R12 call below.

### What was imported (gate 7)

Ledger: `release_patch_closure.tsv`, each row keyed by the CLIENT path, paired with the 302
that produced it (`pair_refusals.py`), size verified against Content-Length, refusing to
overwrite a differing file.

- Not engine bound: `flutter/fonts/3012db47.../fonts.zip`, `gradle-wrapper/fd5c1f2c.../gradle-wrapper.tgz`,
  and `shorebird/38855c84.../artifacts_manifest.yaml` (the proxy's manifest for the fallback hash).
- **Upstream stock engine bytes, not built from 7806e0fb** (10 files): `android-{arm,arm64,x64}-profile/linux-x64.zip`
  and `android-{arm,arm64,x64}{,-profile}/artifacts.zip` from engine `38855c84` (via the
  proxy's remap), and `android-x86/artifacts.zip` from stock `89c39edf`. The 7806e0fb build
  made release engines only, so nothing here can be produced honestly from our own build.
  They sit under the 7806e0fb client path as the mirror's own fallback map would serve them.
  A debug or profile run on this pin would use a stock engine under a 3.47 framework.

The 7806e0fb bytes themselves are ours: `dart-sdk-linux-x64.zip`, `engine_stamp.json` and
`linux-x64/font-subset.zip` are members of `overlay-7806e0fb....tar` on the
`engine-7806e0fb...` release (SHA256SUMS sha256 `82352d49aedbf5e1b70b03f1277a6767149259abbf1a69d4e40c0ad6c02385ac`).
All 63 files in the overlay were re-compared with that tar and are byte-identical.

## R12 recertification: required, not run

The doc asks for two-arm R12 when the pin changes CLI prompting or noninteractive behaviour,
authentication, artifact resolution, platform support, or release/patch workflow semantics,
or the R12 harness. This jump does several of those:

- noninteractive/prompting: `shorebird patch` asks for the track when there is no `--track` (#4291), blocked asset and native diffs report errors when the CLI cannot prompt (#4308), patch stops when dart-defines or target differ from the release's (#4381);
- release/patch semantics: patch no longer guesses the release version and never reuses its build (#4307), Android patches build only the release's architectures (#4236), a missing signing key fails early (#4298), enterprise-required signing refuses unsigned builds (#4386);
- authentication: patches are signed with a Shorebird-managed key by default (#4182), the auth service is derived from the code push server (#4190);
- artifact resolution: patch reuses release artifacts downloaded by earlier patches (#4235);
- the harness: arm 3 now exits 0 where the harness expects 64, measured above.

Add Flutter 3.44 -> 3.47 and Dart 3.12.2 -> 3.13.7. Arm 3's expectation (and what "chooser"
means for this CLI) has to be re-decided before two arms are meaningful, so this is not just a rerun.
The chain above establishes constructibility from owned bytes and a working release and
patch. It does not re-certify R12.

## Open

- Two-arm R12 recertification and the arm 3 decision.
- Debug and profile engine artifacts for 7806e0fb (stock bytes stand in).
- `sky_engine` and `flutter_gpu` are UNPROTECTED in `@must_be_local` (accepted, known).
- `updater_revision` in `compatibility.yaml` is `af6e842ccf87`; 3.47's DEPS has `updater_rev`
  `87c198d30f875a3da317d70935e1025dc13064dd`. Not touched; `eligibleUpdaterRevisions` is the owner's call.
- `engine/route_b/SUPPORTED_STATE.yaml` still names `5b180d22` as its flutter selector. It is a
  separate axis (see the comment on `engine_revision` in `compatibility.yaml`) and was not edited.
- `flutter --version` on the bootstrapped checkout prints `3.46.0-1.0.pre-849`: the version string
  comes from `git describe` against the mirror's tags, not from `release-candidate-branch.version`.
