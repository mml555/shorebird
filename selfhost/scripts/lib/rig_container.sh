#!/usr/bin/env bash
# cspell:words portmap
# rig_container.sh — create a control-plane container from DURABLE inputs.
#
# THE OWNERSHIP DIRECTION
#
# The rig used to recreate containers like this:
#
#   old container -> recover enough state from it -> create new container
#
# which makes the container the authoritative copy of its own credentials. On
# 2026-08-07 that nearly lost them: a `docker rm -f` succeeded, the following
# `docker run` aborted on an unrelated bash error, and API_KEY and
# URL_SIGNING_SECRET existed nowhere else. They were recovered from a temp file
# that had not been cleaned up yet — luck, not design.
#
# The direction is now:
#
#   durable config + durable secrets + durable data -> container
#
# Nothing is ever read back out of a running container to rebuild it, and the
# old container is not destroyed until every input has been validated.
#
#   ~/shorebird-rig/secrets/<name>.env   0600, API_KEY + URL_SIGNING_SECRET
#   ~/shorebird-rig/config/<name>.env    non-secret: PORT, DATA_DIR, ...
#   ~/shorebird-rig/control-plane/<name> the data root
#
# Source this; it defines rig_preflight and rig_recreate.

RIG_ROOT="${RIG_ROOT:-$HOME/shorebird-rig}"
RIG_SECRETS_DIR="${RIG_SECRETS_DIR:-$RIG_ROOT/secrets}"
RIG_CONFIG_DIR="${RIG_CONFIG_DIR:-$RIG_ROOT/config}"
RIG_DATA_ROOT="${CONTROL_PLANE_ROOT:-$RIG_ROOT/control-plane}"

# Credentials that must be present. Losing either bricks the rig: API_KEY
# authenticates every CLI call, URL_SIGNING_SECRET signs artifact download URLs.
RIG_REQUIRED_SECRETS=(API_KEY URL_SIGNING_SECRET)

_rig_err() { echo "ERROR: $*" >&2; return 1; }

# rig_preflight <container> — prove every input exists BEFORE anything is
# destroyed. Prints only key NAMES, never values.
rig_preflight() {
  local c="${1:?container}" sec cfg data mode owner k rc=0
  sec="$RIG_SECRETS_DIR/$c.env"
  cfg="$RIG_CONFIG_DIR/$c.env"
  data="$RIG_DATA_ROOT/$c"

  [[ -f "$sec" ]] || { _rig_err "no secrets file: $sec
       Create it (0600) with ${RIG_REQUIRED_SECRETS[*]}. It is NOT recoverable
       from a deleted container — that is the whole reason this file exists."; rc=1; }
  if [[ -f "$sec" ]]; then
    mode="$(stat -f %Lp "$sec" 2>/dev/null || stat -c %a "$sec" 2>/dev/null)"
    [[ "$mode" == "600" ]] || { _rig_err "$sec has mode $mode, expected 600"; rc=1; }
    owner="$(stat -f %Su "$sec" 2>/dev/null || stat -c %U "$sec" 2>/dev/null)"
    [[ "$owner" == "$(id -un)" ]] || { _rig_err "$sec is owned by $owner, not $(id -un)"; rc=1; }
    for k in "${RIG_REQUIRED_SECRETS[@]}"; do
      grep -qE "^$k=.+" "$sec" || { _rig_err "$sec is missing $k"; rc=1; }
    done
  fi

  [[ -f "$cfg" ]] || { _rig_err "no config file: $cfg"; rc=1; }
  [[ -d "$data" ]] || { _rig_err "no data root: $data
       Move it with selfhost/scripts/relocate_control_plane_data.sh"; rc=1; }
  case "$data" in
    */scratchpad/*|/tmp/*|/private/tmp/*|/var/folders/*)
      _rig_err "data root is in an ephemeral path: $data"; rc=1 ;;
  esac

  [[ $rc -eq 0 ]] || return 1
  echo "  [rig] $c: secrets $(grep -cE '^[A-Z_]+=' "$sec") var(s) 0600, config $(grep -cE '^[A-Z_]+=' "$cfg") var(s), data $data"
}

# rig_recreate <container> <image> <portmap> [EXTRA_ENV=VAL]...
#
# Validates first, builds the env from the durable files, and only then removes
# and recreates. The assembled env lives in a 0600 temp file so no secret ever
# reaches a command line, a log, or shell history.
rig_recreate() {
  local c="${1:?container}" image="${2:?image}" portmap="${3:?ports}"; shift 3
  local tmp env_out kv

  rig_preflight "$c" || return 1
  [[ -n "$image" && -n "$portmap" ]] || { _rig_err "image and portmap are required"; return 1; }

  tmp="$(mktemp -d)" || return 1
  env_out="$tmp/env"
  ( umask 077; : > "$env_out" ) || { rm -rf "$tmp"; return 1; }
  cat "$RIG_CONFIG_DIR/$c.env" "$RIG_SECRETS_DIR/$c.env" > "$env_out"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$env_out"; done

  # Everything needed is in hand; only now is it safe to destroy the old one.
  docker rm -f "$c" >/dev/null 2>&1 || true
  if ! docker run -d --name "$c" --restart unless-stopped \
        --env-file "$env_out" -p "$portmap" \
        -v "$RIG_DATA_ROOT/$c:/data" "$image" >/dev/null; then
    rm -rf "$tmp"
    _rig_err "$c: docker run failed. Data, config and secrets are all intact on
       disk — re-run this command; nothing needs recovering from the container."
    return 1
  fi
  rm -rf "$tmp"
  echo "  [rig] $c: recreated from durable inputs"
}
