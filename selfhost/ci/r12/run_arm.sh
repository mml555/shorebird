#!/usr/bin/env bash
# R12 decisive arm — runs INSIDE a fresh linux/amd64 container.
#
# ORDER MATTERS AND IS NOT NEGOTIABLE:
#   1. prove the container is clean
#   2. bootstrap the OWNED toolchain (Flutter mirror + our CDN)   <-- CHECKPOINT
#   3. mint an ephemeral Android release key
#   4. run the FROZEN ci_noninteractive.sh, unmodified
#
# THERE IS NO FALLBACK. If the owned Linux bootstrap artifact is missing, this
# stops at that exact artifact and reports revision/slice/URL/response. It must
# never reach for upstream Flutter, Dart or engine bytes: a green run bought that
# way would only show that self-hosted Shorebird works on Linux PROVIDED upstream
# supplies part of the toolchain, which is materially weaker than the platform
# being certified.
set -uo pipefail

say()  { printf '\n== %s ==\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

: "${R12_REPO_URL:?}"; : "${R12_REPO_SHA:?}"
: "${SHOREBIRD_FLUTTER_GIT_URL:?}"; : "${FLUTTER_STORAGE_BASE_URL:?}"
: "${SHOREBIRD_HOSTED_URL:?}"
# BOOTSTRAP-ONLY stops after the toolchain checkpoint and runs NO arm. It needs no
# credential, and it must never be confused for a decisive run: a placeholder token
# would make the arms measure the auth path instead of the guard, which the frozen
# harness warns about in as many words.
BOOTSTRAP_ONLY="${R12_BOOTSTRAP_ONLY:-0}"
if [[ "$BOOTSTRAP_ONLY" != "1" ]]; then : "${SHOREBIRD_TOKEN:?}"; fi
SHOREBIRD_TOKEN="${SHOREBIRD_TOKEN:-}"
: "${R12_ARM_LABEL:?}"; : "${R12_RELEASE_VERSION:?}"
: "${SHOREBIRD_STORAGE_BASE_URL:?}"; : "${SHOREBIRD_STORAGE_BUCKET:?}"
export SHOREBIRD_FLUTTER_GIT_URL FLUTTER_STORAGE_BASE_URL SHOREBIRD_HOSTED_URL SHOREBIRD_TOKEN
# WITHOUT THESE THE SEAL IS A LIE. cache.dart defaults storageBaseUrl to
# https://storage.googleapis.com, so the CLI's own artifacts (patch-*.zip,
# aot-tools) would go straight to upstream while FLUTTER_STORAGE_BASE_URL made
# the run look sealed. Both are owned at the pinned engine and served from the
# overlay -- verified 2026-08-28: patch-linux-x64.zip and artifacts_manifest.yaml
# both 200 with X-Overlay: hit.
export SHOREBIRD_STORAGE_BASE_URL SHOREBIRD_STORAGE_BUCKET

OUT=/r12out; mkdir -p "$OUT"

# ------------------------------------------------------------- 1. clean -----
say "container cleanliness"
note "arm label                : $R12_ARM_LABEL"
note "uname                    : $(uname -s)/$(uname -m)"
note "HOME                     : $HOME"
for c in flutter dart shorebird; do
  command -v "$c" >/dev/null && die "$c is already on PATH — the substrate is contaminated"
done
note "flutter/dart/shorebird   : absent from PATH (as required)"
for d in "$HOME/.shorebird" "$HOME/.pub-cache" "$HOME/.gradle" "$HOME/.android" /root/.shorebird; do
  [[ -e "$d" ]] && die "$d exists — a pre-seeded cache would make this arm a no-op"
done
note "caches                   : none present"
[[ -z "${CI:-}${GITHUB_ACTIONS:-}${JENKINS_URL:-}" ]] || die "CI vars set; see the harness header"
note "CI detection vars        : none set"

# ------------------------------------------------- 1b. trust our CA ---------
# Gradle 9 refuses insecure Maven repositories, and FLUTTER_STORAGE_BASE_URL
# becomes a Maven repository during an Android release build:
#
#   Using insecure protocols with repositories, without explicit opt-in,
#   is unsupported.
#
# So the mirror is reached over HTTPS with validation ENFORCED. The alternative,
# a Gradle init script allowing insecure protocols, would make this arm prove
# less than accept_android_default.sh already does.
#
# The CA arrives as data in R12_CA_PEM rather than as a mount, so the "no host
# mounts" boundary is untouched. It goes into BOTH trust stores: the system
# bundle for curl/Dart and the JDK's for Gradle, which does not read the system
# one.
if [[ -n "${R12_CA_PEM:-}" ]]; then
  say "trusting the mirror CA"
  printf '%s\n' "$R12_CA_PEM" > /usr/local/share/ca-certificates/selfhost-cdn.crt
  update-ca-certificates >/dev/null 2>&1 || die "update-ca-certificates failed"
  "${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}/bin/keytool" -importcert \
    -cacerts -storepass changeit -noprompt -alias selfhost-cdn-mirror \
    -file /usr/local/share/ca-certificates/selfhost-cdn.crt >/dev/null 2>&1 \
    || die "could not import the CA into the JDK trust store"
  note "CA installed             : system bundle + JDK cacerts"
  # Prove it before anything depends on it: validation ON, no -k.
  code="$(curl -sS -o /dev/null -m 30 -w '%{http_code}' "$FLUTTER_STORAGE_BASE_URL/" 2>&1 || echo FAIL)"
  note "mirror over TLS          : $FLUTTER_STORAGE_BASE_URL -> $code (CA validation enforced)"
fi

# ------------------------------------------------- 2. owned toolchain -------
say "bootstrap the OWNED toolchain"
note "repo                     : $R12_REPO_URL"
note "sha                      : $R12_REPO_SHA"
git clone --quiet --filter=blob:none "$R12_REPO_URL" /r12src \
  || die "could not clone the owned repository"
git -C /r12src checkout --quiet --detach "$R12_REPO_SHA" \
  || die "owned repository does not contain $R12_REPO_SHA"
got="$(git -C /r12src rev-parse HEAD)"
[[ "$got" == "$R12_REPO_SHA" ]] || die "checked out $got, expected $R12_REPO_SHA"
note "checked out              : $got"

pinned="$(cat /r12src/bin/internal/flutter.version)"
note "flutter.version (pinned) : $pinned"
note "flutter git url          : $SHOREBIRD_FLUTTER_GIT_URL"
note "artifact CDN (flutter)   : $FLUTTER_STORAGE_BASE_URL"
note "artifact CDN (shorebird) : $SHOREBIRD_STORAGE_BASE_URL / $SHOREBIRD_STORAGE_BUCKET"

export PATH="/r12src/bin:$PATH"
BOOTSTRAP_LOG="$OUT/bootstrap.log"
say "first shorebird invocation (this is what performs the bootstrap)"
if ! ( cd /r12src && shorebird --version ) < /dev/null > "$BOOTSTRAP_LOG" 2>&1; then
  note "BOOTSTRAP FAILED — classifying before anything else runs"
  tail -40 "$BOOTSTRAP_LOG" | sed 's/^/     | /'
  # Name the exact artifact, if the failure was an artifact fetch. Reported, not
  # worked around: a missing owned Linux slice is an R12 PREREQUISITE finding.
  miss="$(grep -oE 'https?://[^ "]+\.zip' "$BOOTSTRAP_LOG" | tail -1 || true)"
  if [[ -n "$miss" ]]; then
    code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$miss" || echo FAIL)"
    note "last artifact URL        : $miss"
    note "its response             : $code"
  fi
  die "R12 prerequisite: the supported self-hosted Flutter toolchain did not
     bootstrap on Linux/x64 from owned bytes. NO upstream substitution was
     attempted, by design. Classify this before changing anything."
fi
note "bootstrap OK"
sed 's/^/     | /' "$BOOTSTRAP_LOG" | tail -8
note "shorebird                : $(command -v shorebird)"
( cd /r12src && shorebird --version ) < /dev/null 2>&1 | sed 's/^/     | /' | tail -3

flutter_sha="$(git -C "/r12src/bin/cache/flutter/$pinned" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
note "bootstrapped flutter sha : $flutter_sha"
[[ "$flutter_sha" == "$pinned" ]] \
  || die "bootstrapped Flutter is $flutter_sha, not the pinned $pinned"

if [[ "$BOOTSTRAP_ONLY" == "1" ]]; then
  say "BOOTSTRAP-ONLY — THIS IS NOT A DECISIVE ARM"
  note "The owned toolchain bootstrapped on clean Linux/x64. NO release and NO"
  note "patch ran, no credential was used, and nothing here bears on R12's"
  note "release/patch rows. It discharges exactly one checkpoint: that the"
  note "supported environment is CONSTRUCTIBLE from owned bytes."
  exit 0
fi

# ------------------------------------------------ 3. ephemeral signing ------
# A prerequisite for producing a release artifact, and NOTHING MORE. R12 asserts
# nothing about signing identity, key preservation, Play signing or signing
# correctness — Signing is separately certified (P6 criterion 12). The key is
# generated here, used for both release and patch in this one arm, and dies with
# the container. The B2 private key is deliberately NOT reused: coupling R12 to
# credentials from a closed lane buys nothing.
say "ephemeral Android release key"
APP_DIR=/r12src/selfhost/fixtures/android_signing_app
KS=/r12home/r12-ephemeral.jks
PW="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
"${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}/bin/keytool" -genkeypair -noprompt \
  -keystore "$KS" -storetype PKCS12 -alias r12 \
  -keyalg RSA -keysize 2048 -validity 30 \
  -dname "CN=R12 Ephemeral, OU=CI, O=Selfhost, C=US" \
  -storepass "$PW" -keypass "$PW" > "$OUT/keytool.log" 2>&1 \
  || { cat "$OUT/keytool.log"; die "could not mint the ephemeral keystore"; }
cat > "$APP_DIR/android/key.properties" <<EOF
storeFile=$KS
storePassword=$PW
keyAlias=r12
keyPassword=$PW
EOF
note "keystore                 : $KS (ephemeral, dies with the container)"
note "key.properties           : written, not echoed"

# RECORDED FIXTURE ADAPTATION, not a harness change: a release version is
# immutable on the control plane, so two independent arms cannot both publish
# 1.0.0+1. The harness derives its version from pubspec.yaml, so setting it here
# keeps the harness self-consistent and unmodified.
sed -i -E "s/^version:.*/version: $R12_RELEASE_VERSION/" "$APP_DIR/pubspec.yaml"
note "release version          : $R12_RELEASE_VERSION (recorded adaptation)"

# Non-mutating observation so arm 3 is interpretable: its chooser only fires with
# two or more releases, and "exit 0" would otherwise be ambiguous.
say "pre-arm control-plane state"
note "control plane            : $SHOREBIRD_HOSTED_URL"
( cd "$APP_DIR" && shorebird releases list ) < /dev/null > "$OUT/releases_before.log" 2>&1 || true
sed 's/^/     | /' "$OUT/releases_before.log" | head -20

# ------------------------------------------------------ 4. frozen arms ------
# Run EXACTLY as frozen. Both streams redirected: the harness refuses if either
# is a terminal, and that refusal is the whole measurement.
say "frozen ci_noninteractive.sh"
note "cmd: ci_noninteractive.sh --app-dir $APP_DIR --out $OUT/harness"
rc=0
/r12src/selfhost/scripts/ci_noninteractive.sh \
  --app-dir "$APP_DIR" --out "$OUT/harness" \
  < /dev/null > "$OUT/ci_noninteractive.log" 2>&1 || rc=$?
note "harness exit             : $rc"
sed 's/^/     | /' "$OUT/ci_noninteractive.log"
say "arm $R12_ARM_LABEL finished with exit $rc"
exit "$rc"
