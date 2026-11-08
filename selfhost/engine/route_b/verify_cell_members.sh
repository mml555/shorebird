#!/usr/bin/env bash
# cspell:words PVPY canonicalize canonicalization canonicalized canonicalizer
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

# CELL_MANIFESTS lets a qualification run point at a scratch registry. The
# DEFAULT is the in-repo one, so a supported-state check cannot be talked into
# authenticating a cell against a manifest someone handed it.
MAN="${CELL_MANIFESTS:-$HERE/cell_manifests}/$HASH.v2"
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
# to `%H` before hashing or they would never match.
#
# The rule itself is NOT duplicated here. lib/v2_canonicalize.py is the single
# authority and the mint uses the same file, so a rule can no longer be added to
# one side and forgotten on the other -- which in this direction would mean a
# drifted cell reported as intact.
V2_CANON="$HERE/lib/v2_canonicalize.py"
canon_hash() { # <file> <hash>
  python3 "$V2_CANON" "$1" "$2" --digest
}

# THE MAVEN COORDINATE CHECK, which canonicalization deliberately cannot do.
#
# canon_hash proves a POM's BYTES are the addressed ones. It says nothing about
# whether the version it declares matches the path it is served from -- and that
# is the one thing Gradle enforces at build time ("bad version: expected=…
# found=…"). A cell whose POM body and coordinate disagree authenticates
# perfectly and cannot be built against, so the mismatch has to be caught here
# rather than on a developer's machine.
pom_version_agrees() { # <servedFile> <memberPath> <hash>
  python3 - "$1" "$2" "$3" <<'PVPY'
import re, sys
served, member, h = sys.argv[1], sys.argv[2], sys.argv[3]
# The version the URL promises: .../<artifact>/1.0.0-<h>/<artifact>-1.0.0-<h>.pom
m = re.search(r'/1\.0\.0-%H/', member)
if not m:
    sys.stderr.write('pom member path carries no 1.0.0-%H version segment\n')
    sys.exit(3)
want = '1.0.0-' + h
text = open(served, encoding='utf-8').read()
# The project's own version is the first top-level <version>, before <dependencies>.
head = text.split('<dependencies>')[0]
found = re.findall(r'<version>([^<]*)</version>', head)
if len(found) != 1:
    sys.stderr.write(f'{len(found)} project-level <version> elements, expected 1\n')
    sys.exit(3)
if found[0] != want:
    sys.stderr.write(f'declares {found[0]}, served as {want}\n')
    sys.exit(3)
PVPY
}

total=0; okc=0; bad=0; poms=0
while read -r member want; do
  [[ -n "$member" && -n "$want" ]] || continue
  case "$member" in address_schema|cell|fallback_engine_revision) continue ;; esac
  total=$((total+1))
  served="$OVERLAY/${member//%H/$HASH}"
  if [[ ! -f "$served" ]]; then
    echo "  FAILED  MISSING: $member"; bad=$((bad+1)); continue
  fi
  got=$(canon_hash "$served" "$HASH") || { echo "  FAILED  $member: canonicalization refused"; bad=$((bad+1)); continue; }
  if [[ "$member" == *.pom ]]; then
    if ! err=$(pom_version_agrees "$served" "$member" "$HASH" 2>&1); then
      echo "  FAILED  $member: Maven coordinate disagrees ($err)"; bad=$((bad+1)); continue
    fi
    poms=$((poms+1))
  fi
  if [[ "$got" == "$want" ]]; then
    okc=$((okc+1))
  else
    echo "  FAILED  DRIFTED: $member (addressed ${want:0:16}…, served ${got:0:16}…)"
    bad=$((bad+1))
  fi
done < <(awk 'NF==2' "$MAN")

echo "  ok      $okc of $total addressed members match the bytes served"
if [[ "$poms" -gt 0 ]]; then
  echo "  ok      $poms Maven POM(s) declare the version they are served under"
fi
echo
if [[ "$bad" -eq 0 ]]; then
  echo "CELL MEMBERS VERIFIED ($total/$total)"
else
  echo "CELL MEMBERS FAILED: $bad of $total"
fi
exit $(( bad > 0 ))
