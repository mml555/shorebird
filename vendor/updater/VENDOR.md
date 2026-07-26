# Vendored: shorebirdtech/updater

Pinned snapshot of the Shorebird native updater (Rust), vendored so we build it
ourselves and are insulated from upstream changes.

- Upstream: https://github.com/shorebirdtech/updater
- Pinned commit: 1f85c4ab (2026-07-02)
- Matches engine revision: e1eaecbcac6d9a32cb5590c646e21cf21252cf19 (see selfhost/compatibility.yaml)

To update: re-vendor a new commit, bump compatibility.yaml, and re-run the
compatibility suite before declaring support.
