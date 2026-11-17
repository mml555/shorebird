# ~/shorebird-engine/bin

Workflow scripts for the Flutter fork trees. Each prints its plan first and runs with
`set -euo pipefail`. Re-running is safe, but `sync` and `bootstrap.sh` are not no-ops
(they rewrite `.gclient` and re-run `gclient sync`). Shared helpers are in `lib.sh` (sources `../env.sh`).
Full guide: `selfhost/FLUTTER_FORK.md` in the shorebird repo. These files are symlinks into
`selfhost/flutter_fork/` of a shorebird checkout, made by its `install.sh`.

| Script | Purpose |
|---|---|
| `new-branch NAME [--from REF] [--engine] [--tree TREE] [--dry-run]` | Framework work: worktree under `~/Developer/shorebird-wt/fl-NAME`. Engine work: APFS clone `flutter-NAME` without `out/`. |
| `sync [TREE] [--dart-rev SHA\|none] [--dry-run]` | Fetch remotes, then under the heavy lock set the Dart revision override in `.gclient` and `gclient sync`, verify the Dart checkout, relink SDKs. Refuses the frozen tree. |
| `build TREE CONFIG... [-j N] [--dry-run] [--gn-only] [--allow-frozen]` | gn plus ninja for `ios_release`, `ios_release_rb`, `host_release_arm64`, `host_release_arm64_ddm`. Heavy lock, caffeinate, pid file, log in `logs/`. -j capped at 8. Refuses the frozen tree; `--allow-frozen` is owner-only. |
| `promote TREE [--repo DIR]` | Read-only checks along the TOOLCHAIN_PROMOTION chain. Prints, never applies, the `compatibility.yaml` change. |
| `clean [TREE] [--configs a,b] [--dry-run] [--include-supported] [--allow-frozen]` | List `out/` by size and age; delete only named configs (takes the heavy lock); configs named like the supported cell's are protected in any tree. List-only on the frozen tree (`--allow-frozen` is owner-only). |

Trees: `flutter` (alias `347`) is frozen at d0714887, the supported cell's engine; never
modify it. `flutter-350` (alias `350`) is the Flutter 3.50.0 port, branch `selfhost/3.50`.

Heavy work is serialized by `mkdir ~/Developer/shorebird-wt/tmp/heavy.lock`. Never delete
Time Machine snapshots; if a write fails for space, stop and report.
