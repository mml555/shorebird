#!/usr/bin/env bash
#
# trust.sh — install the mirror's local CA where a BUILD HOST will look for it.
#
# Run this on every machine that runs `shorebird release` / `shorebird patch`
# against an https mirror. It is not needed on devices; they talk to the control
# plane, not the mirror.
#
# There are TWO trust stores in play, and missing either produces a confusing
# failure rather than a clear one:
#
#   * The JDK's `cacerts`, used by Gradle. Without it:
#       Could not GET '.../download.flutter.io/...'
#       PKIX path building failed: unable to find valid certification path
#   * The OS store, used by Dart/Flutter tooling. Without it:
#       HandshakeException: Handshake error in client
#       CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate
#
# Usage:
#   selfhost/cdn/tls/trust.sh            # install into both stores
#   selfhost/cdn/tls/trust.sh --print    # show what it WOULD do, change nothing
#
# Everything here is reversible; the undo commands are printed at the end.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CA="$DIR/ca.crt"
ALIAS="selfhost-cdn-mirror"
DRY=0
[[ "${1:-}" == "--print" ]] && DRY=1

[[ -f "$CA" ]] || {
  echo "no CA at $CA — run selfhost/cdn/tls/generate.sh first" >&2
  exit 1
}

run() {
  if [[ "$DRY" == "1" ]]; then
    echo "  WOULD: $*"
  else
    echo "  \$ $*"
    "$@"
  fi
}

echo "==> JDK truststore (Gradle)"
# Prefer the JDK Gradle will actually use. JAVA_HOME wins; otherwise ask the
# system. Android Studio's bundled JBR is a common third case, so it is reported
# rather than guessed at.
JH="${JAVA_HOME:-}"
if [[ -z "$JH" ]] && command -v /usr/libexec/java_home >/dev/null 2>&1; then
  JH="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
if [[ -z "$JH" ]] && command -v readlink >/dev/null 2>&1 && command -v javac >/dev/null 2>&1; then
  JH="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
fi

if [[ -z "$JH" ]]; then
  echo "  !! no JDK found. Set JAVA_HOME and re-run, or Gradle will not trust the CA."
else
  STORE="$JH/lib/security/cacerts"
  echo "  JDK: $JH"
  if [[ ! -f "$STORE" ]]; then
    echo "  !! no cacerts at $STORE"
  elif "$JH/bin/keytool" -list -cacerts -alias "$ALIAS" -storepass changeit >/dev/null 2>&1; then
    echo "  already trusted (alias $ALIAS)"
  else
    # -cacerts targets the JDK's own store without naming the path.
    run "$JH/bin/keytool" -importcert -noprompt -cacerts -storepass changeit \
      -alias "$ALIAS" -file "$CA"
  fi
fi

echo "==> OS store (Dart/Flutter)"
case "$(uname -s)" in
  Linux)
    if [[ -d /usr/local/share/ca-certificates ]]; then
      run sudo cp "$CA" "/usr/local/share/ca-certificates/$ALIAS.crt"
      run sudo update-ca-certificates
    elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
      run sudo cp "$CA" "/etc/pki/ca-trust/source/anchors/$ALIAS.crt"
      run sudo update-ca-trust
    else
      echo "  !! unknown Linux trust layout; add $CA manually"
    fi
    ;;
  Darwin)
    # Admin-only; asks for a password. Flutter tooling on macOS honours the
    # System keychain.
    run sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain "$CA"
    ;;
  *)
    echo "  !! unsupported OS; add $CA to the system trust store manually"
    ;;
esac

cat <<EOF

==> verify
      curl -sS -o /dev/null -w '%{http_code}\\n' https://localhost:8443/
      # and without --cacert: if that works, the CA is trusted properly

==> undo
      ${JH:-<JDK>}/bin/keytool -delete -cacerts -storepass changeit -alias $ALIAS
      # Linux: sudo rm /usr/local/share/ca-certificates/$ALIAS.crt && sudo update-ca-certificates
      # macOS: sudo security delete-certificate -c 'selfhost-cdn-mirror local CA' /Library/Keychains/System.keychain
EOF
