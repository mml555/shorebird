#!/usr/bin/env bash
# Discover and close the owned bootstrap artifact set for one engine revision.
#
# The loop is: bootstrap against a SEALED, COLD mirror -> it stops at the first
# artifact we do not own -> import those exact bytes with provenance -> repeat,
# until the bootstrap completes with no upstream fetch having been possible.
#
# WHY SEALED AND COLD BOTH. sealed.caddy still serves CACHE HITS by design, and
# the production mirror has ~1GB warm. Sealed alone would therefore let a cached
# upstream artifact satisfy the bootstrap and report a closure that does not
# exist. r12-cdn-sealed is a separate instance with its own EMPTY cache volume,
# so a 200 can only have come from /overlay — and the access log says so
# explicitly with X-Overlay: hit.
#
# THESE RUNS ARE NOT EVIDENCE. The container is reused between iterations so the
# loop is quick. The decisive proof is a FRESH container against the sealed cold
# mirror, run separately once this reports closed.
set -uo pipefail

ENG="${1:-69f9831c360d9152862ec3897c67fb09ae843f3b}"
MAXIT="${MAXIT:-25}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED=http://host.docker.internal:8086
REPO_SHA="${R12_REPO_SHA:?set R12_REPO_SHA}"

note() { printf '   %s\n' "$*"; }
say()  { printf '\n== %s ==\n' "$*"; }

if ! docker ps --format '{{.Names}}' | grep -qx r12-discovery; then
  say "creating the discovery container"
  docker rm -f r12-discovery >/dev/null 2>&1
  docker run -d --name r12-discovery --platform linux/amd64 \
    -e HOME=/r12home \
    -e SHOREBIRD_FLUTTER_GIT_URL=git://host.docker.internal:9418/flutter.git \
    -e FLUTTER_STORAGE_BASE_URL="$SEALED" \
    r12-builder:substrate sleep infinity >/dev/null
  docker exec r12-discovery bash -lc "
    mkdir -p /r12home &&
    git clone --quiet --filter=blob:none https://github.com/mml555/shorebird.git /r12src &&
    git -C /r12src checkout --quiet --detach $REPO_SHA" \
    || { echo "clone failed"; exit 1; }
  note "cloned at $REPO_SHA"
fi

for i in $(seq 1 "$MAXIT"); do
  say "iteration $i — bootstrap against the SEALED COLD mirror"
  before="$(docker logs r12-cdn-sealed 2>&1 | wc -l | tr -d ' ')"
  rc=0
  # NOT `bash -lc`: a login shell re-reads /etc/profile and discards the PATH we
  # pass in, so shorebird was never found and every iteration failed 127 without
  # a single request reaching the mirror. Export inside the command instead.
  docker exec r12-discovery bash -c \
    'export PATH=/r12src/bin:$PATH; cd /r12src && shorebird --version' \
    > "$HERE/discovery_iter.log" 2>&1 || rc=$?
  if [[ "$rc" -eq 127 ]]; then
    say "STOP — command not found inside the container (harness error, not a finding)"
    tail -10 "$HERE/discovery_iter.log" | sed 's/^/     | /'
    exit 1
  fi
  if [[ "$rc" -eq 0 ]]; then
    say "BOOTSTRAP COMPLETED under seal after $((i-1)) additions"
    exit 0
  fi
  note "bootstrap exit $rc — finding what it could not reach"

  # `mapfile` is bash 4+; this host runs bash 3.2, where it silently does not
  # exist and the array stays unset.
  missing=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && missing+=("$line")
  done < <(
    docker logs r12-cdn-sealed 2>&1 | tail -n +"$((before+1))" \
      | grep '"status": *502' \
      | grep -oE '"uri": *"[^"]+"' | sed 's/.*"uri": *"//; s/"$//' \
      | sort -u
  )
  if [[ "${#missing[@]}" -eq 0 ]]; then
    say "STOP — the bootstrap failed but NOTHING was refused by the seal"
    note "That is a different failure and must be classified, not looped on."
    tail -30 "$HERE/discovery_iter.log" | sed 's/^/     | /'
    exit 1
  fi

  for uri in "${missing[@]}"; do
    rel="${uri#/gcs/download.shorebird.dev/flutter_infra_release/flutter/$ENG/}"
    if [[ "$rel" == "$uri" ]]; then
      say "STOP — refused URI is outside the flutter_infra_release namespace"
      note "$uri"
      note "Importing it is a different provenance question. Classify first."
      exit 1
    fi
    note "importing $rel"
    "$HERE/mirror_bootstrap_artifact.sh" "$ENG" "$rel" | sed 's/^/     /' \
      || { say "STOP — could not import $rel"; exit 1; }
  done
done
say "STOP — still not closed after $MAXIT iterations"
exit 1
