<!-- cspell:words noninteractive chardev armeabi passwd nonint prereq settrack devnull dists Requalification -->

# CI-NONINTERACTIVE-1 — unattended release, patch and promote

2026-09-04. **GATE 5 PASSED.** An automated job performs the whole self-hosted
workflow with **file descriptor 0 closed** and no interactive input, from the
`selfhost-v1.1.1` bootstrap.

    bootstrap -> authenticate -> release -> patch -> publish/promote     exit 0
    interactive prompts on the certified path                                0
    the token in captured stdout/stderr                                      0
    audit rows containing the token                                          0

Evidence: [`gate1_surface.log`](gate1_surface.log),
[`gate1b_arms.log`](gate1b_arms.log), [`gate5_run.log`](gate5_run.log),
[`gate5_bank.txt`](gate5_bank.txt), [`gate5_audit.json`](gate5_audit.json),
[`gate4_confirm_refusal.log`](gate4_confirm_refusal.log),
[`settrack_refusal.txt`](settrack_refusal.txt).

## Closed stdin means `0<&-`, and that is not pedantry

    closed    stdin.hasTerminal=false
    devnull   stdin.hasTerminal=true

Dart classifies stdin by `st_mode`, and `/dev/null` is a **character device**,
which it reports as a terminal. Under `< /dev/null` the CLI therefore believes
it can prompt. A CI contract written against `/dev/null` stdin tests the wrong
thing, so `/dev/null` is kept here only as the contrast arm. Asked of Dart
directly rather than inferred from the shell.

## Gate 1 — the surface, discovered by failure

Five blockers, in the order they appeared. **None was a prompt**; every one
fails closed and names its own remedy.

| | class | behaviour |
|---|---|---|
| Flutter `0.0.0-unknown` → pub refuses `flutter_test` | **product defect** | fixed in `b2c42eb9`, guard added to the bootstrap |
| `AndroidManifest.xml` missing INTERNET | environment | exit 78; `doctor --fix` supplies it unattended (exit 0) |
| `No Android SDK found` | environment | exit 70, remedy named |
| **`GRADLE_USER_HOME`** | environment | see below |
| detached checkout → *"Failed to get shorebird version"* | cosmetic | non-blocking |

**`HOME` cannot isolate a Java toolchain.** Gradle resolves `user.home` from
**passwd**, not from the `HOME` environment variable, so with `HOME` pointed at
a clean directory it still reached `/Users/mendell/.gradle` — which the sandbox
denied:

    java.io.FileNotFoundException: /Users/mendell/.gradle/wrapper/dists/
      gradle-9.1.0-all/.../gradle-9.1.0-all.zip.lck (Operation not permitted)

That is invisible on any machine where that directory happens to be readable
and warm. The Seatbelt denial is what exposed it.

## Gate 2 — credentials: passes

    missing       exit 67   You must be logged in            built=0
    garbage       exit 70   Failed to parse SHOREBIRD_TOKEN  built=0
    wrong shape   exit 70   (sb_api_deadbeef)                built=0

`built=0` is the load-bearing column: each refused **before any build**, so the
refusal precedes mutation rather than following it. One documented method
(`SHOREBIRD_TOKEN`), no browser or OAuth, no test-only backdoor.

Attribution, from the audit rows of the certified run:

    audit events                35, every one carrying a request_id
    actor_credential            bootstrap:1b1486344a85   <- a FINGERPRINT
    the raw token in any row     False

So the operation is attributed to the credential **without the credential being
stored** — the property CONTROL-PLANE-AUDIT established, re-measured here.

## Gate 3 — selection: passes, and one part is guaranteed by construction

With **four** releases present and no `--release-version`, the CLI neither
prompts nor picks the first object. It warns *"The release version to patch was
not specified. Building with Flutter … to determine the release version"* and
**derives from pubspec**, reaching `Release Version: 2.1.0+1 → Published Patch
1`. When the derived version has no release it exits 70. Explicit
`--release-version` is deterministic.

Derivation is mechanical, but it depends on a **mutable pubspec**, so the
certified contract passes the flag.

`patches set-track` declares `--release`, `--patch` and `--track` **mandatory**,
so the argument parser refuses before the command runs — deterministic by
construction rather than by a runtime check. Measured: omitting one exits 70,
and it does not ask.

A product wart found and **not** fixed (out of scope): a missing `app_id`
refuses with a raw `ParsedYamlException: … Missing key "app_id". type 'Null' is
not a subtype of type 'String' in type cast`. It refuses correctly; the message
is not a diagnostic.

## Gate 4 — the defect this lane fixed

**I have to correct my own first framing.** I reported that "`CI=true` means yes
to everything". That was imprecise. `confirm` comes from a **hidden `--confirm`
flag that defaults to false** (upstream #3223, *"can be removed fall 2026"*), so
an ordinary invocation does not prompt at all, interactively or not. The real
defect is narrower and worse: **asking is silently dropped when it *is*
requested.**

Measured before the fix — `release android --artifact apk --confirm` with fd 0
closed and `CI=true`:

    exit 0    ✅ Published Release 3.0.0+1!      and no prompt anywhere in the output

An operator who explicitly asked to be asked was silently approved. Cause, at
`release_command.dart` and `patch_command.dart`:

    if (confirm && shorebirdEnv.canAcceptUserInput) { logger.confirm(...) }

`logger.confirm` **already** fails closed — it calls `_failIfNonInteractive` and
throws `InteractivePromptRequiredException`, which the runner turns into a named
error and a non-zero exit. The `&& canAcceptUserInput` short-circuit was
stopping that mechanism from ever running. Removing it uses the product's own
mechanism rather than inventing one.

The required negative control, after the fix:

    --confirm,  fd 0 closed   exit 64   "Input was required for the following
                                         prompt but the CLI is running in a
                                         non-interactive context:
                                         Would you like to continue?"
    default (no flag)         exit 0    Published Release 4.1.0+1
    --no-confirm              exit 0    Published Release 4.2.0+1

It refused, named the prompt, and **did not mutate**: `4.0.0+1` is absent from
the release list while `4.1.0+1` and `4.2.0+1` are present. Not a hang, not an
implicit approval. Exit 64 is corroborated by the message, because 64 is also
the usage code.

The regression guard is a unit test asserting the confirmation is **reached**
when input is unavailable, and it is falsified both ways: restoring the
short-circuit fails it, removing it passes. `release_command_test` 40/40,
`patch_command_test` 92/92.

## Track and channel: two paths, one documented refusal

`patch --track <name>` publishes **and** assigns the track, auto-creating the
channel — the audit shows `channel.create` then `patch.promote`. Unattended.

`patches set-track` moves a patch to an **existing** channel. Demonstrated with
a real move: a third source revision → patch 2 to `beta` → `set-track` to
`stable`, verified by re-reading the channel rather than trusting exit 0.

`patches set-track --track <NEW>` **refuses**, and the product says why:

    Input was required for the following prompt but the CLI is running in a
    non-interactive context:
      No channel named ci1-nonexistent found. Do you want to create it?

    Hint: Pass --track=<existing-channel> to use an existing channel. Channels
    are auto-created when a patch is published with --track=<name>; set-track
    itself has no flag to skip this confirmation.

A documented boundary, not a defect — and the control pins it so a future change
cannot turn it into a silent auto-create. `patches promote` warns that it is
deprecated in favour of `set-track`, so `set-track` is the certified mechanism.

## Gate 5 — the certified run

    tag                selfhost-v1.1.1        cell       f85251f3…
    cli_revision       5cc178ef               selector   5b180d22…
    flutter_version    3.44.6-100-g5b180d224
    app_id             a0282e0f-56de-6c39-b187-d20d87b4d3d0
    release            id 10, 1.0.0+1, exit 0    5 artifacts
    patch 1            id 7, exit 0, channel stable
    patch 2            number 2, exit 0, beta -> stable via set-track
    set-track new      exit 64 (refused, named)
    set-track missing  exit 70 (parser refused)
    audit              35 events, 35 request ids, 1 credential fingerprint
    secret in logs     0        prompts on the certified path   0

Full artifact hashes and every exit status: [`gate5_bank.txt`](gate5_bank.txt).

## Four harness faults of my own, each fixed

1. **Arms that mutated shared state.** The first three release arms all used
   version `1.0.0+1`; arm 1 created it and arms 2 and 3 then failed on *"you
   have an existing android release"* — nothing to do with stdin or the flag.
   Every arm now carries its own version.
2. **A vacuous success check.** The harness accepted `flutter create` because
   the directory existed while its `pub get` had already failed. Directory
   existence is not success.
3. **Promoting an already-promoted patch.** Publishing straight to `stable` left
   nothing to promote, so `promote` correctly refused with *"Patch 1 is already
   live"* and the arm measured nothing.
4. **An audit query that read the wrong end of the log.** `?limit=80` returns
   the **oldest** rows, so the run's own 25 events fell outside the window and
   the check reported 0. Now filtered server-side by `app_id`.

Three of the four produced a green-looking or red-looking result for the wrong
reason, which is the only kind of harness bug that matters.

## Requalification

This lane changed product code, so the record moved:

    cli_revision            46ee70af -> 5cc178ef
    packages_shorebird_cli  6c76e79a -> 486a7714

The cell, the compiler archive, the analyzer and the Flutter selector did not
move. `SUPPORTED STATE VERIFIED` after advancing the recorded runtime checkout.

## Boundary

No device run. No compiler or cell work. iOS was not exercised: the CLI and
control-plane interaction surfaces are shared, and one platform was sufficient
per the lane's terms.
