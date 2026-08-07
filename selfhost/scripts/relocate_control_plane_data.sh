#!/usr/bin/env bash
# cspell:words ENVFILE PORTMAP
# relocate_control_plane_data.sh — move a control plane's persistent data out of
# a session scratchpad into a named, documented location.
#
# WHY
#
# cps-ios and cps-android kept their /data bind mounts inside per-session
# scratchpad directories:
#
#   cps-ios      .../b5a4ac4a-…/scratchpad/cps-data          927 MB
#   cps-android  .../e7ae16e6-…/scratchpad/cps-android-data  334 MB
#
# Those directories belong to sessions that ended long ago and are subject to
# cleanup. They hold every app id, release, patch and artifact both rigs have
# ever produced — the same ephemeral-state failure class that already cost the
# 2026-08-06 acceptance its reproducibility when the fixture app's scratchpad
# was cleaned. This is a STORAGE-OWNERSHIP fix only: no schema change, no
# database migration, no control-plane redesign.
#
#   relocate_control_plane_data.sh [--container NAME]... [--dest-root DIR]
#                                  [--purge-source] [--dry-run]
#
# Default containers: cps-ios cps-android
# Default dest root:  ~/shorebird-rig/control-plane
#
# Idempotent: a container already rooted under --dest-root is left alone.
# The source is KEPT by default (renamed .migrated-<date>) so a bad move is
# recoverable; --purge-source removes it only after verification passes.
set -euo pipefail

DEST_ROOT="${CONTROL_PLANE_ROOT:-$HOME/shorebird-rig/control-plane}"
CONTAINERS=()
PURGE=0
DRY=0

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINERS+=("${2:?}"); shift 2 ;;
    --dest-root) DEST_ROOT="${2:?}"; shift 2 ;;
    --purge-source) PURGE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ ${#CONTAINERS[@]} -gt 0 ]] || CONTAINERS=(cps-ios cps-android)

command -v docker >/dev/null || die "docker is not on PATH"
command -v rsync >/dev/null || die "rsync is required"

# A path is "ephemeral" if it sits in a scratch/temp/session tree. This is the
# same predicate the acceptance preflight uses, so the two cannot disagree.
is_ephemeral_path() {
  case "$1" in
    */scratchpad/*|/tmp/*|/private/tmp/*|/var/folders/*) return 0 ;;
    *) return 1 ;;
  esac
}

relocate_one() {
  local c="$1" src dst image portmap envfile tmp
  docker inspect "$c" >/dev/null 2>&1 || { note "$c: no such container, skipping"; return 0; }

  src="$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
  [[ -n "$src" ]] || { note "$c: no /data mount, skipping"; return 0; }
  dst="$DEST_ROOT/$c"

  if [[ "$src" == "$dst" ]]; then
    note "$c: already at $dst"
    return 0
  fi
  if ! is_ephemeral_path "$src" && [[ -z "${FORCE_RELOCATE:-}" ]]; then
    note "$c: $src is already outside a scratch tree; leaving it (FORCE_RELOCATE=1 to move anyway)"
    return 0
  fi
  [[ -d "$src" ]] || die "$c: mount source $src does not exist — refusing to touch the container"

  note "$c: $src"
  note "$c: -> $dst"
  if [[ $DRY -eq 1 ]]; then note "$c: dry run, nothing done"; return 0; fi

  # --- copy with the container STOPPED, so nothing is mid-write ---------------
  note "$c: stopping"
  docker stop "$c" >/dev/null
  mkdir -p "$dst"
  rsync -a --delete "$src"/ "$dst"/ || die "$c: rsync failed; container is stopped and source untouched"

  # --- verify before rewiring anything ---------------------------------------
  # Verify CONTENT, not disk usage. `du` counts allocated blocks, which differ
  # across filesystems for byte-identical trees — the first attempt refused a
  # perfectly good copy over a 4 KB block-accounting difference.
  local sf df diffs
  sf="$(find "$src" -type f | wc -l | tr -d ' ')"
  df="$(find "$dst" -type f | wc -l | tr -d ' ')"
  [[ "$sf" == "$df" ]] || die "$c: file count differs ($sf -> $df); source untouched"
  # rsync's own checksum comparison is the authoritative answer: any line of
  # output is a file whose CONTENT differs.
  diffs="$(rsync -ain --checksum "$src"/ "$dst"/ | grep -vE '^\.d|^$' | head -5 || true)"
  [[ -z "$diffs" ]] || { echo "$diffs" >&2; die "$c: content differs after copy; source untouched"; }
  # The database byte for byte as well, since it is the part that matters most.
  local sdb
  while IFS= read -r sdb; do
    local rel="${sdb#"$src"/}"
    cmp -s "$sdb" "$dst/$rel" || die "$c: $rel differs after copy; source untouched"
    note "$c: verified $rel byte-identical"
  done < <(find "$src" -maxdepth 1 -name '*.db')
  note "$c: verified $sf files, checksums match"

  # --- recreate on the new mount, preserving everything else ------------------
  # Same approach as prepare_ios_endpoint.sh: every env var (secrets included)
  # goes through a 0600 file rather than a command line.
  tmp="$(mktemp -d)"; envfile="$tmp/env"; umask 077
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -vE '^(PATH=|$)' > "$envfile"
  image="$(docker inspect "$c" --format '{{.Config.Image}}')"
  portmap="$(docker inspect "$c" \
    --format '{{range $p, $co := .HostConfig.PortBindings}}{{range $co}}{{.HostPort}}{{end}}:{{$p}}{{end}}' \
    | sed 's|/tcp||')"
  [[ -n "$image" && -n "$portmap" ]] || die "$c: could not read image/ports"

  # Any non-/data mounts are carried over unchanged. Note the guarded
  # expansion below: under `set -u`, bash 3.2 (macOS) treats "${arr[@]}" on an
  # EMPTY array as an unbound variable and aborts — which it did here, after
  # `docker rm -f` had already run, leaving the container deleted mid-move.
  local extra=()
  while IFS= read -r m; do
    [[ -n "$m" ]] && extra+=(-v "$m")
  done < <(docker inspect "$c" \
      --format '{{range .Mounts}}{{if ne .Destination "/data"}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}{{end}}')

  docker rm -f "$c" >/dev/null
  docker run -d --name "$c" --restart unless-stopped --env-file "$envfile" \
    -p "$portmap" -v "$dst:/data" ${extra[@]+"${extra[@]}"} "$image" >/dev/null \
    || { rm -rf "$tmp"; die "$c: recreate failed. Data is intact at BOTH $src and $dst"; }
  rm -rf "$tmp"
  sleep 3
  note "$c: recreated on $dst"

  # --- prove the rig still works ---------------------------------------------
  local port code
  port="${portmap%%:*}"
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://localhost:$port/" || echo FAIL)"
  [[ "$code" == "200" ]] || die "$c: not answering on :$port after the move (got $code)"
  note "$c: healthy on :$port"

  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$src"; note "$c: source purged"
  else
    local keep="$src.migrated-$(date +%Y%m%d)"
    mv "$src" "$keep" 2>/dev/null && note "$c: source kept at $keep" \
      || note "$c: source left at $src"
  fi
}

for c in "${CONTAINERS[@]}"; do relocate_one "$c"; echo; done

echo "authoritative control-plane root: $DEST_ROOT"
echo "back it up with:  tar -C \"$DEST_ROOT\" -czf control-plane-\$(date +%F).tgz ."
