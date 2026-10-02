# G6 lane B — named tracks, and what the new test actually proves

**Identity.** `code_push_server` 1.3.0 (`pubspec.yaml:6`); Dart SDK 3.12.2 stable;
`dart test -x integration` (CI's command, `code_push_server.yaml:58`), run from
`packages/code_push_server` because the package is not a workspace member; test
`api_test.dart` → `independent live patches per track` →
`named tracks are independent, and promotion adds rather than moves`; recorded
2026-08-13 16:14 EDT. **No cell address or engine hash appears here on purpose** —
nothing in this lane is inside cell `4df8f9b6`, and writing one in would falsely
couple the server lane to that mint.

## Status earned: BUILT, and narrower than it looks

Suite went **290 → 291**. The new test passed **first try**, which is precommitted
outcome #1 — the ⚠ row, because favourable results are the dangerous ones:

> the code path was already generic and already had one named channel
> (`internal`, `api_test.dart:2898`) — so this prices **coverage**, not
> capability.

Channels are get-or-create by name (`api.dart:1550` `_createChannel`,
`repository.dart:1131` `createChannel`), so `beta` and `staging` were never
special. What §6 listed as five NOT VALIDATED rows was untested naming, not
missing behavior. **This earns BUILT for the server rows and nothing more.**

`grep -rn "beta" packages/code_push_server/{lib,test}` returned nothing before
this test and returns hits now. **That grep is not evidence of anything** — §6
already retracted a claim built on exactly it (a negative grep read as absent
work), and repeating the inference would repeat the retraction.

## The half worth having: supersession is channel-scoped

`repository.dart:1205`:

```sql
UPDATE channel_patches SET status = @w, withdrawn_at = now()
WHERE channel_id = @c AND status = @a AND patch_id <> @p
```

`WHERE channel_id = @c` is what makes the verb **ADD** rather than *move*: a patch
stays live on every track it was already on, and promoting onto one track cannot
disturb another. Withdrawal is scoped the same way (`repository.dart:1336`
declaration, `:1342` `WHERE channel_id = @c AND patch_id = @p AND status = @a`).

The test drives three named tracks holding three different patches at once, then
promotes `staging`'s patch onto `beta` and asserts `staging` still serves it.

## The negative control — the test discriminates, measured

A test that passes first try is worth what its failure mode is worth, so the
assertion was made to fail on purpose. **Run in a scratch copy of the package
under `scratchpad/g6-negctl`, never in the shared tree** — house rule 11, which
exists because a sixty-second in-place negative control was committed by another
worker on 2026-08-13.

Change (scratch only): drop `channel_id = @c` from the query above, making
supersession global.

```
supersession is now GLOBAL, not per-channel
  Actual: <null>
  test/api_test.dart 3008:7
00:00 +0 -1: Some tests failed.
```

Line 3008 is `expect(await check('beta'), 1)` — the first assertion after the
three promotions. With global supersession, promoting onto `staging` and `stable`
withdraws `beta`'s patch, and the track serves nothing. **That is precommitted
outcome #2's failure mode reproduced deliberately**, so the assertion is
load-bearing rather than incidentally true.

A fourth assertion guards the other direction: `check('canary')` — a track nobody
promoted onto — must return `null`, not stable's patch by accident. Without it,
every expectation above could pass against a server that ignored `channel`
entirely.

## What this does NOT establish

**Nothing about a device.** Precommitted outcome #3: concluding "tracks work"
here is §6's other retracted overreach. The chain, re-verified at this commit:

| step | fact |
|---|---|
| `shorebird_yaml.dart:68-70` | `compileShorebirdYaml` copies `base_url`, `auto_update`, `patch_verification` — **never `channel`** |
| `config.rs:24`, `:148` | the shipped yaml has no channel, so the updater falls back to `DEFAULT_CHANNEL = "stable"` |
| `network.rs:301` | that value becomes `PatchCheckRequest.channel` (`:262`) |
| `api.dart:1989` | the server resolves `str('channel') ?? 'stable'` |

So **an unmodified device on any release always asks for `stable`.** Per §6's own
retraction that makes the device row **NOT VALIDATED, not blocked** — it is
reachable through the Dart API (`checkForUpdate(track:)`, lane C step 14) or
`shorebird preview --track` (`preview_command.dart:97-100`), neither of which is
in this lane.

> **Citation drift, corrected in place:** the order cites the server default at
> `api.dart:1953`. It is at **`api.dart:1989`** at this commit; `:1953` is inside
> `_patchesCheck` but is no longer the line. The order's other lane-B anchors
> (`repository.dart:1205`, `:1336`, `:1342`, `api_test.dart:2830-2834`, `:2898`,
> `set_track_command.dart:37`) were each re-read and are correct.
