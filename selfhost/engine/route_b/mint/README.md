# Route B cell mint pipeline

These scripts mint a Route B cell for any engine. They build the engine, merge it into an overlay,
mint the cell address, and publish both. The cell is `route-b-cell-v2`, cell `macos-ios-android`.
The address is `sha256(descriptor)[:40]`.

Nothing about one engine or one cell is written in a script. Every value comes from one env file
per mint (`mint.env.example` documents each variable).

## Rules

- Every script that does anything else than read is plan-only until you give it `--run`.
  A plan reads and checks. It does not build, publish, tag, upload, scp, rsync or ssh.
- **OWNER** marks a step only the repo owner runs. It publishes, uploads, tags, creates a release,
  or touches ci-build. An agent writes, lints and plans these. An agent does not run them with `--run`.
- No script overwrites a file with different bytes. Installs on ci-build stop on a mismatch.
  One exception: `repack.sh --run` uploads with `--clobber`. It replaces `MANIFEST.sha256` (which covered the full
  tar) and the cell tar parts on the `cell-<A8>` release with the repacked ones.
- `rsync --delete` is used in one place only: `publish_engine.sh --pull-linux` into `$LINUX_HALF`, which the script
  owns (it refuses a non-empty directory without its `.mint-linux-half` marker). Nothing else deletes.
- Mac tars are made with `COPYFILE_DISABLE=1` and checked for AppleDouble (`._*`) entries.
- GitHub refuses release assets of 2 GiB or more. The release gets the big tar in 1900 MiB parts.
  ci-build gets the whole tar.

## Where the selfhost helpers come from

The scripts read `selfhost/` helpers (`route_b/mint_route_b_cell.sh`, `lib/v2_canonicalize.py`,
`cdn/artifact_policy.conf`, `scripts/sd1_hydrate_cell.sh`, `generate_manifest.sh`) from one commit,
`fork/main` by default. They export `selfhost/` at that commit into `$WORK/helpers-<sha>` and read it from there,
every helper, including `generate_manifest.sh`. A dirty or old checkout cannot change the address.

Run `git fetch fork` before a mint: `fork/main` is the local remote-tracking ref.
To use another commit on purpose, set `HELPERS_REF=<ref>` in the env file. The scripts then print a NOTE.
`stage_mint.sh` prints the helpers sha next to `DRY_ADDRESS` and the address. The sha is also written to
`$OUT/helpers.sha` and into the engine PROVENANCE.txt. Check it is the commit you expect.

## The previous hash

`PREV` is the last hash in the four Caddyfile protection groups. Leave it empty. The scripts read it
from the Caddyfile of the helpers commit (and, on ci-build, from the live Caddyfile).
They stop when the four groups end in different hashes. Set `PREV` only to override that.

## Files

| File | What it does | Who runs it |
|---|---|---|
| `mint.env.example` | Every setting, documented. | Copy it. |
| `lib.sh` | Shared code: env file, helpers, templates, heavy lock. | Sourced. |
| `build_engine_mac.sh` | Mac half of the engine build. | Agent |
| `build_engine_linux.sh` | Linux half. Stands alone, no env file. | **OWNER** (on ci-build) |
| `publish_engine.sh` | Pull the Linux half, merge, publish the engine overlay. | `--pull-linux`, `--run`: **OWNER** |
| `prepare_inputs.sh` | Patch zips, analyze snapshots, `artifacts_manifest.yaml`. | Agent |
| `build_compiler.sh` | Route B compiler zip and `flutter_platform_strong.dill`. | Agent |
| `stage_mint.sh` | Stage the 30 members, compute the address, bundle the cell. | `--run`: **OWNER** |
| `make_selector.sh` | The selector commit: parent E, only `engine.version` changes. | Agent |
| `repo_edits.sh` | The per-cell edits in this repo. | Agent |
| `publish_cell.sh` | Selector branch and tag, cell release, ci-build install. | **OWNER** |
| `install_on_ci.sh` | Runs on ci-build. Overlay, map and Caddyfile install. | **OWNER** (called by the publish scripts) |
| `install_manifest.sh` | Cell descriptor into the overlay on ci-build. | **OWNER** |
| `repack.sh` | Repackage the cell release for `bootstrap_selfhost.sh`. | `--run`: **OWNER** |
| `cell_edits.py` | Edits the Caddyfile, checker and Dart table. Derives `PREV`. | Called by the scripts. |
| `engine-PROVENANCE.head.tmpl` | Header of the engine `PROVENANCE.txt`. | Filled by `publish_engine.sh --build`. |
| `host-extras.names.tmpl` | The 26 host files in `host-extras-<A>.tar`. `@CELL_ADDRESS@` is the cell address. | Filled by `repack.sh`. |

The promotion script is not here. Use `selfhost/engine/route_b/promo_clone.sh`.

## Steps

Set `MINT_ENV=<your env file>` in your shell first. Every script prints a plan when run without a flag.

1. **Write the env file.** Copy `mint.env.example` to a durable path outside the repo.
   Set `E`, `DART`, `FB`, `FLUTTER_LINE`, `WORK`. Check that the engine commit and the Dart commit are pushed.
2. **Mac build.** `bash build_engine_mac.sh --run`. It stages the Mac half in `$MAC_STAGE` with a `SHA256SUMS`.
   It refuses if the tree is not at E, is dirty, or pins another Dart than `DART`.
3. **OWNER: Linux build.** Copy `build_engine_linux.sh` to ci-build and run it there with the step runner:
   `scp build_engine_linux.sh ci-build:/home/oem/`, then
   `ssh ci-build 'bash /srv/ci-cache/shorebird-engine/run_step.sh build bash /home/oem/build_engine_linux.sh --run <E>'`.
   The stage lands in `/home/oem/engine-stage/<E>`. To reuse an already synced tree, set `TREE=<path>`.
4. **OWNER: pull the Linux half.** `bash publish_engine.sh --pull-linux`. It checks the sums on ci-build
   (read-only), rsyncs the half to `$LINUX_HALF`, and checks the sums again.
5. **Extras.** `bash prepare_inputs.sh --run`. It carries the three patch zips from the previous cell
   (`PATCH_SOURCE_TAR`, checked against the previous descriptor), copies the analyze snapshots, and writes
   `artifacts_manifest.yaml` with `generate_manifest.sh`. Diff the manifest with the previous engine's. Only the hash should differ.
6. **Compiler.** `bash build_compiler.sh --run`. It needs `out/host_release_arm64_ddm` in the Mac tree.
   It holds the shared heavy lock. It builds the five Route B tools and packages the compiler zip.
7. **Merge.** `bash publish_engine.sh` (plan), then `bash publish_engine.sh --build`. This writes
   `$OUT/engine` (overlay tar, file list, map line, engine stamp, `SHA256SUMS`). Then audit it:
   `bash <helpers>/selfhost/engine/route_b/audit_route_b_compiler.sh --hash <E> --overlay $OUT/engine/merged`.
   It must print AUDIT CLEAN.
8. **OWNER: publish the engine.** `bash publish_engine.sh --run`. It splits the tar, creates the
   `engine-<E>` release on `$ENGINE_REPO`, copies the files to ci-build, and runs `install_on_ci.sh engine --run`.
   That installs the files into the CDN overlay without overwriting, adds `E FB` to `experimental_hashes.map`,
   extends the Caddyfile groups and `check_protection_matchers.py`, validates the Caddyfile in the container,
   restarts the CDN container, and checks that every file is served from the overlay.
9. **Stage the cell.** `bash stage_mint.sh` prints `DRY_ADDRESS`. **OWNER:** after you confirm `FB` and the inputs,
   `bash stage_mint.sh --run`. It mints the 30 members, writes `$OUT/ADDRESS`, `$OUT/dist`, and `$OUT/ci-stage`.
10. **Selector and repo edits.** `bash make_selector.sh --run` makes the selector commit in `SEL_CLONE`.
    Then, in a new worktree off main, `bash repo_edits.sh --worktree <dir> --run`. See "Repo edits per cell" below.
    Commit, push to `fork` only, and open the PR. Put its head sha in `CLI` in the env file.
11. **OWNER: publish the cell.** `bash publish_cell.sh` (plan), then `bash publish_cell.sh --run`.
    Before it writes anything it runs a read-only ssh check on ci-build: the live Caddyfile groups must end in `E`
    and the engine overlay for `E` must be installed. If not, it stops with nothing pushed. (`publish_cell.sh --check-ci`
    runs just that check.) Then it pushes the selector branch and an annotated tag to `$ENGINE_REPO`, creates the `cell-<A8>` release
    on `$CELL_REPO` (targeting `CLI`), copies the bundle to ci-build, runs `install_on_ci.sh cell --run`, then `install_manifest.sh --run`.
12. **OWNER: manifest only.** `bash install_manifest.sh --run` on its own, if step 11 stopped before it.
    It checks `sha256(cell_manifest.v2)[:40] == A` and installs the descriptor at
    `<overlay>/download.shorebird.dev/shorebird/cell-manifests/<A>.v2`.
13. **OWNER: promotion workspace.** Use `selfhost/engine/route_b/promo_clone.sh`. Its header says how:
    `promo_clone.sh --from promo-<old> --cell <A> --selector <SEL> --repo-sha <CLI> [--dry-run]`.
    Run it with `--dry-run` first. See `selfhost/TOOLCHAIN_PROMOTION.md`.
14. **OWNER: chain and arm B** on ci-build, as `selfhost/TOOLCHAIN_PROMOTION.md` describes.
15. **OWNER: repack the release.** `bash repack.sh` (plan), `bash repack.sh --build` (local, with the hydrate check),
    `bash repack.sh --run`. It uploads six files to the `cell-<A8>` release with `--clobber` (this replaces `MANIFEST.sha256` and the tar parts) and rewrites the notes.
    The notes come from the env file (`CLI_PR`, `ENGINE_NOTE`, `PROMO_NOTE`, `NOTES_EXTRA`).
16. **After the mint** (not here): the records PR (`compatibility.yaml`, the vendored updater pin), then the iPhone and Android runs.

## Repo edits per cell

`repo_edits.sh --worktree <dir> --run` makes these edits. It stages and commits nothing.

| File | Edit |
|---|---|
| `selfhost/cdn/Caddyfile` | Append E and A to the four protection groups. |
| `selfhost/cdn/check_protection_matchers.py` | Append E and A to its three lists. |
| `selfhost/cdn/experimental_hashes.map` | Add `E <FB>` and `A <FB>`. |
| `packages/shorebird_cli/lib/src/dart_sdk_compatibility.dart` | Add E8 and A8 with the Dart 8 hex. |
| `bin/internal/flutter.version` | Set it to the selector commit. |
| `selfhost/engine/route_b/cell_manifests/<A>.v2` | Copy `$OUT/dist/cell_manifest.v2`. |

Two edits stay by hand: add E8 and A8 to the two short-hash comments in the Caddyfile.
Run `dart test test/src/dart_sdk_compatibility_test.dart` in `packages/shorebird_cli` for the Dart table.

`install_on_ci.sh` makes the same Caddyfile, checker and map edits on ci-build, in its own copy of `selfhost/cdn`.
The repo PR keeps the repo in step with ci-build.

## What a failure leaves behind

- `install_on_ci.sh` keeps `.bak.<time>` copies of the Caddyfile, checker and map. If validation fails it restores all three and restarts the container on them, also if the checker or the restart fails.
- A stopped `publish_*.sh --run` can leave a GitHub release or tag behind. Both scripts refuse to start over an existing one.
  Delete or finish it by hand.
- `stage_mint.sh --run` deletes the earlier `dist`, `ci-stage` and `extras-tree` in `$OUT` and makes new ones. A dry run
  deletes only its own scratch (`stage`, `ov-mint`, `evidence`), so it is safe between `--run` and `publish_cell.sh`.
  Do not run `stage_mint.sh --run` again between `--run` and `publish_cell.sh --run` unless you mean to mint again.
  Other stages in `$WORK` are never deleted. Remove them when the mint is done.
