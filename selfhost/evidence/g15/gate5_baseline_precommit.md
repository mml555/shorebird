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

## AMENDMENT, 2026-08-15, before the cut — the table above is unchanged

The `G4.1c` lane raised an over-read in the "wholesale rollback" description that
this precommit's outcomes leaned on, and it is right. The on-disk absence is
consistent with **two** readings that it cannot separate:

* **(a)** the transactions reached this database and rolled back wholesale;
* **(b)** they never reached this database at all — a server writing elsewhere
  leaves exactly the same trace: dense ids, `sqlite_sequence` never advanced, no
  audit row, and a truthful `200`/`204` from a process that really did the work.

Verified here independently: `sqlite_sequence` is `audit_log 178`, `releases 94`,
`patches 60` — **equal to `max(id)` on all three**, so no id was ever allocated
beyond what survives. That is consistent with BOTH readings and discriminates
neither, exactly as the other lane said.

**One thing DOES discriminate, and it narrows (b):** the container has exactly
**one** database file —

    docker exec cps-ios find / -name '*.db' -o -name '*.sqlite*'
    -> /data/code_push.db

So *"the server wrote to a different database file"* is **refuted**. Readings that
require no file at all — an in-memory database, or a file since deleted — are not
refuted, and the container has not restarted (`RestartCount 0`), which makes a
since-deleted file less likely without excluding it.

**What this does to the outcomes above:** a vanish implicates the CLI only under
(a). Under a surviving (b) the interesting question becomes WHERE the write went,
not why it rolled back. So the "absent" row is amended to read: *the CLI
hypothesis is strengthened **if (a) holds**; if the write is later found to have
landed elsewhere, the CLI is not implicated by this experiment at all.* The third
population (release present, no audit row) is likewise ambiguous — precommitted
against (a), but also what a partial (b) would look like.

**ADDED STEP, adopted from the other lane's user: verify, then REOPEN, then verify
again.** A single content read cannot distinguish *committed* from *visible to a
connection that has not been reopened*. So after the cut:

1. content-read `releases` + `audit_log`;
2. `docker restart cps-ios`;
3. content-read both again.

A row present at step 1 and absent at step 3 is a distinct and more interesting
result than either outcome in the table, and it costs seconds.

## What this does not test

Nothing about the engine, the seam, or crash-backout. This is a publish-path
observation that happens to be a prerequisite for gate 5's arms. A persisted
baseline says the bytes are on the plane; it says nothing about whether patch
`0011`'s seam works, which is what the device arms are for.
