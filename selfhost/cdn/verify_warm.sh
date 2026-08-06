#!/usr/bin/env bash
# verify_warm.sh — machine check that a sealed run needed nothing cold.
#
# In sealed mode (docker-compose.cdn.sealed.yaml) every upstream fetch the
# mirror refuses is answered with a "sealed: refusing upstream fetch" 502 and
# logged. If a build succeeded but this script finds refusals, the build
# quietly did without something it wanted (e.g. an optional artifact) — read
# the list and decide. If a build FAILED and this finds refusals, they are the
# reason.
#
# Usage: verify_warm.sh [--since <docker-logs-since, default 2h>]
set -euo pipefail

SINCE="2h"
[[ "${1:-}" == "--since" ]] && SINCE="${2:?--since needs a value}"

CONTAINER="shorebird-cdn-cdn-cache-1"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "ERROR: $CONTAINER is not running" >&2
  exit 2
fi

REFUSALS="$(docker logs "$CONTAINER" --since "$SINCE" 2>&1 | grep -F 'sealed: refusing upstream fetch' || true)"
# The respond body appears in access logs as part of the handled request;
# count distinct request URIs that were refused.
COUNT="$(docker logs "$CONTAINER" --since "$SINCE" 2>&1 | grep -c '"status": 502' || true)"

if [[ -z "$REFUSALS" && "$COUNT" == "0" ]]; then
  echo "WARM: no sealed refusals in the last $SINCE"
  exit 0
fi

echo "COLD PATHS detected in the last $SINCE (${COUNT} sealed 502s):"
docker logs "$CONTAINER" --since "$SINCE" 2>&1 |
  grep '"status": 502' |
  grep -o '"uri": "[^"]*"' | sort | uniq -c | sort -rn || true
exit 1
