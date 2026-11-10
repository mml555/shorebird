# Vendored: shorebirdtech/updater

Pinned snapshot of the Shorebird native updater (Rust), vendored so we build it
ourselves and are insulated from upstream changes.

- Upstream: https://github.com/shorebirdtech/updater
- Upstream base commit: ca91f4b313e5ff1ddb0471af0442ed2bad983bfe (the `updater_rev` in shorebirdtech/flutter e2c965ff DEPS)
- Source revision: 87c198d30f875a3da317d70935e1025dc13064dd, branch `route-b-ca91f4b3` of mml555/shorebird-updater-mirror
  (the fork's route-b changes ported onto the upstream base; see SELFHOST_PORT_ca91f4b3.md in this directory).
  The vendored files are the tree of that commit, except `.github/`, which is upstream's at the base commit:
  the commit's own change to `.github/` is mirror CI only.
- Ahead of that revision by one change, mml555/shorebird-updater-mirror#11 (bounded diag logs; a proxy refusing CONNECT is a transport error in the ureq builds, Linux and Windows, not Android, iOS or macOS),
  applied here so the copy matches once that PR merges. Shipped engines get it at their next rebuild, when DEPS `updater_rev` moves.
- Previous snapshot: upstream 1f85c4ab (2026-07-02) plus fork-local commits, replaced by this one.
- Engine revision it was last matched against: e1eaecbcac6d9a32cb5590c646e21cf21252cf19 (see selfhost/compatibility.yaml).
  That file has not been bumped for this snapshot.

The revision the updater reports (`UPDATER_REVISION`, which `PolicyEpoch` keys
on) is read by `library/build.rs` from the checkout's own `.git`. This copy has
none, so anything built from `vendor/updater` stamps `unknown` and its events
count toward no epoch. Shipped engines build the updater from the mirror
checkout that the Flutter fork's DEPS pins, which stamps `87c198d30f87`. This
copy is for CI and the Dart-to-Rust signing seam test.

`shorebird_code_push/` is the Dart package. It needs the Flutter SDK, so no CI job runs it. Only the Rust
workspace (library, library_test_hooks, patch) is built and tested in CI.

To update: re-vendor a new commit, bump compatibility.yaml, and re-run the
compatibility suite before declaring support.
