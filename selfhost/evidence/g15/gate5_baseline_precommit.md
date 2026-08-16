# G15 gate 5 — the baseline cut, precommitted

Written **before** the release is cut, 2026-08-15. Not edited afterwards.

## The decision

Gate 5's baseline is cut with the **CURRENT rig CLI**, on the **ordinary
user-OAuth path**, and content-read immediately. The alternative offered — check
out `ba4e1c02` for the cut because every vanished write shares the newer
revision — is declined **on purpose**, and the reason is that cutting on the
current CLI is not a risk to absorb but the best experiment available.

## Why this is the sharper experiment

The standing correlation is 6 persisted on `ba4e1c02` against 4 vanished on
`50ed19a7`/`98f84c17`. It spans **two actors, two auth paths, two apps and two
organisations**, so the CLI revision is confounded with everything else that
changed.

A cut from this lane isolates it. Same lane, same fixture (`killswitch_probe`),
same actor (2, `you@example.com`), same auth path (user-OAuth), same plane, same
app — **differing in the CLI revision alone**, against releases 93/94 which
persisted on `ba4e1c02` and are confirmed in `audit_log` rows 176/177.

Choosing `ba4e1c02` would produce a baseline and no information.

## Cost, and why a vanish is cheap here

The content read **gates all further spend**. A vanish costs one release build
(minutes) and no device cycle, no mint and no arm. This is deliberately not the
"three arms in flight" scenario that the hold exists to prevent.

## PRECOMMITTED OUTCOMES

| observation (content read, immediately after the cut) | verdict |
|---|---|
| the release row is **present** in `releases`, **and** a matching `audit_log` row exists | the write persisted on the new CLI. **The CLI hypothesis is WEAKENED — NOT cleared.** One write is not a population, and clearing it on a single agreeable observation would be the same error as promoting the `mtime` or the auth path. Proceed to gate 5, still content-reading every patch |
| the release row is **absent** | **the CLI hypothesis is substantially STRENGTHENED, and this is its first CONTROLLED instance.** Gate 5 stays held. **Do NOT re-login, do NOT re-sync, do NOT change any auth or CLI state** — preserve everything exactly as it stands, because the state is the evidence and re-authenticating destroys it |
| release present but **no `audit_log` row** | a partial commit, which neither the rollback reading nor the CLI reading predicts. **Record as a third population and stop** — it would mean the failure is finer-grained than either lane has described |
| release present, then a later **patch** vanishes | the failure is not at release scope. Record separately; do not generalise from the release's success to the patch path |

## Rules that bind this cut regardless of outcome

1. Same ordinary user-OAuth CLI path (no `SHOREBIRD_TOKEN`).
2. Publish success is **provisional** until content-read.
3. Verify by **content** — `releases` **and** `audit_log`, not the CLI's exit text,
   not an HTTP `200`, not a same-session `releases list`.
4. **A vanish is preserved as evidence. Auth state is not touched first.**

## What this does not test

Nothing about the engine, the seam, or crash-backout. This is a publish-path
observation that happens to be a prerequisite for gate 5's arms. A persisted
baseline says the bytes are on the plane; it says nothing about whether patch
`0011`'s seam works, which is what the device arms are for.
