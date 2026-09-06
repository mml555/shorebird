# SERVER-IMAGE-PROVENANCE-1 — certification

| | |
|---|---|
| harness | `selfhost/scripts/spp1_certify.sh` |
| verdict | **CERTIFIED — 36 passed, 0 failed** |
| against the publisher it replaces | **22 passed, 14 failed** (`LEGACY=1`) |

Everything runs against a throwaway local registry with two real releases built
from two real source trees, pushed per architecture the way the workflow does
(`buildx --push-by-digest`, provenance off), so the manifest-list mechanics
under test are the real ones. The published `:1.3.0` is not touched.

## What is certified

```
version is bound to source        tag X.Y.Z must equal pubspec at the tag's commit
                                  selfhost-v* claims no version, even though its
                                  pubspec says 1.3.0
release publishes                 :X.Y.Z, :latest, the git tag, and :source-<commit>
                                  all resolve to one manifest, with both
                                  architecture digests bound into it
the historical failure replayed   a distribution tag can no longer create or move
                                  :X.Y.Z or :latest
semantic tags are write-once      a different commit is refused; the same release
                                  reruns idempotently
manual builds are inert           they move no semantic tag and no :latest, but
                                  their bytes are still retained
a later release is harmless       :latest moves; the earlier release's semantic
                                  tag and retention reference do not
retrievability                    from a store with nothing left, release A pulls
                                  by its recorded digest and verifies against its
                                  banked provenance record
the rollback contract holds       a backup taken under A records A's manifest
                                  digest; after a later release and a wiped store,
                                  restore refuses until A is reacquired by that
                                  digest, then accepts — and refuses a different
                                  release in its place
```

## It discriminates

`LEGACY=1` substitutes the merge job as it was. The same checks then report:

```
FAIL  the retention reference resolves to it        (there was none)
FAIL  :1.3.0 still resolves to release A            (the distribution build took it)
FAIL  :latest still resolves to release A           (it followed)
FAIL  1.3.0 was republished from a different commit
FAIL  a rerun was not recognised as idempotent
FAIL  :1.3.0 unmoved by a dispatch build
FAIL  the backup records release A's manifest digest  (it records the wrong build)
22 passed, 14 failed
```

The last of those is the one that matters most: under the old publisher a
backup taken from a deployment on `:1.3.0` records whichever build most
recently claimed that tag, so the rollback guarantee certified in
UPGRADE-ROLLBACK-1 was resting on a name that could change underneath it.

## Reproducing

```bash
selfhost/scripts/spp1_certify.sh          # the repaired publisher
LEGACY=1 selfhost/scripts/spp1_certify.sh # the one it replaces
```

## Deliberately not done

`:1.3.0` in the live registry still points at the distribution build. It is
left alone: it is the evidence for P-0, and re-pointing it would be a third
silent move of a semantic tag. Operators who need the actual 1.3.0 release
have it at `:code_push_server-v1.3.0` / `sha256:a6e8bde7…`.

## Corrections made during the lane

1. **The reproduction was vacuous on its first run.** One of the two builds
   failed to push ("does not provide any platform"), so the "tag moved from X
   to Y" line reported a move from nothing. Rebuilt both from real source trees.
2. **Two `set -e` + `pipefail` traps in the same shape**, one of which had
   already been fixed once. A helper whose command legitimately fails when a
   reference is absent must not let that failure propagate out of an
   assignment: it exits the script silently, and a restore that neither refuses
   nor proceeds is worse than either outcome.
3. **Diagnostics truncated the wrong end.** Failure messages printed the first
   110 characters of a command's output — which is the banner every run emits —
   so three consecutive investigations were run on no information. They now
   print the tail.
4. **A cleanup step did not clean.** `docker rmi -f` cannot remove an image a
   stopped container still holds, so the "nothing local is left" arm passed
   while the image was still resolvable, which would have made the pull-by-
   digest arm a no-op against cache.
