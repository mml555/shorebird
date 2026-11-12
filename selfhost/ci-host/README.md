# CI runner host (ci-build)

How the home server `ci-build` (Ubuntu) runs GitHub Actions jobs for this fork, kept here so
it can be rebuilt and reviewed. Nothing in this directory is a secret: the runners'
registration tokens live in `/etc/gha` (root only, 0700) and are never copied here.

## What runs where

| Piece | Where on the host | Source here |
|---|---|---|
| One ephemeral runner per job user, `gha-runner@<user>.service` (users `gha-sb1`..`gha-sb5` for `mml555/shorebird`, `gha-upd1` for `mml555/shorebird-updater-mirror`; `gha-sb5` is installed but not enabled) | `/etc/systemd/system/` | `systemd/` |
| `gha-prep` (root, before each start: checks the user, wipes HOME, loads the firewall, registers the runner), `gha-run` (starts a rootless Docker and the runner), `gha-dockerd` | `/usr/local/sbin/` | `bin/` |
| Per-runner config and the proxy environment jobs see | `/etc/gha-runners/<user>.conf`, `proxy.env` | `runners/` |
| squid proxy on `127.0.0.1:3128` and `10.0.2.2:3128`, allowlist | `/etc/squid/` | `squid/` |
| nftables `table inet gha_egress`, built by `gha-egress-apply` at boot (`gha-egress.service`) and at every runner start | kernel | `bin/gha-egress-apply` |
| `gha-egress-denied`: which hosts the proxy refused | `/usr/local/sbin/` | `bin/` |
| Docker Hub pull-through cache on `127.0.0.1:5000` (root-owned, jobs cannot push) | `docker-registry.service` | `provision.sh` |

Each runner takes one job and exits (ephemeral). systemd then kills the whole cgroup, and
`gha-prep` wipes the user's HOME and registers a fresh runner. Jobs never share state.

Install: `sudo bash selfhost/ci-host/provision.sh` once (packages, Rust, runner tarball, users),
then `sudo bash selfhost/ci-host/install.sh` after any change here. `install.sh` is idempotent
and safe while jobs run: it never starts or restarts a runner.

## Security model

The first gate for pull requests from forks is the repository's approval policy, **all
external contributors** (Settings, Actions, General). A fork PR does not run until a
maintainer approves it. Everything below limits the damage if an approved job is hostile.

- Runner users have no sudo, no `docker` group (each has its own rootless Docker), no
  group at all, and cannot read `/home/oem` or `/etc/gha`. `gha-prep` refuses to start a
  runner whose user is in `sudo`, `docker`, `lxd`, `adm`, `kvm`, `root`, `disk` or
  `shadow`, or has a sudoers entry.
- Outbound traffic of runner users is dropped by nftables except to the proxy
  (127.0.0.1 and 10.0.2.2, port 3128), the registry cache (127.0.0.1:5000) and loopback
  ports used between a job's own processes (5432/6379, the ephemeral range and the
  user's Docker port slice; the loopback bullet below limits who may listen there).
  No direct DNS, no direct internet, IPv4 and IPv6. "The user's traffic" means the
  user's uid, its `/etc/subuid` range and anything in its `gha-runner@<user>` cgroup, so
  a process in a user namespace (rootlesskit, `docker run --network host --user N`) is
  covered. The proxy allows only the hosts in `squid/` (by name: an IP-literal target
  matches nothing) and never reaches private or loopback addresses.
- Loopback between jobs: a job may connect to a loopback listener only if the listener
  belongs to its own runner unit's cgroup. Host services (anything the owner starts at
  any time), other runners and processes outside the unit are unreachable. This is
  checked per connection, not from a list that can go stale; see the comment at the top
  of `bin/gha-egress-apply`. The exceptions, for the Android e2e job, are the device
  pool on `127.0.0.1` (`qa-pool` API 5550, the phones' adb relays 5601/5603/5605) and the
  CDN mirror (8085, on `127.0.0.1` and `10.0.2.2`). A listener a runner opens on one of
  those ports is still dropped, so a job can't pose as one of them.

### Accepted risks

squid sees only the host name of a `CONNECT`, not the path, and we do not intercept TLS.
So an allowed host is allowed for every URL on it. These stay because jobs need them:

| Host | Why it stays | What it still allows |
|---|---|---|
| `github.com`, `api.github.com` | clone, releases, the API | pushing to any repo, with credentials the job brings itself (the job's own `GITHUB_TOKEN` only reaches this repo) |
| `storage.googleapis.com` | the Dart SDK archive and pub packages | uploading to any bucket |
| `*.actions.githubusercontent.com` | runner control, logs, results; shard names change (`pipelinesghubeus22`, `run-actions-2-azure-eastus`, ...) | GitHub-operated services only |
| `productionresultssa<N>.blob.core.windows.net` | artifacts, logs, caches; GitHub adds numbers over time | an Azure storage account with a free number could be registered by someone else |
| `registry.npmjs.org`, `pub.dev`, `index.crates.io`, `static.crates.io`, `ghcr.io` | dependencies, image pushes in the release workflow | publishing, with the job's own credentials |
| `services.gradle.org`, `downloads.gradle.org`, `plugins.gradle.org`, `plugins-artifacts.gradle.org`, `dl.google.com`, `repo.maven.apache.org` | Gradle and its dependencies for the Android e2e job's release and patch builds | publishing to the plugin portal or Maven Central, with the job's own credentials; `dl.google.com` serves every Google download, not only Maven |
| `dl-cdn.alpinelinux.org`, `deb.debian.org` | `apk` / `apt-get` in image builds (the cargo-deny image, the `code_push_server` runtime stage) | plain HTTP on port 80: squid matches only the host, so any path or query string to the CDN goes out. Small, but a channel |

Removed on 2026-11-08 after reading the proxy log (it covered only about 2.5 hours, so
only entries with an obvious replacement were cut): `crates.io` (cargo's sparse registry
needs `index.` and `static.`, not the bare name), and `registry-1.docker.io`,
`auth.docker.io`, `production.cloudflare.docker.com` (images come through the pull-through
cache, which fetches them itself; no job ever used the Hub directly). If a job needs one
back, add it as below.

| the registry cache on `127.0.0.1:5000` | image pulls | the cache runs as root and fetches any public path on `registry-1.docker.io` for any job (an arbitrary public image, or data encoded in an image name). It is not on the allowlist, but it is not closed either |

Also accepted, with the device pool and mirror open to jobs (runners only run this
repo's workflows, and PRs from forks wait for the owner's approval):

- **qa-pool trusts local callers.** For a caller on `127.0.0.1` the owner name is the
  only check, and `GET /status` lists every owner. So a job can renew, release or change
  the network of any phone's lease, including one the owner's other projects hold. A
  per-caller secret in qa-pool would close this; it is not in this repo.
- **adb has no authentication.** A job can drive any pool phone over its relay, held or
  not, and a phone's own network (slirp) reaches qa-devices and the home LAN without
  this allowlist.
- **The mirror fetches what it is asked for.** Any `storage.googleapis.com` path it
  proxies is cached for a year, so a job can pull public objects through it and grow its
  disk. It has no write path.

Also accepted: nftables does not cover Unix sockets. Abstract-namespace sockets belong to
the network namespace, which jobs share with the host (dockerd runs in it). Today
`/var/run/docker.sock` is `root:docker 0660` and `/run/containerd` is closed to the
runner users, so nothing reachable is lost; re-check if a host service adds an
abstract or world-accessible socket.

Also accepted: a job can read everything in its own HOME and the checked-out repo, and can
use the CPU, disk and the allowed hosts while it runs. A job cannot outlive its unit.

## Image builds with buildx

The registry mirror in the rootless dockerd's `daemon.json` and the proxies in
`~/.docker/config.json` (both written by `gha-run`) apply to `docker pull`, `docker run`
and the classic `docker build`. A `docker-container` buildx builder, which
`docker/setup-buildx-action` creates, gets neither: BuildKit runs in its own container and
resolves names itself, which the firewall drops. A workflow that creates one on these
runners must hand it the proxy (`https_proxy`, `http_proxy`, and `no_proxy` including
`10.0.2.2`) as driver env and point `docker.io` at the cache as `10.0.2.2:5000` (plain
HTTP), as `.github/workflows/release_code_push_server.yaml` does.

## Add an allowed host

```sh
sudo $EDITOR /etc/squid/gha-allowlist.txt     # a name, or .example.com for all subdomains
sudo squid -k reconfigure                     # no runner restart, running jobs keep their tunnels
```

Then make the same edit in `squid/gha-allowlist.txt` here (or edit here and run
`install.sh`, which does both). Patterns that need a regex go in `gha-allowlist.regex`.
Prefer an exact name over a leading dot, and say in the PR why the job needs it.

## Read the deny log

```sh
sudo gha-egress-denied --since 1h      # count, last seen, host; --since 30m, 2d, ...
```

A job that hangs or fails on a download is usually a denied host. Only the proxy's refusals
show up there. Traffic that tried to bypass the proxy is dropped by nftables and logged to
the kernel log (rate-limited to 10 per minute):

```sh
sudo journalctl -k --since -1h | grep gha-egress-drop
sudo nft list chain inet gha_egress gha     # per-rule counters
```

## Logs

`/var/log/squid/access.log` is rotated daily by Debian's `/etc/logrotate.d/squid` (compressed,
2 days kept; `squid.conf` sets `logfile_rotate 0` so squid only reopens the file on the
signal). `gha-egress-denied` reads the current and the previous day. The nftables drop log
is limited to 10 per minute (burst 5).

## Watch the runners

`bin/gha-watch` runs from the owner's (`oem`) cron every 10 minutes, with no root, and warns when

- a runner unit failed to start 3 times in a row (`Failed to start gha-runner@<user>` in the
  journal with no `Started` after it; `gha-prep` ends that way when it cannot register), or
- a run of `mml555/shorebird` or `mml555/shorebird-flutter` has been queued over 20 minutes,
  or a job of an in-progress run has.

A read that fails (journal, API, rate limit) is logged as `NOTE (could not check)` and never
counts as all clear: exit status 2, and an open issue stays open.

**Where a human sees it.** Without a token, nobody is paged. The warnings are in
`~/.local/state/gha-watch/current` (the last run), and `install-watch.sh` makes every
interactive login to `oem` run `gha-watch --show`, which prints them with their age and
says so when the watcher itself has not run for 30 minutes (cron stopped). History is in `warnings.log` there (written on
change, and hourly while they last). Check by hand:

```sh
gha-watch --show; tail -3 ~/.local/state/gha-watch/warnings.log
```

**Issue on the fork.** Put the token in `~/.config/gha-watch.env` (the installer creates it
empty, mode 600; it is read as `KEY=value` lines and ignored unless owned by `oem` with mode
600). The token is a fine-grained PAT with Issues read and write on `mml555/shorebird`, kept
out of the repo. Or run `gh auth login` as `oem`.

```sh
echo 'GH_TOKEN=github_pat_...' >> ~/.config/gha-watch.env
```

Then it opens one issue titled "CI host alert: ..." with the label `gha-watch`, comments at
most every 6 hours while the warnings last, adopts an existing open issue with that title instead of duplicating it, and closes it when
everything is clear (a problem that returns after that gets a new issue at once). A failing `gh` call is logged and gives exit status 2.

**API use.** The token goes to `curl` in a 0600 header file, never on a command line. Without
a token the public API allows 60 requests an hour for the host's address; the watcher makes at
most 6 a run (36 an hour) and stops early when the headroom runs low. With a token it makes at
most 40 a run. Thresholds and repos can also be set in the env file (see the script's header).

```sh
bash selfhost/ci-host/install-watch.sh      # as oem; copies the script, cron line, login snippet
```

## A runner will not start

`systemctl list-units 'gha-runner@*'` shows `activating (start-pre)` while `gha-prep` works,
and keeps showing it if it fails and retries. Read why:

```sh
sudo journalctl -u gha-runner@gha-sb1 --since -10min | grep gha-prep
```

`gha-prep` logs GitHub's own message when it cannot get a registration token (for example
"API rate limit exceeded" when the token's account used up its hourly quota, or "Bad
credentials" for an expired or revoked token). After a failed registration `gha-prep`
backs off before it touches anything (1, 2, 4, 8, then 15 minutes, plus up to 30 s of
jitter; if GitHub named the end of a rate limit it waits for that), and it resets the count
only when `config.sh` succeeds. A token file newer than the last failure skips the wait.
To skip it by hand: `sudo rm /run/gha-prep/<user>.*` and `sudo systemctl restart
gha-runner@<user>` (only when no `Runner.Worker` is running for that user).

## Add a runner

1. Add a line to `RUNNERS` in `provision.sh` and a `runners/<user>.conf` (copy one; pick a
   free `GHA_PORT_RANGE` of 1000 ports below 32768).
2. On the host: `sudo bash provision.sh` (creates the user), `sudo bash install.sh`.
3. The token file named in `GHA_TOKEN_FILE` must exist in `/etc/gha` (the owner puts a
   fine-grained PAT there; it is never in git).
4. `sudo systemctl enable --now gha-runner@<user>`. `gha-prep` reloads the firewall first,
   which adds the new user to it.

Never restart a runner that is running a job (`pgrep -a Runner.Worker`).

## Rollback

- A change here: revert the commit and run `install.sh`. For the firewall script alone,
  the previous version stays valid; re-run `gha-egress-apply` to load it.
- Emergency, firewall: `sudo nft delete table inet gha_egress` opens egress for runner
  users (the next runner start or `gha-egress-apply` rebuilds it; `gha-prep` re-creates it at
  every start and refuses to start the runner if that fails). `gha-egress.service` does
  not remove the table when stopped, so restarting it never opens egress.
- Emergency, proxy: `sudo systemctl stop squid` blocks all job traffic (the jobs fail, nothing leaks).
- Disable one runner: `sudo systemctl disable --now gha-runner@<user>`, after its job ends.
