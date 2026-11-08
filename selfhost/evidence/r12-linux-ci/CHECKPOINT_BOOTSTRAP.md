# R12 checkpoint — STOPPED at a prerequisite. No decisive arm ran.

The credential-free toolchain checkpoint was run first, exactly as directed: can
the entire pinned owned Flutter/CLI toolchain bootstrap on a clean Linux/x64
builder? **It cannot, from owned bytes.** Stopping here, classifying, repairing
nothing.

## What succeeded

    substrate         debian trixie, linux/amd64 (emulated), JDK 21, Android SDK
                      image build FAILS if flutter/dart/shorebird or any cache is
                      present -- assertion passed
    container         uname Linux/x86_64, HOME=/r12home
                      flutter/dart/shorebird absent from PATH
                      no .shorebird/.pub-cache/.gradle/.android
                      no CI-detection vars, NO host mounts of any kind
    owned repo        cloned at 36d74a667fd47deed2775b41b9f6fcfa64ad509e
    OWNED FLUTTER     cloned from git://…:9418/flutter.git and checked out at
                      a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61 -- the pinned
                      revision, served by our own mirror. This part works.

So the Flutter *source* side of the supported toolchain is genuinely owned and
genuinely reproducible on a clean Linux builder.

## Where it stopped

The bootstrap read `bin/internal/engine.version` = `69f9831c360d…` and asked for
the Dart SDK. The fetch died:

    Downloading Linux x64 Dart SDK from Flutter engine 69f9831c360d…
    curl: (18) end of response with 146984962 bytes missing

## The finding: the supported toolchain is not bootstrap-complete from owned bytes

Our overlay owns **45** cells under `flutter_infra_release/flutter/`, and those
cells do carry Dart SDKs — `5b1a8965…/dart-sdk-linux-x64.zip` exists. But there
is **no cell at `69f9831c…`**, and that is the engine revision the *pinned
supported Flutter* actually requires. So the request falls through the CDN's
unsealed reverse-proxy to `storage.googleapis.com`:

    GET /flutter_infra_release/flutter/69f9831c…/dart-sdk-linux-x64.zip
    -> 302 /gcs/download.shorebird.dev/… -> reverse_proxy storage.googleapis.com

This is **not Linux-specific**. `dart-sdk-darwin-arm64.zip` at the same revision
redirects identically. The toolchain is not bootstrap-complete from owned bytes
on *any* host.

The distinction that makes this precise: at `69f9831c…` we own the **Shorebird**
artifacts (`patch-linux-x64.zip`, `patch-darwin-*.zip`, `artifacts_manifest.yaml`)
under `download.shorebird.dev/shorebird/`. We do **not** own the **Flutter**
artifacts at that address. Our 45 cells are keyed by the addresses of engines *we
minted*; the pinned Flutter's `engine.version` names the **stock** engine, which
we never minted a cell for.

### Why no existing host revealed this

The Mac has `~/.shorebird/…/a4a3c0d1…/bin/cache/dart-sdk` already populated —
397 MB, warm. Cell activation happens *after* bootstrap, so a developer machine
never re-derives this path. A container with no caches is the first thing that
has ever actually asked the question.

This contradicts nothing that was previously certified; it is a gap that only a
clean bootstrap could expose, which is what the criterion is for.
`compatibility.yaml` states the pin exists so that "a fresh bootstrap must
reproduce the supported toolchain from owned bytes alone" — that intent is not
yet met.

## Why I did not simply continue

The proxy path works when retried: from a container, `-r 0-5242879` returns 206
with 5 MB at ~4 MB/s; the host pulled all 146,984,983 bytes in ~4 s. So the
decisive arms would very likely have gone green.

**That green would have been worth nothing.** It would have certified

> self-hosted Shorebird works on Linux **provided upstream supplies part of the
> toolchain**

which is materially weaker than the platform under certification, and it is the
exact substitution the lane forbids. No fallback was attempted.

### A second, subordinate observation

The first fetch received **21 bytes** and aborted (21 + 146,984,962 = the full
146,984,983). The retry succeeded, so this is a transient on the upstream-proxy
path, not an absence. Recorded, not diagnosed — it sits on a path that should not
be load-bearing anyway.

## Recommended repair — NOT performed

Deliberately left undone: repairing during a decisive arm is what the lane
prohibits.

1. Publish an overlay cell at `69f9831c…` under `flutter_infra_release/flutter/`
   carrying the Flutter bootstrap artifacts (`dart-sdk-<host>.zip` and the
   engine slices the tool requests), sourced once and thereafter owned; **or**
2. pin a supported Flutter revision whose `engine.version` names a cell we
   already own.

Either makes the claim provable. The clean-Linux-builder test should then be
re-run **sealed** (`upstream/sealed.caddy`), because unsealed cannot distinguish
"owned" from "proxied" — which is precisely how this stayed invisible.

## Status

    R12   BLOCKED on a prerequisite, NOT failed.
          Nothing in the certified runtime was touched, read or rebuilt.
