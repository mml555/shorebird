#!/usr/bin/env bash
# Fail if the SUPPORTED toolchain cannot be constructed from OWNED artifacts.
#
# THE STRUCTURAL ERROR THIS CATCHES. compatibility.yaml pins a Flutter revision;
# that revision's bin/internal/engine.version names an engine; and the owned
# artifact service must publish that engine's bootstrap artifacts. On
# 2026-08-28 the third link was missing — no cell existed at 69f9831c… — and it
# went unnoticed for the life of the project because every developer machine had
# a warm ~/.shorebird cache and cell activation happens AFTER bootstrap. A cold
# Linux container was the first thing that ever asked the question.
#
#     compatibility.yaml -> flutter_revision -> engine.version -> owned cell
#                                                                 ^^^^^^^^^^
#                                                                 was empty
#
# r12_revision_guard.sh protects the Route B producer revision. This is the same
# idea one layer earlier: it refuses to let the supported toolchain be
# unbuildable from what we actually host.
#
# Deliberately does NOT fetch anything. It is a structural check over the pin,
# the mirror and the overlay, so it is cheap enough to run in CI every time.
set -uo pipefail

REPO="${REPO:-/Users/mendell/shorebird}"
OVERLAY="${OVERLAY:-$REPO/selfhost/cdn/overlay/flutter_infra_release/flutter}"
MIRROR="${MIRROR:-$REPO/selfhost/cdn/mirrors/flutter.git}"
COMPAT="${COMPAT:-$REPO/selfhost/compatibility.yaml}"

# The artifacts a cold bootstrap needs, per supported host platform. Discovered
# empirically against a sealed cold mirror (selfhost/ci/r12/discover_closure.sh)
# rather than guessed — see evidence/r12-linux-ci/bootstrap_closure.tsv.
: "${REQUIRED_LINUX:=dart-sdk-linux-x64.zip}"

fail=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  REFUSE  %s\n' "$*"; fail=1; }
die()  { printf '\n  GUARD FAILED\n'; exit 1; }

echo "bootstrap closure guard"

rev="$(sed -nE 's/^[[:space:]]*flutter_revision:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$COMPAT" | head -1)"
[[ -n "$rev" ]] || { bad "no 40-hex flutter_revision in $COMPAT"; die; }
ok "supported flutter_revision: $rev"

[[ -d "$MIRROR" ]] || { bad "owned Flutter mirror missing at $MIRROR"; die; }
git -C "$MIRROR" cat-file -e "${rev}^{commit}" 2>/dev/null \
  || { bad "the owned mirror does not contain $rev — the pin is not reproducible"; die; }
ok "owned mirror contains the pinned revision"

eng="$(git -C "$MIRROR" show "$rev:bin/internal/engine.version" 2>/dev/null | tr -d '[:space:]')"
[[ "$eng" =~ ^[0-9a-f]{40}$ ]] \
  || { bad "engine.version at $rev is not 40 hex: '${eng:-<empty>}'"; die; }
ok "engine.version resolves: $eng"

# The check that would have fired on 2026-08-28.
if [[ ! -d "$OVERLAY/$eng" ]]; then
  bad "NO OWNED CELL at $OVERLAY/$eng"
  echo
  echo "  The supported Flutter pin needs engine $eng, and the owned artifact"
  echo "  service publishes nothing for it. A cold bootstrap therefore escapes to"
  echo "  upstream, and the toolchain is not reproducible from owned bytes."
  echo "  Repair by mirroring the exact immutable artifacts into the overlay"
  echo "  (selfhost/ci/r12/mirror_bootstrap_artifact.sh) — do NOT move the pin."
  die
fi
ok "owned cell exists for the supported engine"

for a in $REQUIRED_LINUX; do
  if [[ -s "$OVERLAY/$eng/$a" ]]; then
    ok "linux-x64 closure: $a ($(wc -c < "$OVERLAY/$eng/$a" | tr -d ' ') bytes)"
  else
    bad "linux-x64 closure MISSING: $a"
  fi
done

[[ "$fail" -eq 0 ]] || die
printf '\n  CLOSURE OK  %s -> %s\n' "$rev" "$eng"
