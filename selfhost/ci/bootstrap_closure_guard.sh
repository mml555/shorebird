#!/usr/bin/env bash
# Fail if the SUPPORTED toolchain cannot be constructed from OWNED artifacts.
#
# THE STRUCTURAL ERROR THIS CATCHES. compatibility.yaml pins a Flutter revision;
# that revision's bin/internal/engine.version names an engine; and the owned
# artifact service must publish that engine's bootstrap artifacts, byte for byte.
# On 2026-08-28 the third link was missing — no cell existed at 69f9831c… — and
# it went unnoticed for the life of the project because every developer machine
# had a warm ~/.shorebird cache and cell activation happens AFTER bootstrap. A
# cold Linux container was the first thing that ever asked the question.
#
#   compatibility.yaml -> flutter SHA -> owned mirror -> engine.version
#     -> bootstrap_closure.tsv -> every named artifact -> size + SHA-256
#
# THE MANIFEST IS AUTHORITATIVE, NOT A LIST IN THIS FILE. An earlier version of
# this guard carried a hardcoded filename and only tested `-s`. It would have
# passed with engine_stamp.json deleted, and passed on a one-byte Dart SDK — so
# the "permanent prevention mechanism" was weaker than the evidence it existed to
# preserve. It now consumes the closure that was empirically discovered under
# seal, so the guard and the evidence cannot drift apart.
#
# Deliberately fetches nothing: a structural + digest check over the pin, the
# mirror and the overlay. Cheap enough to run on every self-hosted
# toolchain/coherence validation — NOT a hosted-CI check, because it reads the
# gitignored multi-gigabyte overlay and the local bare mirror, where a hosted
# runner could only be vacuous or permanently red.
set -uo pipefail

REPO="${REPO:-/Users/mendell/shorebird}"
OVERLAY="${OVERLAY:-$REPO/selfhost/cdn/overlay/flutter_infra_release/flutter}"
MIRROR="${MIRROR:-$REPO/selfhost/cdn/mirrors/flutter.git}"
COMPAT="${COMPAT:-$REPO/selfhost/compatibility.yaml}"
LEDGER="${LEDGER:-$REPO/selfhost/evidence/r12-linux-ci/bootstrap_closure.tsv}"

fail=0
ok()  { printf '  ok      %s\n' "$*"; }
bad() { printf '  REFUSE  %s\n' "$*"; fail=1; }
die() { printf '\n  GUARD FAILED\n'; exit 1; }

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

[[ -r "$LEDGER" ]] || { bad "closure manifest unreadable: $LEDGER"; die; }

# A manifest with no rows for the resolved engine is the same failure as a
# missing cell, dressed up as a pass. Refuse it explicitly.
rows=0
while IFS=$'\t' read -r m_eng m_art m_bytes m_sha m_src; do
  [[ "$m_eng" == "$eng" ]] || continue
  rows=$((rows + 1))
  f="$OVERLAY/$eng/$m_art"
  if [[ ! -f "$f" ]]; then
    bad "$m_art — MISSING from the owned cell"
    continue
  fi
  a_bytes="$(wc -c < "$f" | tr -d ' ')"
  if [[ "$a_bytes" != "$m_bytes" ]]; then
    bad "$m_art — SIZE MISMATCH: on disk $a_bytes, manifest $m_bytes"
    continue
  fi
  a_sha="$(shasum -a 256 "$f" | awk '{print $1}')"
  if [[ "$a_sha" != "$m_sha" ]]; then
    bad "$m_art — DIGEST MISMATCH
             on disk  $a_sha
             manifest $m_sha"
    continue
  fi
  ok "$m_art  $a_bytes bytes  sha256 ${a_sha:0:16}…"
done < <(tail -n +2 "$LEDGER")

if [[ "$rows" -eq 0 ]]; then
  bad "closure manifest names NO artifacts for engine $eng"
  echo
  echo "  An empty closure is not a satisfied closure. Discover it under seal"
  echo "  (selfhost/ci/r12/discover_closure.sh) before trusting this guard."
  die
fi
ok "closure manifest rows for this engine: $rows"

# ---- the addressing itself, not just the artifacts ------------------------
# THE CLOSURE IS ONLY MEANINGFUL RELATIVE TO THE MANIFEST THAT ADDRESSES IT.
# artifacts_manifest.yaml at the supported engine declares
# flutter_engine_revision, and the artifact proxy uses it to remap requests for
# everything NOT in artifact_overrides:
#
#   client   /flutter_infra_release/flutter/69f9831c…/sky_engine.zip
#   proxy -> /gcs/flutter_infra_release/flutter/83675ed2…/sky_engine.zip
#
# Every owned path was discovered under that mapping. If the manifest changed,
# the addresses would move and every artifact below could still verify while the
# mirror served nothing — a closure that passes its own guard and fails in a
# container. So the manifest is pinned by digest, and the revision it declares is
# pinned too.
MAPPING="${MAPPING:-$REPO/selfhost/evidence/r12-linux-ci/proxy_mapping.tsv}"
MANIFEST="$OVERLAY/../../download.shorebird.dev/shorebird/$eng/artifacts_manifest.yaml"
if [[ ! -r "$MAPPING" ]]; then
  bad "proxy mapping record unreadable: $MAPPING"
elif [[ ! -f "$MANIFEST" ]]; then
  bad "artifacts_manifest.yaml NOT OWNED for engine $eng — the proxy's remap
             table would come from upstream, so the closure addresses are unpinned"
else
  m_row="$(awk -F'\t' -v e="$eng" '$1==e{print; exit}' "$MAPPING")"
  if [[ -z "$m_row" ]]; then
    bad "no proxy mapping recorded for engine $eng"
  else
    want_sha="$(printf '%s' "$m_row" | cut -f2)"
    want_rev="$(printf '%s' "$m_row" | cut -f3)"
    got_sha="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
    got_rev="$(sed -nE 's/^flutter_engine_revision:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$MANIFEST")"
    if [[ "$got_sha" != "$want_sha" ]]; then
      bad "artifacts_manifest.yaml DIGEST MISMATCH
             on disk  $got_sha
             recorded $want_sha
             The closure addresses may have moved. Re-discover before trusting."
    elif [[ "$got_rev" != "$want_rev" ]]; then
      bad "flutter_engine_revision MOVED: $got_rev, recorded $want_rev"
    else
      ok "proxy mapping pinned: manifest ${got_sha:0:16}… -> flutter_engine_revision ${got_rev:0:16}…"
    fi
  fi
fi

[[ "$fail" -eq 0 ]] || die
printf '\n  CLOSURE OK  %s -> %s  (%s artifacts, size + sha256 verified)\n' "$rev" "$eng" "$rows"
