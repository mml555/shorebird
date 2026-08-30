#!/usr/bin/env bash
# R12 launcher — starts ONE decisive arm in a genuinely fresh container.
#
#   launch.sh <arm-label> <release-version>
#
# THE CONTAINER GETS NO HOST MOUNTS. Not the working tree, not a Flutter cache,
# not a Dart cache, not ~/.shorebird, not a Gradle cache. Evidence comes back out
# with `docker cp` afterwards, so there is never a writable host path inside the
# arm. The toolchain arrives over the network from owned services, exactly as it
# would on a real CI builder.
#
# The only injected secret is SHOREBIRD_TOKEN, the credential genuinely required
# for noninteractive control-plane auth. The Android keystore is NOT injected —
# run_arm.sh mints an ephemeral one inside the container.
set -euo pipefail

ARM="${1:?usage: launch.sh <arm-label> <release-version>}"
RELVER="${2:?usage: launch.sh <arm-label> <release-version>}"

REPO_URL="${R12_REPO_URL:-https://github.com/mml555/shorebird.git}"
REPO_SHA="${R12_REPO_SHA:?set R12_REPO_SHA to the full 40-hex owned CLI commit}"
PRODUCER="${R12_PRODUCER_REVISION:-fc184af6509a93eaf6fc068c6820639b324175a8}"
# Default is the historical mirror. Point this at the SEALED COLD instance
# (:8086) to prove the toolchain came from owned bytes: sealed alone is not
# enough, because sealed.caddy still serves cache hits and the production mirror
# is warm.
CDN="${R12_CDN:-http://host.docker.internal:8085}"
# Passed as data, never mounted. Public certificate, not a secret.
CA_FILE="${R12_CA_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../cdn/tls-r12" 2>/dev/null && pwd)/ca.crt}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE="${R12_EVIDENCE_DIR:-$HERE/../../evidence/r12-linux-ci}"

say() { printf '\n== %s ==\n' "$*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

say "preflight (host side)"

# Full-SHA fail-closed guard. A prefix, a fabricated SHA, an uppercase SHA or an
# iOS cell must never reach a decisive arm — see PREFLIGHT.md for why this check
# exists rather than being a note in a file.
"$HERE/../r12_revision_guard.sh" "$PRODUCER" \
  || die "producer revision refused by the guard"

# THE INVOCATION POINT. A permanent guard nobody calls is documentation with an
# exit code, so the closure is re-proved before every arm: pin -> owned mirror ->
# engine.version -> manifest -> every artifact by size and SHA-256. It cannot
# live in hosted CI (it reads the gitignored overlay and the local bare mirror),
# so this is where it runs until a self-hosted workflow exists.
"$HERE/../bootstrap_closure_guard.sh" \
  || die "owned bootstrap closure is incomplete — see the guard output above.
     Repair with r12/mirror_bootstrap_artifact.sh; do NOT move the Flutter pin."

[[ "$REPO_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || die "R12_REPO_SHA '$REPO_SHA' is not 40 lowercase hex. Branches are not
     provenance and a prefix is not a revision."

if [[ "${R12_BOOTSTRAP_ONLY:-0}" != "1" ]]; then
  [[ -n "${SHOREBIRD_TOKEN:-}" ]] \
    || die "SHOREBIRD_TOKEN is unset. It is the one credential a decisive arm
     needs, and this script deliberately does not read it out of any running
     container. For the toolchain checkpoint alone, set R12_BOOTSTRAP_ONLY=1."
fi

# The owned Flutter mirror must be up AND serving the pinned revision.
docker ps --format '{{.Names}}' | grep -qx r12-flutter-git \
  || die "r12-flutter-git is not running (the owned Flutter mirror service)"
PINNED=a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
got="$(docker run --rm --platform linux/amd64 --entrypoint git alpine/git:latest \
        ls-remote git://host.docker.internal:9418/flutter.git \
        refs/heads/selfhost/3.44.8 2>/dev/null | awk '{print $1}')"
[[ "$got" == "$PINNED" ]] \
  || die "owned Flutter mirror serves '$got', expected the pinned $PINNED"
echo "   owned flutter mirror     : serves $PINNED"

for svc in "CDN $CDN/flutter_infra_release/flutter/$PRODUCER/android-arm64-release/linux-x64.zip" \
           "control-plane http://host.docker.internal:18081/"; do
  name="${svc%% *}"; url="${svc#* }"
  code="$(docker run --rm --platform linux/amd64 curlimages/curl:latest \
            -sS -o /dev/null -m 20 -w '%{http_code}' "$url" 2>/dev/null || echo FAIL)"
  printf '   %-24s : %s -> %s\n' "$name" "${url:0:64}" "$code"
  [[ "$code" == "200" ]] || die "$name unreachable from a container ($code)"
done

CNAME="r12-arm-$ARM"
docker rm -f "$CNAME" >/dev/null 2>&1 || true

say "arm $ARM — fresh container, no host mounts"
set +e
docker run --name "$CNAME" --platform linux/amd64 -i \
  -e HOME=/r12home \
  -e R12_ARM_LABEL="$ARM" \
  -e R12_RELEASE_VERSION="$RELVER" \
  -e R12_REPO_URL="$REPO_URL" \
  -e R12_REPO_SHA="$REPO_SHA" \
  -e SHOREBIRD_FLUTTER_GIT_URL="git://host.docker.internal:9418/flutter.git" \
  -e FLUTTER_STORAGE_BASE_URL="$CDN" \
  -e SHOREBIRD_STORAGE_BASE_URL="$CDN" \
  -e SHOREBIRD_STORAGE_BUCKET="download.shorebird.dev" \
  -e SHOREBIRD_HOSTED_URL="${SHOREBIRD_HOSTED_URL:-http://localhost:18081}" \
  -e SHOREBIRD_TOKEN="${SHOREBIRD_TOKEN:-}" \
  -e R12_BOOTSTRAP_ONLY="${R12_BOOTSTRAP_ONLY:-0}" \
  -e GRADLE_OPTS="-Xmx3g -Dorg.gradle.daemon=false -Dorg.gradle.vfs.watch=false -Dorg.gradle.workers.max=2" \
  -e R12_CA_PEM="$([[ -r "$CA_FILE" ]] && cat "$CA_FILE")" \
  r12-builder:substrate \
  bash -c 'mkdir -p /r12home && cat > /run_arm.sh && chmod +x /run_arm.sh && exec /run_arm.sh' \
  < "$HERE/run_arm.sh"
rc=$?
set -e

say "collecting evidence"
DEST="$EVIDENCE/arm-$ARM"
rm -rf "$DEST"; mkdir -p "$DEST"
docker cp "$CNAME:/r12out/." "$DEST/" 2>/dev/null || echo "   (no /r12out to collect)"
docker logs "$CNAME" > "$DEST/container.log" 2>&1 || true
echo "   evidence                 : $DEST"
docker rm -f "$CNAME" >/dev/null 2>&1 || true

say "arm $ARM exit $rc"
exit "$rc"
