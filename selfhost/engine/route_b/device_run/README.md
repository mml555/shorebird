# iPhone device run

These scripts rerun the on-device checks for Route B iOS code push. This is the
canonical copy. The copies under `evidence/ios-cell-*/` are the frozen record of
past runs; do not edit them.

A run builds a small test app (bundle id `dev.selfhost.untab`), installs it,
publishes patches built from edits to its code, and watches the phone's syslog
to see which patch ran.

## Prerequisites

- A Mac with Xcode, a signing identity and a provisioning profile for the bundle id.
- `ios-deploy` and the libimobiledevice tools (`idevicedebug`, `idevicesyslog`,
  `idevicescreenshot`). `devicectl` is not used.
- An iPhone on the same network as the Mac, trusted, with developer mode on.
- A checkout of this repo at `$CLI`, with the CLI built, at the revision named by
  `cli_revision` in `../SUPPORTED_STATE.yaml`.
- The supported cell: `ENGINE_REV` is `lineage.cell_address` and `FLUTTER_REV` is
  `lineage.flutter_selector` in `../SUPPORTED_STATE.yaml`.
- A reachable real artifact CDN that serves that cell (`ARTIFACT_UPSTREAM`).
- Python 3. The control-plane server (`packages/code_push_server`) is started by
  `up.sh`.

## Setup

```sh
cp env.example.sh env.sh      # fill in every REPLACE_ME
```

Put `API_KEY` and `URL_SIGNING_SECRET` in a `secrets.sh` that exports them (the
path is `SECRETS_FILE`, default `$R/secrets.sh`). `env.sh` and `secrets.sh` are
git-ignored. Never commit them. A script stops with a message if a required
variable is missing. `DEVRUN_ENV` points the scripts at another env file.

## Scripts

All in `bin/`. Run them in this order.

1. `up.sh` starts the recording artifact origin (`origin.py`), the connection
   proxy that logs the phone's outbound hosts (`connproxy.py`), the syslog
   capture, and the control-plane server. It checks that the CLI resolves
   `ENGINE_REV`. `run_up.sh` just calls it.
2. `release.sh` creates the test app, creates the app on the server, runs
   `shorebird release ios`, re-signs the build, and installs it on the phone.
3. `steps.sh` is the regression sequence: release boots, a combined patch, a
   three-edit patch, two patches that must be refused, then a rollback.
4. `steps2.sh` is the newer set: three edits that must publish, two that must be
   refused before upload, then a rollback of the newest patch.
5. `all.sh` runs `steps.sh` then `steps2.sh`.

`lib.sh` holds the shared `launch` and `patch` helpers. Logs go to `$R/logs`
and screenshots to `$R/shots`.

`shapes/` is the test app: `main.dart` and `tally.dart` are the base, and
`variants.py` applies one named edit (or several joined with `+`) to them.
The variant names are the keys of `V` in `variants.py`.

## Rules

- Installs must be upgrade installs. Never uninstall the app. After an uninstall
  the Local Network prompt must be approved again on the phone.
- Patch numbers in `steps.sh` and `steps2.sh` (the rollback calls) assume a fresh
  release. Run `release.sh` again before rerunning the steps.
- `up.sh` leaves its processes running. Stop them with the pids in `$R/*.pid`.
