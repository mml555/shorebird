<!-- cspell:words noninteractive precommitted unbuffer canaccept nonzero -->

# G10.2 — the two harness arms: BUILT, and NOT RUNNABLE on this host

**Identity.** Written 2026-08-13 against tree `1b84d829`. `code_push_server`
version **1.3.0** (`packages/code_push_server/pubspec.yaml:6`). Dart SDK
**3.12.2 (stable), macos_arm64**. Host: **Darwin arm64**. Script under test:
`selfhost/scripts/ci_noninteractive.sh`. No device, no mint, no release cut, no
patch published. **No engine hash or cell address is recorded here on purpose:**
nothing in this lane is inside cell `4df8f9b6` or `40eaa0ef`, and writing one in
would falsely couple `G10.2` to a mint.

## Status in one line

The harness **exists and is verified as far as this host permits**; the two arms
it exists to run **cannot execute on this Mac**, for a reason verified from the
artifact mirror rather than assumed. **`:2361` and `:2362` stay NOT VALIDATED.**
Nothing in this file earns them.

## Why the arms did not run — verified, not assumed

`accept_android_default.sh:17-19` asserts "our `gen_snapshot` is linux-x64 only
and the mirror deliberately 404s host artifacts we did not build, so a release
from the Mac cannot work." That is a comment. It is now backed by evidence at
three independent points:

**1. What a macOS host actually needs.** A darwin host building an Android
arm64 release downloads `android-arm64-release/darwin-x64.zip` —
`vendor/flutter/packages/flutter_tools/lib/src/flutter_cache.dart:900`. Its
linux sibling is the adjacent entry at `:909`.

**2. What our mirror serves.** Probed 2026-08-13 against the running CDN cache
(`shorebird-cdn-cdn-cache-1`, plain-HTTP listener `:8085`), engine revision
`760e3fabffbf31b4e86919a0ef47d6ce5f182991`:

| path | code |
|---|---|
| `linux-x64/artifacts.zip` | **200** |
| `darwin-x64/artifacts.zip` | **404** |
| `android-arm64-release/linux-x64.zip` | **200** |
| `android-arm64-release/darwin-x64.zip` | **404** |

The 200/404 split falls exactly on the host axis, and the 404 is on precisely
the path `flutter_cache.dart:900` names.

**3. The control plane was NOT the blocker.** `cps-android` is up and healthy on
`:18081` (`docker ps` → `Up 5 hours (healthy)`; `curl /` → **200**;
`curl /api/v1/health` → `{"code":"forbidden","message":"Missing bearer token"}`,
i.e. alive and routing). It was left running for this lane and it was ready. The
blocker is the Android toolchain's host artifacts, not our server.

**Therefore `shorebird release android` cannot complete on this host, and the
arms belong on the Linux build box** — the same box `accept_android_default.sh`
targets, reached by the reverse tunnels its header documents
(`-R 18081:localhost:18081`, `-R 18443:localhost:8443`).

This is **NOT RUNNABLE on this host**, not "unrun". The distinction is the one
`PARITY.md` insists on, and it is why no `ci_run_notty.log` or `ci_run_json.log`
appears in this directory: **fabricating either would be total failure**, and an
empty file named like a result is a fabrication.

## What WAS verified here

Every preflight guard in `ci_noninteractive.sh` was exercised and observed to
fire. The host gate short-circuits everything after it, so the downstream guards
were driven from a **throwaway copy in the scratchpad with only the host gate
neutered** — never by editing the committed script in place, which is the
in-place-negative-control trap that cost real attribution on 2026-08-13
(`plans/README.md:157-166`).

| guard | stimulus | observed |
|---|---|---|
| host is Linux | run on Darwin | refuses, cites the 404 and prints the re-verify command |
| not `airgap_app` (`R6`) | `--app-dir .../fixtures/airgap_app` | refuses |
| `android/` present | `--app-dir .../fixtures/twoengine_app` | refuses, points at the `flutter create` pattern |
| stdout not a TTY | run under `script -q /dev/null` | **refuses** — the exact wrapper the order warns about |
| stdin not a TTY | piped stdin | passes, reports `stdin is a TTY : no` |
| CI unset | `CI=true GITHUB_ACTIONS=true` | refuses, **names both offenders** |
| token present | `TOKEN_FILE=/nonexistent` | refuses without echoing anything |
| ours, not upstream | `SHOREBIRD_HOSTED_URL=https://api.shorebird.dev` | refuses **before any network call** |

`shellcheck -x --source-path=SCRIPTDIR --severity=warning` → **clean** (also
clean at `--severity=style`); `bash -n` → clean. Precondition 10 is correct that
no workflow would have done this: `code_push_server.yaml:50-54` runs shellcheck
under `working-directory: packages/code_push_server`, so it never sees
`selfhost/scripts/`.

**One real defect was found and fixed by this exercise.** The upstream-URL guard
originally sat *after* the reachability probe, so a misconfigured run contacted
`api.shorebird.dev` (observed: HTTP 200) before refusing. Reordered so the
refusal precedes any request. A guard that fires only after doing the thing it
forbids is not a guard.

## Two design facts the order does not carry

**1. The negative control is mandatory, and it is new.** Step 22's check is
`grep -c interactive_prompt_required log.txt` = 0 in arm 2. **A broken grep, a
misnamed log, or a harness that never reached the CLI all also return 0.** So
the script adds a third arm: `patch android --json` with `--release-version`
*omitted*, which forces the release chooser
(`release_chooser.dart:76`, `:92`, `:102`) to prompt. That arm **must** exit
**64** and **must** emit `interactive_prompt_required`, and the script fails if
it does not — because a harness that cannot detect the failure it screens for is
not a harness. This is why the script also insists on two releases existing:
`release_chooser.dart:80-82` skips the prompt entirely when exactly one release
exists, which would silently defeat the control.

**2. A GitHub workflow cannot run arm 1 at all.** `isRunningOnCI`
(`shorebird_env.dart:299-324`) returns true on the mere *presence* of
`GITHUB_ACTIONS` (`:321`) or `CI` (`:307`) — note `containsKey`, so even
`CI=false` counts. On a GitHub runner both are always set, so
`canAcceptUserInput` is false **for the CI reason regardless of the TTY**, and
arm 1's entire purpose — showing that the *TTY predicate* carried the run —
evaporates. The script refuses rather than emit that vacuous pass. This is a
hard technical argument on open question 4 that the order's own framing (which
turns only on control-plane reachability) does not contain.

## Against the precommitted table

Row **10** ("non-interactive run exits 0 in both arms") is **not reached** —
neither arm ran. Rows **11** (exits 64 naming a prompt) and **12** (hangs) are
likewise not reached. The honest cell is the one the order does not print: *the
arms were not runnable on the host that holds the control plane.*

Recording that is the outcome. `:2361` and `:2362` remain **NOT VALIDATED**, and
a green preflight earns **BUILT for the harness**, not for the rows.

## What the next worker needs

1. **A Linux run.** Ship `ci_noninteractive.sh` to the build box, open the two
   reverse tunnels, point `--app-dir` at a materialized Android fixture, run it
   with stdout and stdin both redirected and `CI` unset.
2. **A fixture this lane may use.** `selfhost/fixtures/` today holds
   `airgap_app` (**`R6` — the script hard-refuses it**), `flavored_app` and
   `twoengine_app`; the latter two are source-only, with no `android/`. So **no
   usable Android fixture exists yet.** Materialize one with the
   `flutter create --platforms=ios,android` pattern at
   `prepare_airgap_fixture.sh:70-73`, or use lane C's `manual_api_app` once it
   lands. This is a genuine prerequisite, not a detail.
3. **Two releases before the negative control means anything**
   (`release_chooser.dart:80-82`).
