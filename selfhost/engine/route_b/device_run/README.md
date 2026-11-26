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

Releases and patches are signed. `release.sh` creates a key pair in `KEYS_DIR`
(default `$R/keys`) if none is there and reuses it otherwise. Keep `R` outside the
repo, and never commit `private.pem`.

Put `API_KEY` and `URL_SIGNING_SECRET` in a `secrets.sh` that exports them (the
path is `SECRETS_FILE`, default `$R/secrets.sh`). `env.sh` and `secrets.sh` are
git-ignored. Never commit them. A script stops with a message if a required
variable is missing. `DEVRUN_ENV` points the scripts at another env file.

## Scripts

All in `bin/`. Run them in this order.

1. `up.sh` starts the recording artifact origin (`origin.py`), the connection
   proxy (`connproxy.py`) that logs the hosts the Mac-side tooling (CLI, Flutter, Java)
   connects to; the phone does not use it, the syslog
   capture, and the control-plane server. It checks that the CLI resolves
   `ENGINE_REV`. It stops if `ORIGIN_PORT`, `PROXY_PORT` or `SERVER_PORT` is already in use:
   another server on `SERVER_PORT` would answer the readiness check and receive this run's
   app, release and patches. `run_up.sh` just calls it.
2. `release.sh` creates the test app, creates the app on the server, runs
   `shorebird release ios`, re-signs the build, and installs it on the phone.
3. `steps.sh` is the regression sequence: release boots, a combined patch, a
   four-edit patch (p03, p16, p29, p07), two patches that must be refused, then a rollback.
4. `steps2.sh` is the newer set. Run it only after `steps.sh`, because it rolls back
   patch 5: three edits that must publish, two that must be
   refused before upload, then a rollback of the newest patch.
5. `all.sh` runs `steps.sh` then `steps2.sh`.
6. `forced_partial.sh` shows the all-or-nothing rollback: a two-target patch, then
   forged copies of it that must each be refused and rolled back. See
   [Forced partial patch](#forced-partial-patch-all-or-nothing-rollback).

`lib.sh` holds the shared helpers: `launch` (under the debugger), `boot` (detached, so a
crash leaves a crash report), `crash_reports` (fetches them) and `patch`. Logs go to `$R/logs`
and screenshots to `$R/shots`.

`shapes/` is the test app: `main.dart` and `tally.dart` are the base, and
`variants.py` applies one named edit (or several joined with `+`) to them.
The variant names are the keys of `V` in `variants.py`, plus `combo` and `base`.

## Rules

- Installs must be upgrade installs. Never uninstall the app. After an uninstall
  the Local Network prompt must be approved again on the phone.
- `release.sh` wipes `$R/work` and creates a new app on the server each time, so
  patch numbers restart. The rollback numbers in `steps.sh` (2) and `steps2.sh` (5)
  assume a fresh release followed by `steps.sh`, then `steps2.sh`. Rerun
  `release.sh` before rerunning the steps.
- `R` must be a dedicated directory. `release.sh` deletes `$R/work` and `$R/signed`.
- `up.sh` leaves its processes running. Stop them with the pids in `$R/*.pid`.

## Forced partial patch (all-or-nothing rollback)

`packages/shorebird_cli/tool/route_b_forge_partial_patch.dart` is a selfhost
test instrument, not part of the shipping CLI. It publishes a Route B patch
that is built to fail, to show the engine rolling back every target the launch
attached when one target fails. The CLI refuses such a patch before upload, so
this tool is the only way one reaches the server.

It takes the container a normal `shorebird patch` produced
(`<app>/build/route_b/patch.sbrbptch`), makes its last target fail (the modes are
below), signs the new bytes with the release's patch private key, checks the
signature against the public key, and publishes a NEW patch on the same
release. It refuses to run without `--i-know-this-is-a-test-patch`.

Limits to know first:

- It only works for customer-signed releases (the device-run setup, built with
  your own key). The server answers 400 to a client `hash_signature` on a
  managed-signing release.
- The container is re-serialized, so the additive `binding` header field a real
  patch carries is dropped. The device ignores it.
- The server does not record the release's build id, so the tool cannot check
  that the container belongs to the release. It prints the container's build
  id next to the release version before publishing; comparing them is the
  operator's check.
- `--channel` is required and must already exist; the tool never creates one.
  A channel named `stable` also needs `--allow-stable`.

```sh
# after a normal `shorebird patch` (the good case: it applies)
cd $CLI/packages/shorebird_cli
dart run tool/route_b_forge_partial_patch.dart --i-know-this-is-a-test-patch \
  --container <app>/build/route_b/patch.sbrbptch \
  --private-key <private.pem> --public-key <public.pem> \
  --app-id <app_id> --release-version "$VERSION" --channel <existing channel> \
  --dry-run    # forges and verifies, publishes nothing
```

The tool forges the last target in one of three ways:

| Mode | Last target | Engine 88a7bf8c and later | Engines up to 64abe347 |
| --- | --- | --- | --- |
| default (append) | a new target with a bogus selector and a copy of the first payload | `REFUSED (target-missing)` | crash |
| `--retarget-last` | the last real target, renamed to a bogus selector, with its own payload | `REFUSED (target-missing)` | `REFUSED (target-missing)` |
| `--reuse-first-payload` | the last real target, with its own selector and the first target's payload | `REFUSED (invalid-bytecode)`, after `ROUTEB: payload library <uri> is already loaded` | crash |

Engines up to 64abe347 (cell 97f91aff) load a target's payload before they look
up its selector. When the payload's library is already loaded, the app crashes
(a segfault in `Exceptions::JumpToFrame`) instead of rolling back. Later engines
look up the selector first and refuse an already-loaded library
(dart-sdk-shorebird-lineage#10). Only `--reuse-first-payload` reaches that
check. The append mode is refused earlier, at the selector.

`--retarget-last` and `--reuse-first-payload` need a patch built from two edits in
different functions, such as `p06_async_return+p03_setstate_closure`, whose last
payload differs from the first (the tool checks). In the forged patch, N in the
expected line below is the number of targets before the last one.

`bin/forced_partial.sh` runs the whole sequence: the two-target patch, then each
mode in `FORGE_MODES` (default all three; use `FORGE_MODES=retarget-last` on
engines up to 64abe347). Each forged patch is downloaded, booted twice and then
skipped, and the script lists any crash reports. Logs go to
`$R/logs/forced_partial`.

The forged container is always written to `<container>.partial` (or `--out`).
Drop `--dry-run` to publish; it needs `SHOREBIRD_TOKEN` and
`SHOREBIRD_HOSTED_URL` (what `env.sh` exports) and the engine `patch` tool
(`$CLI/bin/cache/artifacts/patch/patch`, or `--patch-tool`). `--bogus-selector`
overrides the fake name.

Expected device log. The normal patch applies and the app shows the patched
behaviour. The forced partial logs the forged target as `REFUSED (...)`, with the
reason the table gives, then

```
rolled back N/N attached targets, main runs the release code
```

where N is the number of real targets the patch attached: 1 for a one-target
patch. The app shows release behaviour, not the patched one. The updater then
marks the forged patch bad (`Patch <n> is known bad, skipping`), and the next
boot runs the previous patch again.
