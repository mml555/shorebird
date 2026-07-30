#!/usr/bin/env bash
#
# generate.sh — mint a local CA and a server certificate for the CDN mirror, so
# it can be served over HTTPS.
#
# WHY THIS EXISTS: Gradle 8+ refuses insecure (http) Maven repositories without an
# explicit opt-in, and Flutter's Gradle plugin turns FLUTTER_STORAGE_BASE_URL into
# exactly such a repository. So a plain-http mirror fails every Android release
# build at `:app:mergeReleaseAssets`, before a single Flutter artifact is fetched:
#
#   > Could not resolve all dependencies for configuration ':app:releaseRuntimeClasspath'
#      > Using insecure protocols with repositories, without explicit opt-in, is unsupported.
#
# Serving the mirror over https is the fix that does not involve patching the
# vended Flutter checkout on every build host.
#
# Two consumers have to trust the CA, and they use DIFFERENT trust stores:
#   * Gradle runs on the JVM, which uses the JDK's own `cacerts`.
#   * Dart/Flutter tooling uses the operating system store.
# `trust.sh` in this directory does both; read it before running it.
#
# Usage:
#   selfhost/cdn/tls/generate.sh [host ...]
#
# Hosts default to `localhost` plus `127.0.0.1`. Pass additional names if the
# mirror is reached over a LAN address or hostname, e.g.:
#   selfhost/cdn/tls/generate.sh localhost 192.168.1.20 mirror.lan
#
# Certificates land beside this script and are gitignored: a private key must
# never be committed, and every deployment should mint its own.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DAYS=825   # the maximum Safari/macOS accept for a server cert

hosts=("$@")
if [[ ${#hosts[@]} -eq 0 ]]; then
  hosts=(localhost)
fi

# Build the SAN list. A modern TLS client ignores CN entirely and validates
# against subjectAltName only, so getting this wrong looks like a hostname
# mismatch rather than a missing SAN.
san=""
dns_i=0
ip_i=0
for h in "${hosts[@]}"; do
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip_i=$((ip_i + 1))
    san+="IP.$ip_i = $h"$'\n'
  else
    dns_i=$((dns_i + 1))
    san+="DNS.$dns_i = $h"$'\n'
  fi
done
# 127.0.0.1 is always useful: the build host reaches the mirror over loopback.
ip_i=$((ip_i + 1))
san+="IP.$ip_i = 127.0.0.1"$'\n'

cat > "$DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[dn]
CN = selfhost-cdn-mirror local CA

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, keyCertSign, cRLSign

[server_req]
distinguished_name = server_dn
prompt             = no

[server_dn]
CN = selfhost-cdn-mirror

[server_ext]
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[alt_names]
$san
EOF

echo "==> CA"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$DIR/ca.key" -out "$DIR/ca.crt" \
  -config "$DIR/openssl.cnf" -extensions v3_ca 2>/dev/null

echo "==> server key + CSR"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$DIR/server.key" -out "$DIR/server.csr" \
  -config "$DIR/openssl.cnf" -section server_req 2>/dev/null

echo "==> signing server cert (${DAYS} days)"
openssl x509 -req -in "$DIR/server.csr" -sha256 -days "$DAYS" \
  -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -out "$DIR/server.crt" \
  -extfile "$DIR/openssl.cnf" -extensions server_ext 2>/dev/null

# nginx wants the chain in one file, leaf first.
cat "$DIR/server.crt" "$DIR/ca.crt" > "$DIR/fullchain.crt"
chmod 600 "$DIR/ca.key" "$DIR/server.key"
rm -f "$DIR/server.csr" "$DIR/.srl" "$DIR/ca.srl"

echo
echo "==> wrote:"
echo "      $DIR/ca.crt         <- the CA to trust (see trust.sh)"
echo "      $DIR/fullchain.crt  <- served by nginx"
echo "      $DIR/server.key     <- private key, never commit"
echo
echo "==> SANs on the server cert:"
openssl x509 -in "$DIR/server.crt" -noout -text \
  | sed -n '/Subject Alternative Name/{n;s/^ *//;p;}'
echo
echo "==> next:"
echo "      docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache"
echo "      selfhost/cdn/tls/trust.sh          # on every machine that BUILDS"
echo "      export FLUTTER_STORAGE_BASE_URL=https://localhost:8443"
