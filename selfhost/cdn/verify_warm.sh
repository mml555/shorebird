#!/usr/bin/env bash
# verify_warm.sh — machine check that a sealed run needed nothing cold.
#
# In sealed mode (docker-compose.cdn.sealed.yaml) every upstream fetch the
# mirror refuses is answered with a "sealed: refusing upstream fetch" 502 and
# logged. If a build succeeded but this script finds refusals, the build
# quietly did without something it wanted — read the list and decide. If a
# build FAILED and this finds refusals, they are the reason.
#
# The mirror is frequently NOT on the machine running the acceptance payload
# (the Linux Android leg reaches this Mac's mirror over an SSH tunnel), so the
# log source is selectable:
#
#   verify_warm.sh                        # local docker container (default)
#   verify_warm.sh --ssh user@host:port   # docker on a remote host, over ssh
#   verify_warm.sh --log-file <path>      # a captured log file
#   verify_warm.sh --since 30m            # window (docker sources only)
#
# SSH_KEY=<path> is honored for --ssh. With --ssh, the remote must be able to
# run `docker logs` for the container.
#
# For a leg that runs on a host which CANNOT reach the mirror's docker (the
# usual case — the Linux box reaches the mirror through a reverse tunnel, not
# the other way round), stream the log to that host for the duration of the
# run and point --log-file at it. From the mirror host:
#
#   docker logs -f --since 1m shorebird-cdn-cdn-cache-1 2>&1 \
#     | ssh -i KEY -p PORT user@box 'cat > /tmp/mirror.log' &
#
# then run the leg with AIRGAP_VERIFY_ARGS="--log-file /tmp/mirror.log".
set -uo pipefail

SINCE="2h"
CONTAINER="${CDN_CONTAINER:-shorebird-cdn-cdn-cache-1}"
SOURCE="local"
SSH_TARGET=""
LOG_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:?}"; shift 2 ;;
    --ssh) SOURCE="ssh"; SSH_TARGET="${2:?}"; shift 2 ;;
    --log-file) SOURCE="file"; LOG_FILE="${2:?}"; shift 2 ;;
    --container) CONTAINER="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fetch_log() {
  case "$SOURCE" in
    local)
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER" || {
        echo "ERROR: $CONTAINER is not running locally. If the mirror lives on another host, use --ssh user@host:port (or --log-file)." >&2
        return 2
      }
      docker logs "$CONTAINER" --since "$SINCE" 2>&1
      ;;
    ssh)
      local host="${SSH_TARGET%%:*}" port="${SSH_TARGET##*:}"
      [[ "$port" == "$SSH_TARGET" ]] && port=22
      ssh ${SSH_KEY:+-i "$SSH_KEY"} -p "$port" -o BatchMode=yes "$host" \
        "docker logs $CONTAINER --since $SINCE 2>&1" \
        || { echo "ERROR: could not read docker logs on $host:$port" >&2; return 2; }
      ;;
    file)
      [[ -r "$LOG_FILE" ]] || { echo "ERROR: cannot read $LOG_FILE" >&2; return 2; }
      cat "$LOG_FILE"
      ;;
  esac
}

LOG="$(fetch_log)" || exit $?

# Refusals are NOT uniformly failures. Exactly one class is by design: a
# fork-hash aot-tools.dill. The overlay owns that path so it fails loudly
# instead of silently serving the pinned linker a fork engine cannot use, and
# the CLI treats it as optional — warns and continues. Anything else refused
# was a required artifact, which is a blocking failure.
#
# EXPECTED_REFUSALS is an extended-regex allowlist of URIs whose refusal is
# design, not breakage. Keep it SHORT and justify each entry: every pattern
# added here is a refusal nobody will look at again.
#
# No brace repetition ({40} for the hash): this has to run under whatever
# `grep` the host provides, and ugrep — which some hosts alias to grep —
# rejects it with "invalid repetition count(s)".
#   - aot-tools.dill on a fork hash: owned so it fails loudly; CLI warns on.
#   - AIRGAP-SEAL-PROBE: airgap_run.sh's own preflight probe, which exists
#     precisely to force a refusal and confirm the mirror is sealed.
#   - android-x86 / android-arm: Flutter precaches every Android ABI, but
#     nothing here ships 32-bit or x86 Android. Observed live: a sealed iOS
#     run refused android-x86/artifacts.zip and the release AND patch both
#     completed, so the artifact is genuinely unused. Only these two ABIs are
#     listed — a refusal for arm64 or x64 would be a real failure.
#   - "/" exactly: a health/reachability probe of the mirror root. No build
#     ever requests the bare root, so a refusal there is always a checker,
#     never a missing artifact.
EXPECTED_REFUSALS="${EXPECTED_REFUSALS:-/shorebird/[0-9a-f]+/aot-tools\.dill|AIRGAP-SEAL-PROBE|/android-x86/|/android-arm/|^/$}"

# bash 3.2 (macOS) has no mapfile, and this script runs on both hosts — keep
# it to a while-read loop over a temp file.
TALLY="$(mktemp)"; trap 'rm -f "$TALLY" "$TALLY.exp" "$TALLY.blk"' EXIT
grep '"status": 502' <<<"$LOG" | grep -o '"uri": "[^"]*"' |
  sed 's/"uri": "//; s/"$//' | sort | uniq -c | sort -rn > "$TALLY"

if [[ ! -s "$TALLY" ]]; then
  echo "WARM: no sealed refusals in the last $SINCE (source: $SOURCE)"
  exit 0
fi

: > "$TALLY.exp"; : > "$TALLY.blk"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  uri="${line##* }"
  if printf '%s' "$uri" | grep -qE "$EXPECTED_REFUSALS"; then
    printf '%s\n' "$line" >> "$TALLY.exp"
  else
    printf '%s\n' "$line" >> "$TALLY.blk"
  fi
done < "$TALLY"

if [[ -s "$TALLY.exp" ]]; then
  echo "EXPECTED refusals (by design — CLI warns and continues):"
  sed 's/^/  /' "$TALLY.exp"
fi

if [[ ! -s "$TALLY.blk" ]]; then
  echo "WARM: no BLOCKING refusals in the last $SINCE (source: $SOURCE)"
  exit 0
fi

echo "BLOCKING refusals — a required artifact was not available locally:"
sed 's/^/  /' "$TALLY.blk"
exit 1
