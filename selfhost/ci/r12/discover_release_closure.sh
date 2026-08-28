#!/usr/bin/env bash
# Discover the release/patch artifact closure, the same way the bootstrap closure
# was found: run against a SEALED COLD mirror, import whatever it refuses, repeat.
#
#   SHOREBIRD_TOKEN=… R12_REPO_SHA=<40hex> ./discover_release_closure.sh
#
# THESE RUNS ARE NOT EVIDENCE. The container is reused so iterations are cheap,
# and each iteration publishes a throwaway 0.9.x release so a successful release
# in one round does not collide with the next. The decisive Arm A is a separate,
# single, uninterrupted run from a FRESH container after this reports closed —
# successful phases from discovery are never stitched into it.
#
# It mutates shared control-plane state by creating 0.9.x releases for the
# fixture app. Deliberate and recorded: 1.0.0+1 and 1.0.1+1 stay reserved for the
# decisive arms.
set -uo pipefail

: "${SHOREBIRD_TOKEN:?set SHOREBIRD_TOKEN}"
: "${R12_REPO_SHA:?set R12_REPO_SHA}"
MAXIT="${MAXIT:-30}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HTTPS, because Gradle 9 refuses insecure Maven repositories and
# FLUTTER_STORAGE_BASE_URL becomes one during an Android release build.
SEALED="${R12_CDN:-https://host.docker.internal:8087}"
CA_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../cdn/tls-r12" && pwd)/ca.crt"
CP="${SHOREBIRD_HOSTED_URL:-http://host.docker.internal:18081}"
APP=/r12src/selfhost/fixtures/android_signing_app
C=r12-discovery-rp

note() { printf '   %s\n' "$*"; }
say()  { printf '\n== %s ==\n' "$*"; }

# CONTAINER REUSE IS A HAZARD, NOT A CONVENIENCE. Reusing a running container
# silently carries its ORIGINAL environment: a run started after GRADLE_OPTS was
# added reused a container created before it, so the OOM remedy was absent while
# the log looked correct. Reuse only if the environment still matches, and say so
# either way.
want_opts="-Xmx3g -Dorg.gradle.daemon=false -Dorg.gradle.vfs.watch=false -Dorg.gradle.workers.max=2"
if docker ps --format '{{.Names}}' | grep -qx "$C"; then
  have_opts="$(docker exec "$C" printenv GRADLE_OPTS 2>/dev/null || true)"
  if [[ "$have_opts" != "$want_opts" ]]; then
    say "recreating the discovery container — its environment is stale"
    note "GRADLE_OPTS in container: '${have_opts:-<empty>}'"
    note "GRADLE_OPTS wanted      : '$want_opts'"
    docker rm -f "$C" >/dev/null 2>&1
  else
    note "reusing the discovery container (environment matches)"
  fi
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  say "creating the release/patch discovery container"
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" --platform linux/amd64 \
    -e HOME=/r12home \
    -e SHOREBIRD_FLUTTER_GIT_URL=git://host.docker.internal:9418/flutter.git \
    -e FLUTTER_STORAGE_BASE_URL="$SEALED" \
    -e SHOREBIRD_STORAGE_BASE_URL="$SEALED" \
    -e SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev \
    -e SHOREBIRD_HOSTED_URL="$CP" \
    -e SHOREBIRD_TOKEN="$SHOREBIRD_TOKEN" \
    -e GRADLE_OPTS="-Xmx3g -Dorg.gradle.daemon=false -Dorg.gradle.vfs.watch=false -Dorg.gradle.workers.max=2" \
    -e R12_CA_PEM="$(cat "$CA_FILE")" \
    r12-builder:substrate sleep infinity >/dev/null
  # Same two trust stores the decisive arm installs into, for the same reason:
  # Gradle does not read the system bundle.
  docker exec "$C" bash -c '
    printf "%s\n" "$R12_CA_PEM" > /usr/local/share/ca-certificates/selfhost-cdn.crt
    update-ca-certificates >/dev/null 2>&1
    "${JAVA_HOME}/bin/keytool" -importcert -cacerts -storepass changeit -noprompt \
      -alias selfhost-cdn-mirror -file /usr/local/share/ca-certificates/selfhost-cdn.crt \
      >/dev/null 2>&1' || { echo "CA trust failed"; exit 1; }
  docker exec "$C" bash -c "
    mkdir -p /r12home &&
    git clone --quiet --filter=blob:none https://github.com/mml555/shorebird.git /r12src &&
    git -C /r12src checkout --quiet --detach $R12_REPO_SHA" || { echo "clone failed"; exit 1; }
  # Ephemeral release key, exactly as a decisive arm mints one.
  docker exec "$C" bash -c '
    PW=$(head -c 24 /dev/urandom | base64 | tr -d "/+=" | head -c 24)
    "${JAVA_HOME}/bin/keytool" -genkeypair -noprompt -keystore /r12home/disc.jks \
      -storetype PKCS12 -alias r12 -keyalg RSA -keysize 2048 -validity 30 \
      -dname "CN=R12 Discovery, OU=CI, O=Selfhost, C=US" \
      -storepass "$PW" -keypass "$PW" >/dev/null 2>&1
    printf "storeFile=/r12home/disc.jks\nstorePassword=%s\nkeyAlias=r12\nkeyPassword=%s\n" \
      "$PW" "$PW" > '"$APP"'/android/key.properties' || { echo "keystore failed"; exit 1; }
  note "container ready at $R12_REPO_SHA"
fi

for i in $(seq 1 "$MAXIT"); do
  ver="0.9.$i+$i"
  say "iteration $i — frozen harness against the SEALED COLD mirror (v$ver)"
  before="$(docker logs r12-cdn-sealed 2>&1 | wc -l | tr -d ' ')"
  docker exec "$C" bash -c "sed -i -E 's/^version:.*/version: $ver/' $APP/pubspec.yaml"
  rc=0
  docker exec "$C" bash -c \
    "export PATH=/r12src/bin:\$PATH; /r12src/selfhost/scripts/ci_noninteractive.sh \
       --app-dir $APP --out /r12out/disc < /dev/null" \
    > "$HERE/rp_iter.log" 2>&1 || rc=$?
  note "harness exit $rc"

  missing=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && missing+=("$line")
  done < <(
    docker logs r12-cdn-sealed 2>&1 | tail -n +"$((before+1))" \
      | python3 "$HERE/pair_refusals.py"
  )

  if [[ "${#missing[@]}" -eq 0 ]]; then
    if [[ "$rc" -eq 0 ]]; then
      say "CLOSED — the frozen harness passed under seal with nothing refused"
      exit 0
    fi
    say "STOP — harness failed with NOTHING refused by the seal"
    note "A different failure. Classify it; do not loop."
    tail -40 "$HERE/rp_iter.log" | sed 's/^/     | /'
    exit 1
  fi

  note "${#missing[@]} artifact(s) refused this round"

  # NO-PROGRESS DETECTION. Without it a mis-addressed import loops forever
  # re-importing a file it already owns while the seal keeps refusing — which is
  # exactly what happened for 28 iterations before the pairing was fixed. An
  # unchanged refusal set means the last import did not take effect, and that is
  # a defect to classify, not a round to repeat.
  fingerprint="$(printf '%s\n' "${missing[@]}" | sort | shasum -a 256 | awk '{print $1}')"
  if [[ "$fingerprint" == "${last_fingerprint:-}" ]]; then
    say "STOP — the SAME artifacts were refused twice in a row"
    note "The previous import did not change what the mirror serves. Most likely"
    note "the bytes were written to the upstream address instead of the client"
    note "path. Verify with: curl -sSI <mirror>/<client_path> | grep X-Overlay"
    printf '     refused: %s\n' "${missing[@]}"
    exit 1
  fi
  last_fingerprint="$fingerprint"

  for pair in "${missing[@]}"; do
    client="${pair%%$'\t'*}"; gcs="${pair##*$'\t'}"
    note "importing $client"
    note "     from $gcs"
    "$HERE/mirror_cdn_artifact.sh" "$client" "$gcs" release_patch | sed 's/^/     /' \
      || { say "STOP — could not import $client"; exit 1; }
  done
done
say "STOP — still not closed after $MAXIT iterations"
exit 1
