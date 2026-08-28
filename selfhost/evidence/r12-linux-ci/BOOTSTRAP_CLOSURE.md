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
