# SERVER-IMAGE-PROVENANCE-1 — findings

One invariant: **a server version names one source revision, one multi-arch
manifest digest, and one permanently retrievable set of bytes.**

The release process held none of the three, and the damage is still in the
registry. It is left there deliberately: `:1.3.0` is the evidence, and moving it
again would be the same mistake a third time.

## P-0 — the historical failure, measured

Resolved from GHCR, not inferred:

| reference | manifest digest | schema it applies |
|---|---|---|
| `:code_push_server-v1.3.0` | `sha256:a6e8bde7…` | **8** |
| `:1.3.0` | `sha256:320338b8…` | **12** |
| `:selfhost-v1.1.1` | `sha256:320338b8…` | 12 |
| `:latest` | `sha256:320338b8…` | 12 |

`:1.3.0` and `:latest` are the *distribution* tag's build. The semantic version
does not name the release it is named after.

The source side explains it exactly:

```
code_push_server-v1.3.0 -> cf74eeda  pubspec 1.3.0  schema 8   <- the release
selfhost-v1.1.0         -> 58a4985e  pubspec 1.3.0  schema 12
selfhost-v1.1.1         -> bdb234ab  pubspec 1.3.0  schema 12  <- overwrote :1.3.0
HEAD                                  pubspec 1.3.0  schema 12
```

Three tags carry a pubspec that says `1.3.0`. The publisher fired on
`selfhost-v*` as well as `code_push_server-v*`, read `version:` from whichever
ref it built, and re-tagged unconditionally — so the last of them to run won.
Reading the version was never enough to know which release was being cut.

The original bytes survived only because the git-tag traceability tag happened
to be applied as well. Nothing guaranteed that.

## P-1 — reproduced, without touching anything real

The merge job's shell was replayed verbatim against a throwaway local registry,
with two images built from two real source trees:

```
1. code_push_server-v1.3.0 (pubspec 1.3.0)   :1.3.0 -> cdca7df8   :latest -> cdca7df8
2. selfhost-v1.1.1         (pubspec 1.3.0)   :1.3.0 -> d6e95065   :latest -> d6e95065
   nothing refused
```

## P-2 — repaired

The logic lives in `packages/code_push_server/ops/release/`, not in the
workflow, because a YAML step cannot be certified locally and a script can.

| gate | how |
|---|---|
| separate release from distribution | `resolve_release.sh` classifies the ref: `code_push_server-vX.Y.Z` is the only `release`; `selfhost-v*` is `traceability`; anything else is `dispatch`. Only `release` may create `:X.Y.Z` or move `:latest`. |
| bind version to source | the tag's `X.Y.Z` must equal `pubspec.yaml` at the commit the tag resolves to, or the release refuses before anything is built or pushed |
| write-once semantic tags | before claiming `:X.Y.Z`, resolve it. Absent → publish. Same digest → idempotent rerun. Different digest → **refuse**, never replace |
| retain every released digest | every publish, in every mode, also gets `:source-<full commit>` — one per source commit, never reused, never moved by a later release |
| control `latest` | moved only by a `release` publication that passed every check |
| bind both architectures | the per-arch child digests are read back out of the published manifest and each must be present |
| post-publish verification | `imagetools create` exiting 0 is not evidence. Every reference is resolved back from the registry and required to equal the digest just produced |
| provenance in the image | OCI labels carry the source revision, repository and ref |

## P-3 — identity correctness is not retention

UPGRADE-ROLLBACK-1 made restore refuse anything but the recorded build. That
changes the failure from unsafe success to safe refusal, which is only half of
recoverability: a backup whose recorded digest is no longer *obtainable* is a
backup that cannot be restored through the certified contract.

So retention is a first-class property here, and it is measured rather than
assumed. After publishing a later release and deleting every local trace:

```
release A pulled from a clean store by its recorded digest alone   ok
its retention reference still resolves to that same digest         ok
:latest has moved to the later release                             ok
:1.3.0 still names release A                                       ok
```

and then, end to end with the rollback contract:

```
backup taken under release A records ...@sha256:8a027841…   (= A's manifest digest)
a later release is published
every local image removed
  -> restore REFUSES: "cannot resolve … to an image identity"
  -> pull by the recorded digest, point the compose at it
  -> restore ACCEPTS
  -> a different release is refused in its place
```

The backup's `server_image_id` is literally the release record's
`manifest_digest`, so the two systems name the same thing rather than merely
agreeing in spirit.

## P-4 — two defects in the digest check itself, found here

Both are in code this lane inherited from UPGRADE-ROLLBACK-1, and both were
found by the recovery control above rather than by review.

1. **The reference check ran before the digest check.** Pinning the compose to
   `repo@sha256:…` is the correct operator action when rolling back, and it was
   *rejected* for not looking like the tag the backup happened to be taken
   under. The digest is now the authority and runs first; the reference
   comparison is the fallback for archives taken before identity was recorded.
2. **`tar … | sed … | head -1` could kill the whole check.** `head` closes the
   pipe, `pipefail` sees SIGPIPE, and `set -e` exited the restore with **no
   message at all** — neither refusing nor proceeding, non-deterministically.
   The same shape was already fixed once in `resolve_digest` and had been
   reintroduced in `image_identities`. The manifest is now read once and parsed
   from a variable, and both helpers treat "absent" as an answer rather than an
   error.
