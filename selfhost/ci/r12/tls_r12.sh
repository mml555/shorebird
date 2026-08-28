#!/usr/bin/env bash
# Issue an R12 server certificate from the EXISTING mirror CA.
#
# WHY NOT tls/generate.sh. That script regenerates the CA unconditionally
# (tls/generate.sh:92). Rotating the CA would invalidate the trust already
# established on the Linux build box that accept_android_default.sh depends on —
# breaking another lane to fix this one. So this signs a NEW SERVER CERT with the
# CA that already exists, leaving tls/ca.* and tls/server.* untouched.
#
# WHY A CERT IS NEEDED AT ALL. Gradle 9 refuses insecure Maven repositories, and
# FLUTTER_STORAGE_BASE_URL becomes a Maven repository during an Android release
# build. The existing server cert carries SANs "localhost, 127.0.0.1" only, so a
# container reaching the mirror as host.docker.internal fails hostname
# verification. Note the alternative — a Gradle init script allowing insecure
# protocols — would make R12 prove LESS than accept_android_default.sh already
# does, which is exactly why it is not taken here.
set -euo pipefail

CDN=/Users/mendell/shorebird/selfhost/cdn
SRC="$CDN/tls"; OUT="$CDN/tls-r12"

[[ -f "$SRC/ca.key" && -f "$SRC/ca.crt" ]] \
  || { echo "no existing CA in $SRC — run tls/generate.sh once first" >&2; exit 1; }

mkdir -p "$OUT"
cat > "$OUT/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = selfhost-cdn-mirror r12
[v3_req]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt
[alt]
DNS.1 = host.docker.internal
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$OUT/server.key" -out "$OUT/server.csr" \
  -config "$OUT/openssl.cnf" 2>/dev/null
openssl x509 -req -in "$OUT/server.csr" -days 365 \
  -CA "$SRC/ca.crt" -CAkey "$SRC/ca.key" -CAcreateserial \
  -extfile "$OUT/openssl.cnf" -extensions v3_req \
  -out "$OUT/server.crt" 2>/dev/null
cat "$OUT/server.crt" "$SRC/ca.crt" > "$OUT/fullchain.crt"
cp "$SRC/ca.crt" "$OUT/ca.crt"
chmod 600 "$OUT/server.key"
rm -f "$OUT/server.csr"

echo "issued from the existing CA (which was NOT rotated):"
openssl x509 -in "$OUT/server.crt" -noout -subject -issuer -ext subjectAltName | sed 's/^/  /'
