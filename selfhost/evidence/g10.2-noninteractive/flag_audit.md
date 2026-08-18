<!-- cspell:words noninteractive unvalidated precommitted PIPESTATUS pipestatus authorised behavioural -->

# G10.2 — the non-interactive guard, measured rather than rebuilt

**Identity.** Read and run 2026-08-13 17:25 EDT. CLI under test: `~/.shorebird`
at **`ba4e1c02`** (its own checkout — it does **not** move when this repo is
committed). Control plane: **`cps-android`**, started this session, `:18081`,
own bind mount `shorebird-rig/control-plane/cps-android` and own
`code_push.db` — no state shared with `cps-ios`. Dart SDK 3.12.2. No device, no
mint, no release cut.

## The machinery is BUILT — this lane measures it, it does not build it

All four prompts fail fast rather than hanging, each via `_failIfNonInteractive`
(`packages/shorebird_cli/lib/src/logging/shorebird_logger.dart`): `confirm`
`:56-57`, `chooseOne` `:65-72`, `prompt` `:85-91`, `promptAny` `:99-104`. The
guard, verbatim at `:136`:

```dart
if (isInteractive && shorebirdEnv.canAcceptUserInput) return;
```

It throws `InteractivePromptRequiredException` (`:137-140`), which the runner
catches at `shorebird_cli_command_runner.dart:297` and turns into
`ExitCode.usage` at `:315`, emitting `interactive_prompt_required` under `--json`
(`json_output.dart:54`). **So `G10.2` is a harness, and a harness that does not
break one of the guard's conditions measures nothing.**

### Two facts the order does not carry, both of which change harness design

**1. The two halves test different streams.**

```dart
// interactive_mode.dart:18-22
bool get isInteractive {
  if (isJsonMode) return false;          // :19 — short-circuits before any TTY test
  if (io.stdout.hasTerminal) return true;
  return io.stdioType(io.stdout) == io.StdioType.terminal;
}
```

`isInteractive` tests **stdout**. `canAcceptUserInput`
(`shorebird_env.dart:292-293`) is
`stdin.hasTerminal && !isRunningOnCI && !isJsonMode` — it tests **stdin**. The
guard ANDs them, so **a run with a TTY stdout but piped stdin still throws.** An
arm that redirects only one stream is not testing what its author thinks.

CI detection (`shorebird_env.dart:299-324`) fires on `BOT=true`, `TRAVIS=true`,
`CONTINUOUS_INTEGRATION=true`, or the mere presence of `CI`, `APPVEYOR`,
`CIRRUS_CI`, `JENKINS_URL`, `GITHUB_ACTIONS`, `TF_BUILD`, or `AWS_REGION` **and**
`CODEBUILD_INITIATOR` together.

**2. `--no-confirm` and the release-selection prompt are different prompts.**
`--no-confirm` gates only "Would you like to continue?"
(`patch_command.dart:1064-1065`), and that call *already* requires
`canAcceptUserInput`. Choosing **which** release to patch is a separate
`logger.chooseOne` (`release_chooser.dart:92` and `:102`, message built at
`:76`), whose escape hatch is `--release-version`. Note also
`release_chooser.dart:80-82` skips the prompt entirely when exactly one release
exists — **so a harness whose app has one release proves less than it appears
to**, and must publish two before the arm means anything.

## The orphaned flag — reported, not silently "fixed"

`CommonArguments.noConfirmArg` (`common_arguments.dart:177-182`) is **defined and
never used**: a tree-wide grep of `packages/shorebird_cli` returns exactly one
hit, its own definition. It is never registered on a command and never read.

What actually parses `--no-confirm` is the negatable `confirm` flag —
`patch_command.dart:115-118` and `release_command.dart:131-134`, both
`addFlag('confirm', hide: true)` with no `negatable: false`, read at
`patch_command.dart:215` and `release_command.dart:250`. Because it is
`hide: true` it never appears in `--help`, which is almost certainly why a
harness comment came to claim the flag did not exist.

**Left in place, annotated rather than deleted.** `common_arguments.dart` is
upstream code that this fork otherwise keeps pinned; deleting a dead descriptor
buys nothing functional and costs a merge conflict at every future sync. The
reader-misleading problem the order names is solved by saying so here and in §10.

## The two script comments — one corrected, one verified true

| script | verdict |
|---|---|
| `accept_android_default.sh:125-126` | **FALSE, corrected.** It said `--no-confirm` does not exist on `patch`. It does. Proven twice: the flag registration above, and the fact that **the same script already passes `--no-confirm` to `shorebird release android` twenty lines earlier**. Only comment text changed — `yes \|` (now `:144`) and `rc=${PIPESTATUS[1]}` (now `:146`) are untouched, verified by a diff that shows no non-comment line, and `shellcheck -x --severity=warning` is clean |
| `airgap_acceptance.sh:240-243` | **TRUE, left alone.** It says `--no-confirm` does not answer "Which release would you like to patch?" — correct, per the two-prompt distinction above. That script runs from a terminal via `airgap_run.sh:20`, where stdout and stdin are both TTYs and `CI` is unset, so the guard returns without throwing and `chooseOne` blocks on stdin exactly as the comment says. Rewriting it would replace a true statement with a false one |

## Token arms — `:2363` and `:2364`

Three arms, `shorebird account whoami` against `cps-android`, **stdout redirected
to a file (never a PTY)**, `CI` unset, no `--json`. Full output in
[`token_arms.txt`](token_arms.txt).

| arm | exit | first line |
|---|---|---|
| unset | **70** | `Failed to refresh credentials.` / `Try logging out with shorebird logout and logging in again.` |
| empty | **70** | `Failed to parse SHOREBIRD_TOKEN. Expected an API key (sb_api_...) or a legacy CI token.` then `FormatException: Unexpected end of input (at character 1)` |
| garbage | **70** | same named message, then `FormatException: Unexpected extension byte (at offset 0)` |

Against the precommitted rows: **`:2363` "Token/auth failure produces a useful
error" earns BUILT** — all three exit non-zero and name their cause. **`:2364`
"An empty `SHOREBIRD_TOKEN` can surface as a JSON `FormatException`" is
MITIGATED, NOT CLOSED**, and the distinction is deliberate: the named message
from `auth.dart:375-378` now precedes it, but **the raw `FormatException` is
still printed to the user**. The KNOWN ISSUE's literal claim — a FormatException
surfaces — remains true; what changed is that it is no longer the *only* thing
surfaced. Downgrading it to "fixed" would overstate what was measured.

One observation for whoever takes the harness: the *unset* arm's advice, "Try
logging out with `shorebird logout` and logging in again", is the wrong hint in
a CI context, where there is no interactive login to redo. Not a defect in scope
here, but it is the arm a CI author will actually hit.

> **Two void attempts, recorded rather than hidden.** The first arm run used
> `shorebird apps list` — not a command; all three arms printed the usage banner
> and exercised no auth path. The second used `shorebird account usage` — not a
> subcommand; all three exited 64. Both produced neatly formatted output that
> looked like a result. They are noted at the top of `token_arms.txt` because a
> vacuous arm that *looks* like a finding is precisely this lane's failure mode,
> and the same pass also caught `${PIPESTATUS[0]}` silently yielding nothing in
> zsh, where the array is `$pipestatus` and 1-indexed.

## NOT DONE, and why

**Step 22's two harness arms — `release android` + `patch android` against our
own control plane — were not run.** This is the lane's decisive step and it is
recorded as owed rather than approximated. The blockers are no longer
environmental: `cps-android` is up (authorised this session) and the Android
toolchain is fully present — SDK 36.0.0, JDK 17, `flutter doctor` reports
`[✓] Android toolchain` with no issues. What remains is real work: registering an
app on `cps-android`, choosing a fixture that is **not** `airgap_app` (that is
`R6`, and its version counter belongs to the device lane), publishing **two**
releases so the release-selection prompt is not skipped by
`release_chooser.dart:80-82`, and running both arms — with `--json` and without,
because `interactive_mode.dart:19` means a `--json`-only harness cannot tell
"no TTY" from "`--json`".

Until those run, `:2361` and `:2362` stay **NOT VALIDATED**. Nothing in this file
earns them.
