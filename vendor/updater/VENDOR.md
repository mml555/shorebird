# Vendored: shorebirdtech/updater

Pinned snapshot of the Shorebird native updater (Rust), vendored so we build it
ourselves and are insulated from upstream changes.

- Upstream: https://github.com/shorebirdtech/updater
- Upstream base commit: 91dbbddb958a397868c9d8db4742a10e0f2c3832 (upstream #456, the commit "Merge upstream updater 91dbbddb958a into route-b" merged)
- Source revision: a58774ab8a88a04ae5f96ce4e5a9825561a2f2f3, branch `route-b-91dbbdd` of mml555/shorebird-updater-mirror
  (the fork's route-b changes ported onto the upstream base; see SELFHOST_PORT_91dbbdd.md in this directory,
  and SELFHOST_PORT_ca91f4b3.md for the port it builds on).
  The vendored files are the tree of that commit, except `.github/`, which is upstream's at the base commit
  (91dbbddb958a): the mirror's own changes to `.github/` are mirror CI only.
- Ahead of that revision by one change, mml555/shorebird-updater-mirror#11 (merged into `route-b-ca91f4b3` as merge commit
  9a7bdb3ed50a37250fdb5a004b698dad01e8951d): bounded diag logs (new `library/src/diag_log.rs`); a proxy refusing CONNECT is a
  transport error in the ureq builds, Linux and Windows, not Android, iOS or macOS. The shipped 3.50 engine does NOT have it:
  a58774ab does not contain 9a7bdb3e. It reaches engines when DEPS `updater_rev` moves to a commit containing it
  (route-b-91dbbdd needs #11 merged into it first). The merge into this tree was done locally, with one conflict in
  `library/src/updater.rs` (`report_launch_success`'s success_diag.log block, resolved by hand onto the new nesting).
- Previous snapshot: 87c198d30f875a3da317d70935e1025dc13064dd (branch `route-b-ca91f4b3`, upstream base ca91f4b3) plus mirror#11, replaced by this one.
- Engine revision it was matched against: e737ede3bcf9b18c495498ada78a841e38b4a388 (shorebird-flutter, Flutter 3.50; its DEPS
  `updater_rev` is the source revision above). Stamped revision (`updater_revision` in selfhost/compatibility.yaml): a58774ab8a88.

The revision the updater reports (`UPDATER_REVISION`, which `PolicyEpoch` keys
on) is read by `library/build.rs` from the checkout's own `.git`. This copy has
none, so anything built from `vendor/updater` stamps `unknown` and its events
count toward no epoch. Shipped engines build the updater from the mirror
checkout that the Flutter fork's DEPS pins, which stamps `a58774ab8a88`. This
copy is for CI and the Dart-to-Rust signing seam test.

`shorebird_code_push/` is the Dart package. It needs the Flutter SDK, so no CI job runs it. Only the Rust
workspace (library, library_test_hooks, patch) is built and tested in CI.

Fork-local edit on top of that snapshot: `shorebird_test_check_signature` in
`library_test_hooks/src/lib.rs` registers the test engine callbacks before
verifying, because the verifier is the engine's and the Dart-to-Rust seam test
runs without one. Re-apply it when re-vendoring.

To update: re-vendor a new commit, bump compatibility.yaml, and re-run the
compatibility suite before declaring support.
