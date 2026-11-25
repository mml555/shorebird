# Promoting a Flutter revision to SUPPORTED — the frozen order

Frozen 2026-08-31, from the R12 lane. This is a **prerequisite chain**, not a
checklist to work through after the fact: the closure must be established
*before* the pin is declared supported, never discovered afterwards.

## The mistake this exists to prevent

The project treated

    Flutter source is owned  +  Shorebird artifacts are owned

as equivalent to

    a clean machine can construct the supported toolchain from owned bytes

**It is not.** Those are different claims, and the second was false for the entire
programme without anyone noticing.

The pinned Flutter's `bin/internal/engine.version` named a **stock** engine
(`69f9831c…`) for which the overlay published no Flutter artifacts — our 45 cells
are keyed by engines *we* minted. A cold bootstrap therefore escaped to upstream
GCS through the CDN's unsealed proxy, on **every** host, not just Linux.

Nothing revealed it because every developer machine had a warm `~/.shorebird`
cache (397 MB of Dart SDK on this Mac) and because cell activation happens *after*
bootstrap. A container with no caches was the first thing that ever asked the
question. `compatibility.yaml` had stated the intent all along — the pin exists so
"a fresh bootstrap must reproduce the supported toolchain from owned bytes alone"
— and the intent was simply not met.

**Warm caches hide missing links. A cold, sealed builder is the only honest test.**

## The promotion chain

    candidate flutter_revision
            ↓
    exists in owned Flutter mirror
            ↓
    resolve exact engine.version
            ↓
    SEALED + COLD bootstrap discovery
            ↓
    bank complete bootstrap artifact manifest
    (size + SHA-256 + provenance)
            ↓
    bootstrap_closure_guard PASS
            ↓
    fresh SEALED cold bootstrap PASS
            ↓
    SEALED release/patch artifact discovery
            ↓
    fresh Linux release/patch smoke PASS
            ↓
    only then:
    compatibility.yaml → SUPPORTED

### Gating the release/patch discovery step

`discover_release_closure.sh` runs the frozen harness
(`scripts/ci_noninteractive.sh`) under the seal. With a single release on the
control plane its verdict is FAIL by design: arm 3 (patch with no
`--release-version`, the release chooser) has one release to pick, never
prompts, and exits 0 instead of 64. Do not gate on "NOTHING refused by the
seal" alone; that also passes a run where arm 1, arm 2 or a detector self-test
failed. Keep the log and check it:

    set -o pipefail   # optional: keeps the script's own exit status through tee
    discover_release_closure.sh 2>&1 | tee rp.log
    selfhost/ci/r12/check_rp_arms.sh rp.log

Exit 0 means the seal refused nothing, both self-tests fired, arm 1 and arm 2
passed with no prompt reached, and arm 3's single-release exit 0 is the only
failed check. 1 is a failed check, including a run that stopped with something
refused; a real arm 1 failure is 1 (the harness skips arm 1 patch after it). 2
is a log it cannot parse (no arms block, truncated, no verdict, or two runs in
one file), which is not a pass. The step passes only on 0, and the gate reads
one run's log: write `rp.log` fresh, never `tee -a`.

A workspace set up by `selfhost/engine/route_b/promo_clone.sh` runs this gate as step 7
of its `bin/chain.sh`, and keeps the verdict as `evidence/rp_arms.txt`. Chains up to
`9995f957` gated on "NOTHING refused by the seal" alone; `promo_clone.sh` replaces that
line when it clones such a workspace, keeps a donor that already has this gate as it is,
and refuses a donor whose step 7 gate is neither.

When it stops, the discovery script prints the last 120 lines of the harness
output (`ci/r12/rp_iter.log`, the full output of the last iteration), enough
for the whole arms block. The harness (`scripts/ci_noninteractive.sh`) is
frozen and the gate matches its wording, so a reworded harness gives 2, not a
pass. `check_rp_arms_test.sh` covers the gate in CI, and runs on edits to
either script.

### SEALED **and** COLD, both

`upstream/sealed.caddy` still serves **cache hits** — that is what the air-gap
mode is for. Sealing a warm mirror can therefore be satisfied entirely by cached
*upstream* bytes and report a closure that does not exist. Use a separate mirror
instance with its own empty cache volume, and confirm origin from the server's own
`X-Overlay: hit` rather than inferring it from a 200.

### Mirror by the CLIENT path

The overlay is keyed by the path the client asks for; upstream is the
`/gcs`-rewritten path, and the artifact proxy also **remaps the engine hash** via
`artifacts_manifest.yaml`. Deriving one address from the other by string surgery
writes correct bytes where nothing will ever look for them — a silent non-repair
that cost 28 wasted discovery iterations. Pair each refusal with the 302 that
produced it (`ci/r12/pair_refusals.py`).

## Tooling

    ci/bootstrap_closure_guard.sh        pin → mirror → engine.version → manifest
                                         → every artifact by size + SHA-256,
                                         plus the proxy mapping pinned by digest
    ci/r12/discover_closure.sh           sealed cold bootstrap closure discovery
    ci/r12/discover_release_closure.sh   sealed release/patch closure discovery
    ci/r12/mirror_bootstrap_artifact.sh  import one bootstrap artifact w/ provenance
    ci/r12/mirror_cdn_artifact.sh        import by (client_path, gcs_path)
    ci/r12/check_rp_arms.sh              gate on the discovery log's arms block
    ci/r12/launch.sh                     one decisive arm; runs both guards first

The guard runs on the self-hosted machine, beside
`verify_toolchain_coherence.sh`. It reads the gitignored multi-gigabyte overlay
and the local bare mirror, so on a hosted runner it could only be vacuous or
permanently red.

## When full R12 recertification IS required

An ordinary pin update with no change to noninteractive semantics requires:

    compatibility qualification
    sealed cold bootstrap closure rediscovery
    closure guard PASS
    sealed clean Linux release/patch smoke PASS

It does **not** automatically require two-arm R12 recertification.

Re-run full R12 only when the pin changes something relevant to:

* CLI prompting / noninteractive behaviour
* authentication
* artifact-resolution behaviour
* host-platform support
* release/patch workflow semantics
* or the R12 harness itself, materially

Certification that fires on every pin becomes ritual; the point is to protect the
property that actually failed here, which is **constructibility from owned bytes**.
