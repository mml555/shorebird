# G6 — progressive rollout is a KNOWN GAP in the client surface, not an unvalidated row

**Identity.** Re-derived 2026-08-13 16:12 EDT against the tree at the commit this
file lands in; `code_push_server` 1.3.0; Dart SDK 3.12.2 stable. No device, no
run, no cell — this is a source-determined classification.

## The classification, and why it is not a test

`PARITY.md`'s classification rule: **if source already determines the behavior it
is a KNOWN GAP — a decision to make — not an unvalidated question to test.**
Booking a run for this row would produce a green result that means nothing,
because there is no client surface to drive.

## The server half is BUILT

| what | where |
|---|---|
| bucketing | `rollout.dart:19` `eligibleForRollout` — deterministic bucket, fails closed with no `clientId` |
| tests | `test/rollout_test.dart`, 10 tests |
| settable per promotion | `api.dart:1684` declaration, `:1688` `_optIntField(body, 'rollout') ?? 100`, `:1689-1690` range check, `:1697` `repo.promote(..., rollout: rollout)` |
| admin route | `POST /admin/apps/{appId}/patches/{patchId}/rollout?channel=&percent=` — `api.dart:2497` route comment, handler branch `:2533`, audit label `:2546` |

## The client half does not exist — greps re-run, not inherited

The order's step 8 asserts this and says *"re-run the greps yourself"*. Done, at
this commit; each is the count of **files** containing the term:

```
grep -rli "rollout" packages/shorebird_cli/lib/src              -> 0
grep -rli "rollout" packages/shorebird_code_push_client/lib/src -> 0
grep -rli "rollout" packages/shorebird_code_push_protocol/lib   -> 0
```

`PromotePatchRequest` carries `patchId` and `channelId` and nothing else. So the
percentage is reachable **only** by an operator calling the admin route directly;
no CLI command can set it, and no protocol message can carry it.

This is precommitted outcome #4 in the negative direction: had any of those greps
found a surface, the order's claim — and this file — would have been wrong, and
the instruction was to verify at the location before believing either. They found
none.

## The decision this dispatches, left open deliberately

Open question 3 of the order, unresolved here because it is a protocol change and
this lane owns `R10` only:

* **Add the field** — touches `shorebird_code_push_protocol` +
  `shorebird_code_push_client` + `patch_command`, and diverges from upstream's
  message shape, which this fork otherwise keeps pinned.
* **Document the gap** — progressive rollout stays admin-only. The precedent for
  folding an aspiration into an existing mechanism rather than standing it up as
  its own obligation is §7's KMS row.

**Recorded, not decided.** What is decided is the label: the `G6` progressive
rollout row moves from **NOT VALIDATED** to **KNOWN GAP (client surface)**, with
the server half separately **BUILT**, because that is what the source says today.
