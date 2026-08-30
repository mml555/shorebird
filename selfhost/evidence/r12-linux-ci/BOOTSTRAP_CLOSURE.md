# 69f9831c owned-artifact bootstrap closure — CLOSED under seal

The prerequisite that stopped R12 on 2026-08-28 is repaired. The Flutter pin, the
engine identity, the CLI and the certified runtime are all **unchanged**; what
changed is who hosts two artifacts.

## The repair

    source identity    unchanged     flutter pin        unchanged
    engine identity    unchanged     certified runtime  unchanged
    artifact bytes     unchanged     hosting            upstream -> owned

`mirror_bootstrap_artifact.sh` imports one exact immutable object, verifies the
body against the declared `Content-Length` before banking it — the checkpoint had
already seen a transfer die after 21 bytes, and a mirror that banks a short read
publishes corruption under an owned name — and refuses to overwrite an existing
overlay file whose bytes differ.

## The closure, discovered rather than guessed

    engine   69f9831c360d9152862ec3897c67fb09ae843f3b
    artifact                  bytes        sha256
    dart-sdk-linux-x64.zip    146984983    4f6aac5042ccbb7a29fb84e1dd54c9bc321384978a01b9248b1b1fa34ab19e2b
    engine_stamp.json               237    f424c1e7f9c0f4c620c66b4e75050394a85c14ec307591db88c92f8ccfb34b7b

Both from
`storage.googleapis.com/download.shorebird.dev/flutter_infra_release/flutter/69f9831c…/`.
Full provenance in `bootstrap_closure.tsv`.

`discover_closure.sh` found these by bootstrapping against a sealed mirror and
importing whatever it was refused, until it stopped being refused. Only the first
one was predictable; `engine_stamp.json` was not, which is the argument for
discovering a closure instead of listing it from memory.

## Why "sealed" alone would have been a false green

`sealed.caddy` **still serves cache hits** — by design, that is what the air-gap
mode is for — and the production mirror at :8085 is ~1 GB warm. A sealed run
against it could have been satisfied entirely from cached upstream bytes and
reported a closure that did not exist.

So the decisive run used `r12-cdn-sealed`: the same Caddyfile and the same
overlay, sealed, on its **own empty cache volume**. A 200 there can only have come
from `/overlay`. The production mirror was not purged and not disturbed.

## Decisive run — fresh container, sealed, cold

    container   fresh, linux/amd64, HOME=/r12home
                no flutter/dart/shorebird on PATH, no caches, NO host mounts
    flutter     git://…:9418/flutter.git -> a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    artifacts   http://host.docker.internal:8086 (sealed, cold)
    result      EXIT 0

    Shorebird 1.6.115+selfhost.1
    Flutter   3.44.8+selfhost.1 • revision a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    Engine    • revision 69f9831c360d9152862ec3897c67fb09ae843f3b

### Every byte accounted for, from the mirror's own access log

    200  overlay=hit    2103968  …/fc184af6…/android-arm64-release/linux-x64.zip   (preflight probe)
    200  overlay=hit  146984983  …/69f9831c…/dart-sdk-linux-x64.zip
    200  overlay=hit        237  …/69f9831c…/engine_stamp.json

    502 sealed refusals   0
    200 not from overlay  0
    /gcs/ passthroughs    0

`X-Overlay: hit` is the server stating the origin, rather than us inferring it
from a status code.

## What this does NOT establish

**This is the bootstrap closure, not the full release/patch closure.** The
decisive arms build an Android release and a patch, which will request engine and
tool artifacts this run never touched. A further closure round on the same
provenance process should be expected, and finding one is not a regression.

**`dart pub get` reached pub.dev.** Package dependencies are not the
Flutter/Dart/engine toolchain and are not covered by the seal, which only governs
the artifact mirror. Recorded so the claim is not read as broader than it is.

**The repo clone came from github.com** — our own repository at a full immutable
SHA, so owned, but over the network rather than from the sealed mirror.

## The permanent guard

`selfhost/ci/bootstrap_closure_guard.sh` walks
`compatibility.yaml -> flutter_revision -> engine.version -> owned cell -> required artifacts`
and fails if the chain breaks. It is the analogue of `r12_revision_guard.sh` one
layer earlier, and it would have fired on this defect from the day the pin was
set. Mutation-tested:

| mutation | result |
|---|---|
| overlay with no cell for the supported engine | REFUSE (the 2026-08-28 defect) |
| cell present, required artifact absent | REFUSE |
| required artifact present but zero bytes | REFUSE |
| owned mirror lacks the pinned revision | REFUSE |
| unmutated | CLOSURE OK, exit 0 |

**Placement is a decision, not an oversight.** It reads the 10 GB gitignored
overlay and the local bare mirror, so on a hosted GitHub runner it could only be
vacuous or permanently red. It belongs on the self-hosted machine beside
`verify_toolchain_coherence.sh`. Wiring it into `.github/workflows/` would
reproduce exactly the class of check this project keeps rejecting.

---

## Guard hardening — the manifest is now authoritative

The first version of the guard was weaker than the evidence it existed to
preserve: it carried a hardcoded filename and tested only `-s`, so it would have
passed with `engine_stamp.json` deleted and passed on a one-byte Dart SDK. That
did not affect the sealed bootstrap evidence — the fresh-container run proves the
bytes present are sufficient — but the *prevention mechanism* did not cover the
closure it was protecting.

It now consumes `bootstrap_closure.tsv` for the resolved engine and verifies
**existence, exact byte count and exact SHA-256** for every named row, so the
guard and the evidence cannot drift apart.

    compatibility.yaml -> pinned Flutter SHA -> owned mirror -> engine.version
      -> bootstrap_closure.tsv -> every named artifact -> size + SHA-256

| mutation | result |
|---|---|
| control, unmodified sandbox | **PASS** — 2 artifacts, size + sha256 verified |
| `engine_stamp.json` removed | REFUSE — MISSING from the owned cell |
| Dart SDK truncated to 1 MB | REFUSE — SIZE MISMATCH 1000000 vs 146984983 |
| Dart SDK corrupted, **same size** | REFUSE — DIGEST MISMATCH |
| whole engine cell deleted | REFUSE — NO OWNED CELL |
| owned mirror lacks the pin | REFUSE — the pin is not reproducible |
| manifest names no rows for the engine | REFUSE — an empty closure is not a satisfied closure |
| control, sandbox restored | **PASS** |

Run against a cloned sandbox; the real overlay was never mutated, and the
bracketing controls prove the sandbox itself was valid both before and after.

**Invocation point:** `r12/launch.sh` now runs the guard in its preflight, so the
closure is re-proved before every arm. It stays out of hosted CI by design — it
reads the gitignored multi-gigabyte overlay and the local bare mirror, where a
hosted runner could only be vacuous or permanently red. Move it to a self-hosted
workflow when one exists.

---

## Service restart, 2026-08-30 — and a retroactive check on "cold"

Raising the Docker VM (7.75 GiB -> 11.91 GiB / 9 CPUs) restarted Docker and
stopped both `r12-flutter-git` and `r12-cdn-sealed`. Arm B's preflight **refused
to start** on it:

    FAIL: r12-flutter-git is not running (the owned Flutter mirror service)

which is the fail-closed behaviour working: an arm that had proceeded would have
silently used whatever the environment happened to offer.

Both services were recreated, and `r12-cdn-sealed` was given a **brand new** cache
volume so the cold claim needs no argument. Re-verified after restart:

    owned mirror serves    refs/heads/selfhost/3.44.8 -> a4a3c0d1b1b0f997  (pinned)
    sealed+cold over TLS   sky_engine.zip -> 200, CA validation enforced
    unowned artifact       "sealed: refusing upstream fetch for ..."  (seal live)
    closure guard          CLOSURE OK, 2 artifacts by size + sha256

### The cold cache was genuinely cold, then and now

The new volume reports three files, exactly as the old one did — so that count is
the empty-store baseline, not cached artifacts:

    0.dat           268435456 bytes   nutsdb PREALLOCATION, no entries
    bucket.Meta             0 bytes
    nutsdb-flock            0 bytes

Two 0-byte metadata files and a preallocated data file. This matters backwards as
well as forwards: the volume Arm A ran against carried the same three files, so
Arm A's "25× 200, all X-Overlay: hit, 0 non-overlay" was served from the overlay
and not from a warm cache. The claim holds.
