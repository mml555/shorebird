#!/usr/bin/env bash
# Sourced by the ops scripts after .env is loaded. Resolves the object-store
# credentials: S3_ACCESS_KEY / S3_SECRET_KEY, falling back to the deprecated
# MINIO_ROOT_USER / MINIO_ROOT_PASSWORD an older .env still carries (with a
# one-line warning naming the replacement). The values are exported so
# `docker compose` substitutes them into the rclone service.

for _pair in MINIO_ROOT_USER:S3_ACCESS_KEY MINIO_ROOT_PASSWORD:S3_SECRET_KEY; do
  _old="${_pair%%:*}"; _new="${_pair##*:}"
  if [[ -n "${!_old:-}" ]]; then
    if [[ -z "${!_new:-}" ]]; then
      export "${_new}=${!_old}"
      echo "WARNING: ${_old} is deprecated, use ${_new}" >&2
    else
      echo "WARNING: ${_old} is deprecated, use ${_new} (${_new} is set, so ${_old} is ignored)" >&2
    fi
  fi
done
unset _pair _old _new
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-cps}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY must be set (MINIO_ROOT_PASSWORD is accepted as a deprecated alias)}"
export S3_SECRET_KEY
