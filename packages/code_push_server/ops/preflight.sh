#!/usr/bin/env bash
#
# preflight.sh — check that the server image you are about to start accepts
# this deployment's .env, BEFORE the running container is replaced.
#
# Why: the server refuses to boot on a config it rejects (exit 78), and a
# release can add a rule. 2.0.0 made IDP_ISSUER mandatory in production when an
# IdP is configured; `up -d server` then replaced the working container with
# one that crash-looped, taking login, the CLI and device check-ins down with
# it. This runs the new image's own Config.validate against the exact
# environment compose would give it (.env, compose defaults and overrides), in
# a throwaway container that touches no database, object store or port.
#
# Usage (between pulling/building the new image and `up -d`):
#   ./ops/preflight.sh
#   docker compose -f docker-compose.prod.yaml up -d server   # only if it passed
#
# Exit: 0 config accepted; 1 could not run the check; 78 config rejected (the
# reasons are printed). CPS_IMAGE, COMPOSE_FILE and ENV_FILE apply as for the
# other ops scripts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${COMPOSE_FILE}" ]] || die "no such compose file: ${COMPOSE_FILE}"
[[ -f "${ENV_FILE}" ]]     || die "no .env at ${ENV_FILE} (run ./setup.sh, or set ENV_FILE)"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

DC=(docker compose --progress quiet -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")

# A compose file that does not parse would otherwise fail halfway through `up`.
"${DC[@]}" config -q || die "docker compose could not resolve ${COMPOSE_FILE}"

IMAGE="$("${DC[@]}" config --images | grep -m1 'code-push-server' || true)"
echo "==> Checking config against ${IMAGE:-the server image}"

# --no-deps: no postgres/seaweedfs start. --entrypoint is left alone: the
# image's entrypoint is the server binary, which exits after validating.
set +e
"${DC[@]}" run --rm --no-deps -T server --check-config
status=$?
set -e

if [[ ${status} -eq 78 ]]; then
  echo "==> REJECTED: the new image will not boot with this .env. Fix it, then re-run." >&2
  echo "    The running container has not been touched." >&2
  exit 78
elif [[ ${status} -ne 0 ]]; then
  die "the check itself failed (exit ${status}); is the image present? Pull or build it first."
fi
echo "==> OK: safe to replace the container."
