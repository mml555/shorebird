# Vendored: shorebirdtech/updater

Pinned snapshot of the Shorebird native updater (Rust), vendored so we build it
ourselves and are insulated from upstream changes.

- Upstream: https://github.com/shorebirdtech/updater
- Upstream base commit: 91dbbddb958a397868c9d8db4742a10e0f2c3832 (upstream #456, "ci: drop taiki-e actions"; the mirror merged it into route-b as a58774ab, "Merge upstream updater 91dbbddb958a into route-b")
- Source revision: 64a458f034c86bca2eff6541a19d73781728b18f, branch `route-b-91dbbdd` of mml555/shorebird-updater-mirror
  after mirror PR #14 (a merge of a58774ab and 32676dc0 whose tree equals 32676dc0's; 32676dc0 carries mirror #10 and #11).
  (the fork's route-b changes ported onto the upstream base; see SELFHOST_PORT_91dbbdd.md in this directory,
  and SELFHOST_PORT_ca91f4b3.md for the port it builds on).
  The vendored files are the tree of that commit, except `.github/`, which is upstream's at the base commit
  (91dbbddb958a): the mirror's own changes to `.github/` are mirror CI only.
- Mirror #11 (bounded diag logs, new `library/src/diag_log.rs`; a proxy refusing CONNECT is a transport error in the ureq
  builds, Linux and Windows, not Android, iOS or macOS) and #10 are now in the source revision, and so in the shipped 3.50
  engine 09c6f422 (its DEPS `updater_rev` is the source revision above). The previous snapshot of this directory
  (a58774ab plus #11 applied by hand) matched no shipped engine exactly: engine e737ede3 (cell a377ecb7) has a58774ab without #10 and #11.
- Previous snapshot: a58774ab8a88a04ae5f96ce4e5a9825561a2f2f3 (branch `route-b-91dbbdd`, upstream base 91dbbddb958a) plus mirror#11, replaced by this one;
  before it 87c198d30f875a3da317d70935e1025dc13064dd (branch `route-b-ca91f4b3`, upstream base ca91f4b3).
- Engine revision it was matched against: 09c6f4225d3ddf276fe4f3473beca79e038360b6 (shorebird-flutter, Flutter 3.50; its DEPS
  `updater_rev` is the source revision above). Checked 2026-11-22 with `diff -rq` against `third_party/updater` of the engine checkout at 64a458f0:
  the differences are the fork-local edit below, CRLF line endings in `library/.cargo/config.toml`, the unvendored `shorebird_code_push/coverage_badge.svg`,
  and `.github/` (above). Stamped revision (`updater_revision` in selfhost/compatibility.yaml): 64a458f034c8.

The revision the updater reports (`UPDATER_REVISION`, which `PolicyEpoch` keys
on) is read by `library/build.rs` from the checkout's own `.git`. This copy has
none, so anything built from `vendor/updater` stamps `unknown` and its events
count toward no epoch. Shipped engines build the updater from the mirror
checkout that the Flutter fork's DEPS pins, which stamps `64a458f034c8`. This
copy is for CI and the Dart-to-Rust signing seam test.

`shorebird_code_push/` is the Dart package. It needs the Flutter SDK, so no CI job runs it. Only the Rust
workspace (library, library_test_hooks, patch) is built and tested in CI.

Fork-local edit on top of that snapshot: `shorebird_test_check_signature` in
`library_test_hooks/src/lib.rs` registers the test engine callbacks before
verifying, because the verifier is the engine's and the Dart-to-Rust seam test
runs without one. Re-apply it when re-vendoring.

To update: re-vendor a new commit, bump compatibility.yaml, and re-run the
compatibility suite before declaring support.
