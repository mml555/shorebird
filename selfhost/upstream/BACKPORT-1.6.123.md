# CLI backport — upstream 1.6.116..1.6.123 onto 1.6.115+selfhost.2

**PM ruling, 2026-09-25: option B.** Backport the compatible upstream CLI surface
onto the existing 1.6.115 self-hosted line. This is **not** a 1.6.123 pin
promotion, and nothing here claims compatibility with 1.6.123.

## Why not promote

"Promotion to 1.6.123" turned out to mean:

| | pinned (unchanged) | upstream 1.6.123 |
|---|---|---|
| Flutter | 3.44.8, fork commit `a4a3c0d1` (`c15ef637` + channel fix) | 3.47 line, `ff900e7f` (still lacks the channel fix) |
| engine | `69f9831c`; Route B cell on `selfhost/3.44.8-v13-cell-…` | `c663a268` |
| Dart | 3.12 | 3.13 |
| updater | fork `af6e842c` | `b0aa3dd`, per upstream's 1.6.121 prep; later releases not checked |

That is an engine programme covering Route B, Mutable-AOT, iOS engine/signing,
updater integration and the full toolchain closure. It is recorded separately in
[`ROADMAP.md`](../ROADMAP.md) under *Parked*, and must not happen as a side
effect of wanting CLI commands. `ff900e7f` is not in the owned Flutter mirror.

## Unchanged by this backport

Flutter `a4a3c0d1`, engine and Route B cell, Dart 3.12, the updater fork, M5
state, and the stock-toolchain promotion status (still 1.6.115). No pubspec or
`pubspec.lock` change. The only version that moves is the CLI build:
`1.6.115+selfhost.1` → **`1.6.115+selfhost.2`**.

## Method

For each upstream commit: dependency check (Flutter 3.47 API, Dart 3.13,
updater, server APIs we do not implement), then classify, then cherry-pick
(`-x`) or adapt in upstream order. Every adapted commit carries a
`[selfhost backport]` note in its message saying what differs from upstream.
Backport commits are limited to `packages/` plus the cspell word list.

Dart compatibility is tested, not inferred. Local Dart is **3.12.2**, the
version the pinned Flutter ships, and upstream's SDK constraint is still
`>=3.9.0` at 1.6.123. `dart pub get --enforce-lockfile` resolved against the
unchanged lockfile. `dart analyze` shows **0 errors** and the same 3 warnings as
`experimental` in `shorebird_cli`, `shorebird_code_push_client`,
`shorebird_code_push_protocol` and `shorebird_build_trace`. The only new items
are 5 lint *infos* (import ordering, cascades, one long line) in verbatim
upstream code.

## Matrix — CLI candidates

Dependency columns: **F** = Flutter 3.47 API, **D** = Dart 3.13, **U** =
updater, **S** = server API we do not implement. "–" means none found.

| upstream | change | F | D | U | S | disposition | branch commit | evidence |
|---|---|---|---|---|---|---|---|---|
| `119406bba` | link-failure hint describes the checks that run | – | – | – | – | **clean** | `0fdea00a2` | suite |
| `e8741c31f` | CI/build fix: tracer seeded in integration scope, link-failure tests | – | – | – | – | **adapted**: fork already had its `await` fix; `.github`/release-notes hunks dropped | `2c40dc8f6` | suite |
| `008cc5a33` | layered icons no longer reported as changed assets | – | – | – | – | **clean** | `019ebf4ad` | suite |
| `bcaa1fc31` | `patches rollback` / `rollforward` | – | – | – | rollforward | **adapted** (cspell only). Rollforward kept, fails explicitly (server 501) | `bef627f21` | suite; integration §rollback, §rollforward |
| `1ef0831dd` | precache stamp + staging-dir clone for Flutter installs | – | – | – | – | **deferred: needs adaptation**, conflicts with a certified contract, see below | — | — |
| `6ff87e57e` | point at plugins using legacy `flutter.jar` | – (jar removed in Flutter 1.12; applies to 3.44.8) | – | – | – | **clean** | `179aa9246` | suite |
| `5b13bfca2` | `apps list/rename/transfer/delete`, `channels list/create/delete` | – | – | – | `DELETE /apps/{id}` | **clean**. `apps delete` has no server route, **ruling needed** | `37e66c9b7` | suite; integration §apps, §channels |
| `a8076a137` | dependabot: 16 dependency bumps | – | ? | – | – | **not applicable**: no backport needs it, and a backport must not move the lockfile | — | builds without it |
| `ec9b974fe` | plan level in `account whoami` | – | – | – | `GET /plan` | **blocked by policy** (`/plan` omitted) | — | integration: `whoami` unchanged |
| `b3adb1487` | keep a pubspec comment with its key on `init` | – | – | – | – | **clean** | `b654d7060` | suite |
| `534afd18c` | `--no-clear` for protocol regen with space_gen ≥1.4 | – | – | – | – | **not applicable**: we lock space_gen 1.3.0, which has no clearing behaviour; dev tooling only | — | `pubspec.lock` |
| `c5ef7a41e` | ignore asset-catalog toolchain versions when diffing | – | – | – | – | **clean** | `e7871436a` | suite |
| `c74e18a8d` | name the next step in iOS patcher errors | – | – | – | – | **clean** | `8a7fc1ef8` | suite |
| `19fb22ed6` | signing-flag mistakes are usage errors naming the flag | – | – | – | – | **adapted** to the fork's multi-platform `createPatch(List)` | `de7930269` | suite |
| `1685d78b5` | download time in build traces | – | – | – | – | **adapted**: spans wrap the fork's own clone and precache, not `1ef0831dd`'s | `8d45a8ac7` | suite |
| `3408dbfed` | report when a patch is missing `libapp.so` | – | – | – | – | **adapted** (additive merge beside fork helpers) | `3965cd5e7` | suite |
| `a86dbc12a` | deflake throttled-progress test | – | – | – | – | **clean**; fixes the one baseline failure | `72b91267b` | suite |
| `dea22a522` | `--flutter-version=fvm` / `=system` | – | – | – | – | **adapted** (git-URL override kept; test expects fork's `releasePlatform`) | `ec39d6676` | suite |

`dea22a522` does not bypass the pinned toolchain. `system`/`fvm` resolve only to
a version *number*, which then goes through the same revision lookup and
coherence gate as an explicit `--flutter-version`.

The survey (`ADOPTION-1.6.123.md` §2) said "nine" CLI-only fixes but listed ten.
This matrix is exhaustive over all 42 commits instead.

## Matrix — everything else in 1.6.115..1.6.123

| upstream | disposition |
|---|---|
| `3c301e47d` `45facdd4e` `ebb7ac37a` `cdd0edf0e` `5ac7f9a9a` `a0606c9a3` `59ab14685` `c6d18d195` (release prep) | **not applicable**: version string only (`a0606c9a3` also moves `flutter.version`). We version as `+selfhost.N` |
| `50bbc1b82` `cf5334d02` `adccd7616` `d5fab4e14` `dd08e3053` `9984e6db9` `a37ab3005` (Flutter bumps) | **blocked by policy**: the 3.47 programme, not this backport |
| `98adec243` `b6f1120cb` (`stripe_api`) | **blocked by policy**: upstream SaaS billing |
| `81b6c2550` `9ff2f6e4b` `f3964e580` `6c9dc1d0d` `56d8d4c36` `1c90cb761` `076ea64bf` | **not applicable**: upstream CI, README, vendored-package publishing, release-notes spellcheck |

## Deferred: `1ef0831dd`, precache and resume

A semantic conflict, not a textual one. The fork's `installRevision` runs
`flutter precache` for the target platform on **every** call. That is the
hydration contract behind Route B releases (`558a78d59`, `cce82dc7f`), adopted
after a correctly published cell refused with `COHERENCE_UNDETERMINABLE` because
a checkout existed without its engine. Upstream precaches **once**, writes a
stamp, and skips afterwards. Taking it as-is would silently weaken a certified
fail-closed gate.

Its real value, atomic staging-directory publication so an interrupted clone
cannot poison the target, is compatible with the fork. A correct adaptation takes
the staging/reclaim half and leaves precache unconditional. That is its own
change, reviewed against the hydration evidence. It is not something to fold
into a CLI sync.

## Test evidence

Artifacts are in `selfhost/evidence/cli-backport-1.6.123/`.

**`shorebird_cli` suite** (Dart 3.12.2, `dart test`):

| tree | result |
|---|---|
| `experimental` (baseline) | 2740 pass, **1 fail**: the throttled-progress flake `a86dbc12a` fixes |
| backport, first run | 2939 pass, 2 fail: the new fvm/system tests verified `installRevision` without the fork's `releasePlatform` argument (lib correct; the call log shows `releasePlatform: android`). Test adapted in `ec39d6676` |
| backport, final | **2941 pass, 2 skipped, 0 fail** (`cli_suite_final.txt`) |

`shorebird_code_push_client` +112 (1 skipped), `shorebird_code_push_protocol`
+363, `shorebird_build_trace` +48: all pass.

**Command-level integration.** The compiled backport CLI ran against a live
self-hosted server built from the same tree (SQLite): `start_and_seed.sh`, then
`cli_integration.sh`. **22/22 pass** (`cli_integration.out`). Server-side state
was checked independently of CLI output:

* `patches rollback`: rolls back; device patch-check returns
  `rolled_back_patch_numbers: [1]`. A repeat reports "already rolled back" (304)
  and exits 0; `--require-change` exits 64; `--json` reports `changed: false`.
* `patches rollforward`: exits 70 with the server's own message, *"Rollforward
  is not supported by this self-hosted server: a rolled-back patch is withdrawn
  permanently. Publish a new patch instead."* The patch stays rolled back.
  Under `--json` the error object carries upstream's generic "Failed to roll
  forward patch 1…", and the server reason is printed on the line above.
* `apps rename`: server `display_name` changes.
* `channels create/list/delete`: `--confirm-name` required; `stable` refused
  ("The stable channel is permanent"); `qa` deleted and hidden from listings.
* `apps transfer`: into the current org is a no-op (the CLI still prints
  "Moved … into"); into an org the caller is not in, the CLI refuses before
  calling the server.
* `apps delete`: exits 70 with "No route DELETE /api/v1/apps/…"; app intact.
* `account whoami`: unchanged; no `/plan` call.

## Open before tagging `+selfhost.2`

1. **`apps delete` ruling.** New upstream surface (1.6.115 had no app-delete
   command) calling `DELETE /api/v1/apps/{id}`, which the server does not
   implement. It currently fails safely but with a generic "No route" message.
   It is destructive (releases, patches, artifacts). Options: implement,
   refuse explicitly (like rollforward), or remove the command from the
   self-hosted CLI.
2. **A real `shorebird release` + `patch` smoke** through the self-hosted stack.
   Several backported fixes run inside release/patch (signing-flag validation,
   trace spans around install/precache, asset-diff filters, `libapp.so` /
   `flutter.jar` diagnostics). None changes artifact bytes, the updater or the
   device wire contract, but only a real build proves the release path is
   intact. `compatibility.yaml`'s `cli_version` stays `1.6.115+selfhost.1`
   until that passes and the release is cut.
