#!/usr/bin/env bash
# verify_cell_members.sh -- do the bytes SERVED for a v2 cell still equal the
# member hashes its address was computed over?
#
# PUBLISH-V2 proved 16/16 at publication time. That evidence is about the moment
# of publication and stays valid; it says nothing about drift afterwards. This
# asks the question a supported-state check has to ask: are those bytes still the
# addressed cell NOW.
#
# `audit_route_b_compiler.sh` remains the deeper compiler/runtime semantic audit
# -- it unpacks the bundle, checks the runtime/snapshot pairing, the platform
# dill split, the dart revision and the capability probe. This is the breadth
# check: every addressed member, no semantics.
#
#   verify_cell_members.sh <cellAddress> [--overlay DIR]
#
# Exit: 0 all members verified · 1 drift or missing member · 2 usage/environment
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
HASH=${1:?usage: verify_cell_members.sh <cellAddress> [--overlay DIR]}; shift || true
OVERLAY=${OVERLAY:-$REPO/selfhost/cdn/overlay}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

MAN="$HERE/cell_manifests/$HASH.v2"
[[ -f "$MAN" ]] || { echo "no v2 manifest registered for $HASH" >&2; exit 2; }

# The manifest authenticates the address before anything else is read from it.
RE=$(shasum -a 256 "$MAN" | cut -c1-40)
if [[ "$RE" != "$HASH" ]]; then
  echo "  FAILED  manifest recomputes to $RE, not $HASH"
  echo "CELL MEMBERS FAILED: manifest does not authenticate the address"
  exit 1
fi
echo "  ok      manifest authenticates the address"

# Files that legitimately carry the cell's own hash. The address was computed
# over a staged tree holding a LITERAL `%H`, so these must be canonicalized BACK
# to `%H` before hashing or they would never match. Same rule as the mint's
# v2_canonicalize, and it REFUSES a hash outside the one permitted field rather
# than rewriting it.
canon_hash() { # <file> <hash>
  python3 - "$1" "$2" <<'PY'
import sys, os, hashlib
path, h = sys.argv[1], sys.argv[2]
raw = open(path, 'rb').read()
name = os.path.basename(path)
if h.encode() not in raw:
    print(hashlib.sha256(raw).hexdigest()); sys.exit(0)
out = []
for line in raw.decode('utf-8').split('\n'):
    if h in line:
        if name == 'engine_stamp.json':
            if f'"git_revision": "{h}"' not in line:
                sys.stderr.write(f'{name}: {h} outside git_revision\n'); sys.exit(3)
            line = line.replace(f'"git_revision": "{h}"', '"git_revision": "%H"')
        elif name == 'artifacts_manifest.yaml':
            if not line.lstrip().startswith('#'):
                sys.stderr.write(f'{name}: {h} on a non-comment line\n'); sys.exit(3)
            line = line.replace(h, '%H')
        else:
            sys.stderr.write(f'{name}: no permitted hash-bearing field\n'); sys.exit(3)
        if h in line:
            sys.stderr.write(f'{name}: residual hash after canonicalization\n'); sys.exit(3)
    out.append(line)
print(hashlib.sha256('\n'.join(out).encode('utf-8')).hexdigest())
PY
}

total=0; okc=0; bad=0
while read -r member want; do
  [[ -n "$member" && -n "$want" ]] || continue
  case "$member" in address_schema|cell|fallback_engine_revision) continue ;; esac
  total=$((total+1))
  served="$OVERLAY/${member//%H/$HASH}"
  if [[ ! -f "$served" ]]; then
    echo "  FAILED  MISSING: $member"; bad=$((bad+1)); continue
  fi
  got=$(canon_hash "$served" "$HASH") || { echo "  FAILED  $member: canonicalization refused"; bad=$((bad+1)); continue; }
  if [[ "$got" == "$want" ]]; then
    okc=$((okc+1))
  else
    echo "  FAILED  DRIFTED: $member (addressed ${want:0:16}…, served ${got:0:16}…)"
    bad=$((bad+1))
  fi
done < <(awk 'NF==2' "$MAN")

echo "  ok      $okc of $total addressed members match the bytes served"
echo
if [[ "$bad" -eq 0 ]]; then
  echo "CELL MEMBERS VERIFIED ($total/$total)"
else
  echo "CELL MEMBERS FAILED: $bad of $total"
fi
exit $(( bad > 0 ))
