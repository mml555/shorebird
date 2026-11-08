#!/usr/bin/env bash
# cspell:words dartaotruntime DPUB
#
# verify_cell_delivery.sh -- does the REAL CONSUMER PATH serve this cell?
#
# THE INVARIANT:
#
#   Before any release or client may consume a newly published cell, the exact
#   hash URL through the real consumer path must return bytes matching the
#   published cell manifest.
#
# This replaces an older precondition that said "reload the mirror first". That
# rule was a deployment-specific remediation dressed as an invariant, and its
# negation is no better: on 2026-08-25 a `caddy reload` FAILED (admin endpoint
# off in that container) and the fetch nevertheless delivered the correct new
# cell, because that deployment rereads experimental_hashes.map per request.
# Neither "reload required" nor "reload unnecessary" is a product fact. The
# digest is.
#
# WHY A 200 IS NOT THE PROOF. The failure being closed serves a perfectly valid
# response containing the WRONG cell: the mapping is not live, the mirror falls
# back to the pinned hash, and Caddy CACHES that response under this hash's URL.
# `order cache before respond` then means a cache HIT beats the 404 that
# ownership would otherwise return. So this compares the DELIVERED bytes to the
# PUBLISHED bytes, and separately to the DONOR's, so fallback is named as
# fallback instead of surfacing as a vague mismatch.
#
#   verify_cell_delivery.sh --hash <cellHash> [--donor <hash>] [--base <url>]
#
# Exit codes: 0 delivered and verified · 1 mismatch (do not consume) · 2 usage.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
BASE=${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}
PLAT=${PLAT:-darwin-arm64}
HASH=""; DONOR=""

usage() { sed -n '3,29p' "${BASH_SOURCE[0]}"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --donor) DONOR="${2:?}"; shift 2 ;;
    --base) BASE="${2:?}"; shift 2 ;;
    --plat) PLAT="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$HASH" ]] || usage

fail=0
ok()   { echo "  ok      $*"; }
bad()  { echo "  FAIL    $*"; fail=$((fail+1)); }
note() { echo; echo "==> $*"; }

REL="download.shorebird.dev/shorebird/$HASH/route-b-compiler-$PLAT.zip"
PUB="$OVERLAY/$REL"
URL="$BASE/$REL"

echo "Route B cell delivery check"
echo "  hash : $HASH"
echo "  url  : $URL"
echo

[[ -f "$PUB" ]] || { echo "  FAIL    nothing published at $PUB"; exit 1; }
PUB_SHA=$(shasum -a 256 "$PUB" | cut -d' ' -f1)
ok "published bundle exists (${PUB_SHA:0:16})"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# `-w` already emits 000 when the transfer fails, so an `|| echo 000` here
# concatenates and prints "000000".
code=$(curl -s -o "$W/got.zip" -w '%{http_code}' --max-time 600 "$URL") || true
code=${code:-000}
if [[ "$code" != 200 ]]; then
  bad "consumer path returned HTTP $code"
  echo
  echo "REFUSE: nothing may consume $HASH. Reload or reconcile the serving"
  echo "config, clear the cache, then re-run this check."
  exit 1
fi
GOT_SHA=$(shasum -a 256 "$W/got.zip" | cut -d' ' -f1)
ok "consumer path returned HTTP 200 ($(wc -c < "$W/got.zip" | tr -d ' ') bytes)"

# THE CHECK. Not the status code.
if [[ "$GOT_SHA" == "$PUB_SHA" ]]; then
  ok "delivered bytes MATCH the published bundle (${GOT_SHA:0:16})"
else
  bad "delivered bytes are NOT the published bundle"
  echo "          published : $PUB_SHA"
  echo "          delivered : $GOT_SHA"
fi

# Name fallback as fallback. Without this a poisoned cache reads as a generic
# mismatch, and the remediation for the two is different.
if [[ -z "$DONOR" ]]; then
  DONOR=$(sed -nE "s/^# Previous cell, kept for rollback:$//p" /dev/null; \
    grep -B40 "^$HASH " "$SELFHOST/cdn/experimental_hashes.map" 2>/dev/null \
    | sed -nE 's/^# ANCESTRY, MEASURED against donor ([0-9a-f]{40}).*/\1/p' \
    | tail -1)
fi
if [[ -n "$DONOR" ]]; then
  DPUB="$OVERLAY/download.shorebird.dev/shorebird/$DONOR/route-b-compiler-$PLAT.zip"
  if [[ -f "$DPUB" ]]; then
    D_SHA=$(shasum -a 256 "$DPUB" | cut -d' ' -f1)
    # VACUITY FIRST, then the finding. Written the other way round, a cell whose
    # bundle is legitimately byte-identical to its donor -- a no-op republish --
    # had CORRECT delivery reported as a FALLBACK, because "delivered == donor"
    # is also true when donor == published. Caught by mutation-checking this
    # gate with --donor set to the cell itself.
    if [[ "$D_SHA" == "$PUB_SHA" ]]; then
      echo "  --      donor bundle is IDENTICAL to this one, so the fallback"
      echo "          control cannot distinguish them for this cell"
    elif [[ "$GOT_SHA" == "$D_SHA" ]]; then
      bad "delivered bytes ARE THE DONOR'S ($DONOR) — this is a FALLBACK, and it"
      echo "          is now probably cached under this hash's URL. Clearing the"
      echo "          mirror cache is required, not just a reload."
    else
      ok "delivered bytes differ from the donor's (${D_SHA:0:16}) — not a fallback"
    fi
  else
    echo "  --      donor $DONOR has no published bundle to compare against"
  fi
else
  echo "  --      no donor identified; the fallback control did not run"
fi

# Members, from the DELIVERED bytes. A bundle can match a digest and still be
# missing something if the published bundle was itself incomplete.
note "required members, read from the DELIVERED bytes"
for f in dartaotruntime dart2bytecode.aot vm_platform.dill route_b_analyze.aot \
         route_b_gen_kernel.aot route_b_gen_dynamic_interface.aot \
         route_b_release_probe.aot flutter_platform_strong.dill PROVENANCE.txt; do
  # NOT `unzip -l | grep -q`: grep exits at the first match, unzip takes
  # SIGPIPE, and pipefail turns a SUCCESSFUL match into a failed pipeline.
  if [[ "$(unzip -l "$W/got.zip" | grep -c "$f")" -ge 1 ]]; then
    ok "delivers $f"
  else
    bad "delivers NO $f"
  fi
done

# And the members must match what the bundle says they are.
note "delivered members against the delivered PROVENANCE.txt"
unzip -q -o "$W/got.zip" -d "$W/x"
PROV="$W/x/PROVENANCE.txt"
recorded=0
while IFS= read -r line; do
  name=${line%% : *}; want=${line##* : }
  [[ -f "$W/x/$name" ]] || continue
  got=$(shasum -a 256 "$W/x/$name" | cut -d' ' -f1)
  recorded=$((recorded+1))
  [[ "$got" == "$want" ]] && ok "$name matches its recorded hash" \
    || bad "$name is $got, recorded $want"
# PROVENANCE.txt PADS the name before the colon (`dartaotruntime    : ...`), so
# a single-space pattern silently matched only 6 of the 8 members. The count
# assertion below is what surfaced that -- without it this would have reported
# all-clear while never looking at the runtime or the platform dill.
done < <(sed -nE 's/^([a-z_0-9.]+)[[:space:]]*:[[:space:]]*([0-9a-f]{64})$/\1 : \2/p' \
           "$PROV" || true)
[[ "$recorded" -ge 8 ]] || bad "only $recorded member hashes were recorded (want >= 8)"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "DELIVERY VERIFIED — $HASH may be consumed."
  exit 0
fi
echo "REFUSE — $fail finding(s). Nothing may consume $HASH until this is clean."
echo "Remediation is deployment-specific: reload or reconcile the serving config,"
echo "clear the mirror cache and <flutterDir>/bin/cache/downloads, then re-run."
exit 1
