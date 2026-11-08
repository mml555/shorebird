#!/usr/bin/env bash
# Serves the OWNED bare Flutter mirror to R12 containers over git://.
#
# WHY A SERVICE AND NOT A BIND MOUNT. Mounting selfhost/cdn/mirrors into the
# builder would hand the arm a host path, and the whole point of R12 is that a
# clean CI builder reproduces the supported toolchain from owned bytes reached
# over the network. This is the same shape as the CDN: an owned service the
# container fetches from, with no host filesystem inside the arm.
#
# The mirror is read-only to the container (:ro) and the daemon is export-all
# read-only by construction — git-daemon serves fetches, never pushes.
set -euo pipefail

MIRRORS="${MIRRORS:-/Users/mendell/shorebird/selfhost/cdn/mirrors}"
PINNED=a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61

[[ -d "$MIRRORS/flutter.git" ]] || { echo "no mirror at $MIRRORS/flutter.git" >&2; exit 1; }

docker rm -f r12-flutter-git >/dev/null 2>&1 || true
docker run -d --name r12-flutter-git --platform linux/amd64 \
  -p 9418:9418 -v "$MIRRORS:/srv:ro" \
  alpine:3.20 sh -c \
  "apk add --no-cache git git-daemon >/dev/null && exec git daemon --verbose \
     --export-all --base-path=/srv --reuseaddr --listen=0.0.0.0 --port=9418 /srv" >/dev/null

for _ in $(seq 1 20); do
  got="$(docker run --rm --platform linux/amd64 --entrypoint git alpine/git:latest \
          ls-remote git://host.docker.internal:9418/flutter.git \
          refs/heads/selfhost/3.44.8 2>/dev/null | awk '{print $1}')"
  [[ -n "$got" ]] && break
  sleep 2
done

# Not "the service is up" — the service is serving THE PINNED REVISION. Those are
# different claims and only the second one is worth anything.
[[ "$got" == "$PINNED" ]] || { echo "mirror serves '$got', expected $PINNED" >&2; exit 1; }
echo "r12-flutter-git: serving refs/heads/selfhost/3.44.8 -> $PINNED"
