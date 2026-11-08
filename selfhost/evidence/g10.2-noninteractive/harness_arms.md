<!-- cspell:words noninteractive precommitted unbuffer canaccept nonzero -->

# G10.2 — the harness: detector MEASURED, arms NOT RUNNABLE on this host

**Identity.** First written 2026-08-13 against tree `1b84d829`; **corrected
2026-08-13 after a verification pass found the negative control unreachable.**
`code_push_server` version **1.3.0** (`packages/code_push_server/pubspec.yaml:6`).
Dart SDK **3.12.2 (stable), macos_arm64**. CLI **1.6.115+selfhost.1** (read out
of a live `--json` envelope, see `detector_selftest.txt`). Host: **Darwin
arm64**. Script under test: `selfhost/scripts/ci_noninteractive.sh`. No device,
no mint, no release cut, no patch published. **No engine hash or cell address is
recorded here on purpose:** nothing in this lane is inside cell `4df8f9b6` or
`40eaa0ef`, and writing one in would falsely couple `G10.2` to a mint.

## Status in one line

The harness's **detector now fires and was measured on this host**; the two arms
it exists to run **still cannot execute on this Mac**. **`:2375` and `:2376`
stay NOT VALIDATED.** Nothing in this file earns them.

## Correction: the first negative control could never fire, on any host

The original third arm was `--json patch android --no-confirm` with
`--release-version` omitted, on the theory that the release chooser would then
have to prompt. **That was wrong, and it was wrong by construction rather than
by accident.** Re-derived from source:

`patch_command.dart:376-430` resolves the release in four branches. The only one
that prompts is

```dart
:396   } else if (results.wasParsed('release-version')) {
...
:402   } else if (shorebirdEnv.canAcceptUserInput) {
:403     release = await promptForRelease(releasePlatforms);
:404   } else {
:405     final flutterVersionString = await shorebirdFlutter …   // speculative build
```

and `canAcceptUserInput` (`shorebird_env.dart:292-293`) is

```dart
stdin.hasTerminal && !isRunningOnCI && !isJsonMode
```

So **every** way of making a run non-interactive — redirected stdin, any CI
variable, or `--json` — also makes `:402` false. Control falls to the plain
`else` at `:404`, which warns and does a **speculative build** to infer the
version. `--json` is the worst choice of all, because it is the very term that
disables the branch the control needs to reach. The other prompt on that path,
`patch_command.dart:1064`'s `if (confirm && shorebirdEnv.canAcceptUserInput)`,
is gated identically.

Consequence in the shipped script: the condition `rcn == 64 && neg_hits >= 1`
was unsatisfiable, `fail_count` was always ≥ 1, and the PASS branch was
unreachable. Run live, it produced exit **70** where 64 was expected and **0**
hits where ≥1 was expected. The `--skip-negative-control` escape hatch reverted
the harness to exactly the vacuous zero-hits result the control existed to rule
out. **The harness was either always-red or vacuous.** That flag is now deleted.

## What replaced it: a detector self-test that does fire

The requirement is unchanged — *a harness that cannot detect the failure it
screens for is not a harness* — so the control was not dropped, it was pointed
at a prompt site that is actually reachable:
`preview_command.dart:152-158`.

```dart
:152   } else if (shorebirdYaml != null && flavors != null) {
:153     final flavorOptions = flavors.keys.toList();
:154     final chosenFlavor = logger.chooseOne<String>(
:155       'Which app flavor?',
:156       choices: flavorOptions,
:157     );
:158     appId = flavors[chosenFlavor];
```

Three properties make it the right site:

1. **No `canAcceptUserInput` gate.** Unlike the release chooser and the two
   `confirm` sites, nothing suppresses it in a non-interactive run — so the
   prompt is genuinely reached and genuinely refused.
2. **It precedes every network call and every build.** `preview` validates only
   `checkUserIsAuthenticated` (`preview_command.dart:129-131` →
   `shorebird_validator.dart:79-89`), and `auth.dart:357-360` accepts an
   `sb_api_` value by shape alone. No project, no fixture, no `android/`, no
   server round trip.
3. **It works without `--json`,** which is what lets it measure the TTY
   predicate at all.

The script runs it twice, from a throwaway `shorebird.yaml` it generates itself:

| stage | invocation | required | measured |
|---|---|---|---|
| A | `shorebird preview` | exit 64, ≥1 line matching `running in a non-interactive context` | **exit 64, 1 line** |
| B | `shorebird --json preview` | exit 64, ≥1 `interactive_prompt_required` | **exit 64, 1 hit** |

Verbatim logs, the full run transcript, and the guard sweep are in
**`detector_selftest.txt`**. Stage B is the one that validates arm 2's literal
grep token (`json_output.dart:54`); stage A is the one that isolates the streams.

**Why stage A's refusal is attributable to the TTY predicate.** No `--json` was
passed and the preflight had already asserted that every CI-detection variable
is unset. Of the four ways to be non-interactive, exactly two were true, and
both are stream tests: `isInteractive` false because stdout is not a terminal
(`interactive_mode.dart:18-22`), and `canAcceptUserInput` false because
`stdin.hasTerminal` is false (`shorebird_env.dart:292-293`).
`_failIfNonInteractive` (`shorebird_logger.dart:135-141`) threw, and
`shorebird_cli_command_runner.dart:297-315` returned `ExitCode.usage` (64) at
`:315` — via the human branch at `:305-313` in A, the JSON branch at `:298-304`
in B.

**The self-test is host-independent, so it now runs BEFORE the Linux host gate.**
A Mac can prove the detector works even though it cannot run the arms; a new
`--self-test-only` mode stops right after it. That reordering also means every
preflight guard is now exercisable on any host.

## What arm 1 actually shows — and what it does not

Arm 1 (`release`/`patch android`, no `--json`) passes **both**
`--release-version` and `--no-confirm`. `--release-version` is consumed at
`patch_command.dart:396`, *before* `:402`; `--no-confirm` makes the `confirm &&`
at `:1064` false. **So arm 1 reaches no prompt site at all, whatever the
interactivity predicates say.**

* **It shows:** the real release+patch workflow runs to completion against our
  control plane with neither stream a terminal and without `--json` — nothing on
  the happy path needs a prompt, and the non-interactive output path (static
  `Progress`, `shorebird_logger.dart:118-128`, no ANSI) does not break it.
* **It does not show:** that the TTY predicate carried the run. A pass is
  equally consistent with the predicate doing nothing whatsoever. The previous
  version of this file claimed otherwise; that claim is withdrawn. The detector
  self-test is what exercises the predicate.

This also rescales the CI-variable argument. It remains **true** that
`isRunningOnCI` (`shorebird_env.dart:299-324`) fires on the mere *presence* of
`CI` (**`:305`** — note `containsKey`, so even `CI=false` counts) or
`GITHUB_ACTIONS` (`:321`), and that both are always set on a GitHub runner. But
the consequence is narrower than first stated: it is not that arm 1 loses a
discriminating power it never had, it is that **on a runner you cannot attribute
a non-interactive run to the streams**, because the CI term already forced the
result. So a runner can confirm the workflow completes non-interactively; it
cannot produce stage A's measurement. The preflight's CI refusal is an
attribution guard, not an arm-1 guard, and it is worded that way now.

## Why the arms did not run — and how that was actually determined

**This was an inference from an artifact-mirror probe, not an observation of the
arms failing at the artifact stage.** Stating it the other way round, as the
first version of this file did, overstates the evidence class. The chain:

**1. What a macOS host needs.** A darwin host building an Android arm64 release
downloads `android-arm64-release/darwin-x64.zip` —
`vendor/flutter/packages/flutter_tools/lib/src/flutter_cache.dart:900`
(re-derived; its linux sibling is `:909`).

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

**3. What the arms were actually observed doing on this host.** They executed
and died *far earlier than the artifact fetch*: at token parsing, exit **70**,
`auth.dart:373-381`. Re-measured here with a deliberately malformed token —
`shorebird account whoami`, stdout redirected, exit **70**, first line `Failed
to parse SHOREBIRD_TOKEN. Expected an API key (sb_api_...) or a legacy CI
token.` **No run on this Mac has ever reached the artifact stage**, so the 404 is
a *predicted* blocker for the arms, not a measured one. The Linux gate encodes
that prediction and refuses early rather than failing deep inside a build.

**4. The control plane was NOT the blocker.** `cps-android` is up and healthy on
`:18081` (`docker ps` → `Up (healthy)`; `curl /` → **200**, re-observed by the
preflight in today's run). It was left running for this lane and it was ready.

This is **NOT RUNNABLE on this host**, not "unrun", and it is why no
`ci_run_notty.log` or `ci_run_json.log` appears in this directory: fabricating
either would be total failure, and an empty file named like a result is a
fabrication. `detector_selftest.txt` *is* committed, because it is a real
measurement.

## What WAS verified here

Every preflight guard was exercised and observed to fire — the full table, with
stimuli, is in `detector_selftest.txt`. Because the host gate now sits after the
self-test, **all of them ran against the committed script unmodified**; only the
self-test-failure branch needed a mutated scratch copy (never an in-place edit —
that is the trap that cost real attribution on 2026-08-13,
`plans/README.md:157-166`). `git status --porcelain` in the worktree after the
sweep showed only the intended edit.

`shellcheck -x --source-path=SCRIPTDIR --severity=warning` → **clean** (also
clean at `--severity=style`); `bash -n` → clean.

Precondition 10 is correct that no workflow would have done this, and the anchor
is **`code_push_server.yaml:51-55`** (re-derived; the earlier `:50-54` was off by
one — `:49-50` are the comment lines). Two independent reasons it never sees
`selfhost/scripts/`: `defaults.run.working-directory: packages/code_push_server`
at `:21-23` scopes the step's `git ls-files -z '*.sh'`, and the workflow's own
path filter at `:8-14` only triggers on `packages/code_push_server/**` or the
workflow file. Cross-checked rather than assumed: `shellcheck` appears in
**exactly one** of the 13 files in `.github/workflows/` (`grep -rn shellcheck
.github/workflows/` → only `code_push_server.yaml:36,37,38,55`).

**One real defect was found and fixed by the original exercise.** The
upstream-URL guard sat *after* the reachability probe, so a misconfigured run
contacted `api.shorebird.dev` (observed: HTTP 200) before refusing. Reordered so
the refusal precedes any request. A guard that fires only after doing the thing
it forbids is not a guard.

## Against the precommitted table

Row **10** ("non-interactive run exits 0 in both arms") is **not reached** —
neither arm ran. Rows **11** (exits 64 naming a prompt) and **12** (hangs) are
likewise not reached *for the arms*. What is now reached is the row the table
does not contain: **a prompt site that IS reached exits 64 and names itself, in
both output modes, and that was measured here.**

`:2375` and `:2376` remain **NOT VALIDATED**. The self-test is a host probe and
earns **BUILT** for the harness — not for the rows, and not for the workflow.
(Those two row anchors are themselves a correction: the previous version of this
file cited `:2361`/`:2362`, which are lines of the `G10` goal *prose*, not the
rows. `PARITY.md:2377` is the token/auth row the script's empty-token guard
points at, and the PROVEN definition the script quotes is `:3582-3583`.)

## PARITY.md edits this lane would make (not applied — it is the status authority)

**`:2376`** carries the same false premise this file just retracted: *"the
harness must publish **two** releases or it proves less than it appears:
`release_chooser.dart:80-82` skips the release-selection prompt entirely when
exactly one release exists."* The one-release short-circuit at
`release_chooser.dart:80-82` is real, but ~~it is **moot for a non-interactive
harness**: the chooser is never reached at all, because
`patch_command.dart:402`'s `else if (shorebirdEnv.canAcceptUserInput)` is false
in every non-interactive posture. Publishing a second release would buy the
harness nothing.~~

> **REFUTED BY MEASUREMENT 2026-08-14 — this paragraph was wrong and arm 3's log
> was right.** `canAcceptUserInput` is **TRUE** under `< /dev/null`, because Dart
> classifies stdin by `st_mode` and `/dev/null` is a **character device**, which
> it reports as `StdioType.terminal` (Darwin and linux_x64, identical;
> `/dev/zero` behaves the same, isolating chardev as the cause). So the chooser
> **is** reached, `chooseOne` hits `_failIfNonInteractive`, and that throws
> because **`isInteractive` is false on STDOUT** — not because of stdin. Exit 64,
> chooser named, exactly as arm 3 recorded. The second release therefore **does**
> buy the harness something. Full derivation and the exposure statement:
> `STDIN_CHARDEV_2026-08-14.txt`. Proposed replacement clause:

> Fully noninteractive CI patch — same. **A second release buys nothing here:**
> `patch_command.dart:402` only reaches the release chooser when
> `canAcceptUserInput` is true, so `release_chooser.dart:80-82`'s one-release
> short-circuit is unreachable in a non-interactive run. The harness's detector
> is `preview_command.dart:152-158` instead
> (`evidence/g10.2-noninteractive/detector_selftest.txt`).

**`:2375`** — no status change. Optional addendum: *"the harness's detector was
measured on Darwin 2026-08-13 (`detector_selftest.txt`); the arm itself still
requires the Linux box."* Both rows stay `☐ NOT VALIDATED`.

## What the next worker needs

1. **A Linux run of the arms.** Ship `ci_noninteractive.sh` to the build box,
   open the two reverse tunnels (`-R 18081:localhost:18081`,
   `-R 18443:localhost:8443`), point `--app-dir` at a materialized Android
   fixture, run with stdout and stdin both redirected and `CI` unset. Run
   `--self-test-only` there first — it is one second and it proves the detector
   survived the trip.
2. **A fixture this lane may use.** `selfhost/fixtures/` today holds
   `airgap_app` (**`R6` — the script hard-refuses it**), `flavored_app` and
   `twoengine_app`; the latter two are source-only, with no `android/`. So **no
   usable Android fixture exists yet.** Materialize one with the
   `flutter create --platforms=ios,android` pattern at
   `prepare_airgap_fixture.sh:70-73`. This is a genuine prerequisite.
3. **Do not reintroduce a release-chooser control.** It cannot fire; see the
   correction above. If a control that also exercises the *control plane* is
   wanted, the candidate is `preview_command.dart:296-308`'s `promptForApp`
   (`getApps()` then an ungated `chooseOne`) — it needs a server-valid token and
   at least one app to exist, which is why it is not the default self-test.
