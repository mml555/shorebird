#!/usr/bin/env bash
# cspell:words imagetools
# Verify a published release against its banked provenance record, from
# nothing but the record. This is the check an operator (or a later lane) runs
# to answer "are the bytes my backup names still retrievable, and are they the
# ones this release claims?" -- separately from the publish that produced them.
#
# Usage: verify_release.sh <provenance.json>
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib.sh
. "$HERE/lib.sh"

REC=${1:?usage: verify_release.sh <provenance.json>}
read -r IMAGE DIGEST SEMANTIC RETAIN GIT_TAG COMMIT CHILDREN <<<"$(python3 - "$REC" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(r["image"], r["manifest_digest"], r.get("semantic_tag") or "-",
      r["retention_ref"], r.get("git_tag") or "-", r["commit"],
      ",".join(r["child_digests"]))
PY
)"

fail=0
say_ok(){ echo "    ok   $1"; }
say_no(){ echo "    FAIL $1"; fail=1; }
check(){ local ref=$1 got; got="$(resolve_digest "$ref")"
  if [[ "$got" == "$DIGEST" ]]; then say_ok "$ref -> $got"
  else say_no "$ref -> ${got:-<absent>} (expected $DIGEST)"; fi; }

echo "==> release $COMMIT ($GIT_TAG) claims $DIGEST"
# The retention reference is the load-bearing one: aliases may legitimately
# have moved on to later releases, but this must still resolve, because a
# backup's recorded digest is only useful while the bytes remain retrievable.
check "$RETAIN"
[[ "$SEMANTIC" != "-" ]] && check "$SEMANTIC"
[[ "$GIT_TAG" != "-" ]] && check "${IMAGE}:${GIT_TAG}"

# And the bytes themselves, by digest, independent of every name.
if [[ -n "$(resolve_digest "${IMAGE}@${DIGEST}")" ]]; then
  say_ok "${IMAGE}@${DIGEST} is retrievable by digest"
else
  say_no "${IMAGE}@${DIGEST} is NOT retrievable by digest"
fi

served="$(docker buildx imagetools inspect --raw "${IMAGE}@${DIGEST}" 2>/dev/null \
  | python3 "$HERE/manifest_children.py")"
if [[ -z "$served" ]]; then
  served="$DIGEST $(docker buildx imagetools inspect "${IMAGE}@${DIGEST}" | awk '/^Platform:/{print $2; exit}')"
fi
IFS=, read -ra kids <<<"$CHILDREN"
for d in "${kids[@]}"; do
  if printf '%s\n' "$served" | grep -q "^$d "; then
    say_ok "child $d ($(printf '%s\n' "$served" | awk -v x="$d" '$1==x{print $2}'))"
  else say_no "child $d is missing from the published manifest"; fi
done

(( fail == 0 )) || { echo "release verification FAILED" >&2; exit 1; }
echo "==> verified"
