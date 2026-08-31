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
