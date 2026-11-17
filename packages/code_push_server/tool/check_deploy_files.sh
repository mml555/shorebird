#!/usr/bin/env bash
#
# check_deploy_files.sh — static checks on the deploy files, run in CI.
#
#   1. The server image pinned in both compose files is this package's version.
#      A release bumps pubspec.yaml; if the compose pins lag, a fresh clone
#      installs an image without the fixes the docs describe.
#   2. The Caddyfile still answers 404 for /metrics and /readyz, and still
#      keeps /download out of `encode`.
#   3. `caddy validate`, when caddy is installed.
#
# Run from anywhere; exits non-zero on the first failing group.

set -euo pipefail

PKG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "${PKG_DIR}"

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

version="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9A-Za-z.+-]*\).*/\1/p' pubspec.yaml | head -1)"
[[ -n "${version}" ]] || { echo "FAIL: no version in pubspec.yaml" >&2; exit 1; }

for f in docker-compose.yaml docker-compose.prod.yaml; do
  pins="$(grep -o 'ghcr.io/mml555/code-push-server:[0-9A-Za-z.+-]*' "${f}" | sort -u || true)"
  [[ -n "${pins}" ]] || { bad "${f}: no ghcr.io/mml555/code-push-server:<version> pin found"; continue; }
  while IFS= read -r pin; do
    [[ "${pin##*:}" == "${version}" ]] \
      || bad "${f}: pins ${pin}, but pubspec.yaml is ${version}; bump the compose pin with the version"
  done <<<"${pins}"
done

grep -Eq '^[[:space:]]*@internal path .*/metrics .*/readyz' Caddyfile \
  || bad "Caddyfile: no '@internal path /metrics ... /readyz' matcher"
grep -Eq '^[[:space:]]*handle @internal' Caddyfile \
  && awk '/handle @internal/{f=1} f&&/respond 404/{ok=1} /^[[:space:]]*}/{if(f)exit} END{exit !ok}' Caddyfile \
  || bad "Caddyfile: 'handle @internal' does not respond 404"
grep -Eq '^[[:space:]]*@compressible not path /download/\*' Caddyfile \
  && grep -Eq '^[[:space:]]*encode @compressible' Caddyfile \
  || bad "Caddyfile: encode must use a matcher that excludes /download/*"
if grep -Eq '^[[:space:]]*encode[[:space:]]+(gzip|zstd)' Caddyfile; then
  bad "Caddyfile: a bare 'encode gzip zstd' compresses /download"
fi

if command -v caddy >/dev/null 2>&1; then
  DOMAIN=localhost ACME_EMAIL=ci@example.com \
    caddy validate --config Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || bad "caddy validate failed (run it by hand for the error)"
else
  echo "note: caddy not installed; skipped 'caddy validate'"
fi

if [[ ${fail} -ne 0 ]]; then exit 1; fi
echo "deploy files OK (image ${version})"
