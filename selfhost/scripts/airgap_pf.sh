#!/usr/bin/env bash
# airgap_pf.sh — apply or remove the macOS air-gap seal, correctly.
#
#   sudo selfhost/scripts/airgap_pf.sh on     # seal
#   sudo selfhost/scripts/airgap_pf.sh off    # unseal, restore /etc/pf.conf
#   sudo selfhost/scripts/airgap_pf.sh status
#
# Why this script exists instead of a one-liner: `pfctl -a NAME -f rules`
# loads an anchor but does NOT hook it into the active ruleset, so the rules
# are evaluated never and the machine stays wide open while looking sealed.
# The main ruleset has to reference the anchor. This generates a main ruleset
# that keeps Apple's own anchors intact and appends ours, applies it, and can
# restore the stock /etc/pf.conf afterward.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ANCHOR=shorebird_airgap
RULES="$HERE/airgap.pf.conf"
GENERATED=/tmp/airgap_pf_main.conf
STATE=/tmp/airgap_pf_was_enabled

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only" >&2; exit 2; }
[[ "$(id -u)" == "0" ]] || { echo "run with sudo" >&2; exit 2; }

case "${1:-}" in
  on)
    # Remember whether pf was already enabled so `off` can restore the prior state.
    if pfctl -s info 2>/dev/null | head -1 | grep -q Enabled; then
      echo yes > "$STATE"
    else
      echo no > "$STATE"
    fi

    # COPY the stock ruleset verbatim and append ours. Do not reconstruct
    # Apple's anchor list by hand: this machine's /etc/pf.conf also carries an
    # `agbridge` anchor, and a hand-written version silently dropped it —
    # sealing must not quietly disable unrelated networking. Filter anchors
    # belong last in pf's ordering, so appending is valid.
    {
      cat /etc/pf.conf
      echo "anchor \"$ANCHOR\""
      echo "load anchor \"$ANCHOR\" from \"$RULES\""
    } > "$GENERATED"

    pfctl -n -f "$GENERATED" || { echo "generated ruleset failed to parse" >&2; exit 1; }
    pfctl -f "$GENERATED"
    pfctl -e 2>/dev/null || true    # "already enabled" is fine
    echo "Rules loaded into anchor $ANCHOR:"
    pfctl -a "$ANCHOR" -s rules

    # PROVE it. Loading rules is not sealing: an anchor that is not referenced,
    # or a non-quick block that a later pass overrides, both list perfectly
    # while blocking nothing. Only a live probe distinguishes them.
    echo "--- verifying (probing an external host) ---"
    if curl -4 -s -o /dev/null -m 8 https://github.com/ 2>/dev/null; then
      echo "NOT SEALED: github.com is still reachable." >&2
      echo "pf status:" >&2; pfctl -s info 2>/dev/null | head -2 >&2
      echo "Something is not enforcing these rules (pf disabled, anchor not" >&2
      echo "referenced, or another tool reloaded the ruleset). Do NOT run the" >&2
      echo "acceptance suite — its result would be meaningless." >&2
      exit 1
    fi
    echo "SEALED and verified: external HTTPS is blocked."
    curl -s -o /dev/null -m 8 http://localhost:8085/ 2>/dev/null \
      && echo "  local mirror still reachable" \
      || echo "  WARNING: local mirror unreachable — check the pass rules"
    ;;
  off)
    pfctl -a "$ANCHOR" -F rules 2>/dev/null || true
    pfctl -f /etc/pf.conf 2>/dev/null || true
    if [[ -f "$STATE" && "$(cat "$STATE")" == "no" ]]; then
      pfctl -d 2>/dev/null || true
      echo "UNSEALED (pf disabled, as it was before)"
    else
      echo "UNSEALED (pf left enabled, as it was before)"
    fi
    rm -f "$STATE" "$GENERATED"
    ;;
  status)
    pfctl -s info 2>/dev/null | head -2
    echo "--- anchor $ANCHOR ---"
    pfctl -a "$ANCHOR" -s rules 2>/dev/null || echo "(no rules loaded)"
    ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
