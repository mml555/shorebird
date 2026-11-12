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
#
# The CA is also constrained to these host names (nameConstraints below), so
# that a CA key that leaks, or a ca.crt that gets trusted by mistake, can only
# vouch for the mirror's own names and not for any site. The two lists are built
# together so they cannot disagree.
#
# DNS names only. Dart on Linux (BoringSSL's verifier, Dart 3.13.7) fails the
# handshake for a CA with ANY IP name constraint, permitted or excluded:
#   CERTIFICATE_VERIFY_FAILED: unsupported name constraint type
# while Dart on macOS, curl and openssl accept it. Without an IP constraint the
# IP SANs still verify, and a leaked key could vouch for IP-literal HTTPS hosts,
# but not for any domain name. With no host name at all, the CA is limited to
# the reserved name `invalid` (RFC 2606), so it vouches for no real domain.
san=""
nc=""
dns_i=0
ip_i=0
probes=()   # one "<kind> <name to verify>" per SAN entry
add_host() {
  local h="$1"
  [[ "$san" == *"= $h"$'\n'* ]] && return 0
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip_i=$((ip_i + 1)); san+="IP.$ip_i = $h"$'\n'
    probes+=("ip $h")
  elif [[ "$h" == *:* ]]; then
    # IPv6 literal. A mask the same width as the address, so only that host.
    [[ "$h" =~ ^[0-9a-fA-F:]+$ ]] || { echo "ERROR: not an IPv6 address: $h" >&2; exit 2; }
    ip_i=$((ip_i + 1)); san+="IP.$ip_i = $h"$'\n'
    probes+=("ip $h")
  elif [[ "$h" == \*.* ]]; then
    # Wildcard cert name; the constraint is its base domain, which permits the
    # domain and everything below it.
    base="${h#\*.}"
    [[ "$base" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "ERROR: bad wildcard host: $h" >&2; exit 2; }
    # TLS clients refuse a wildcard directly under a single label (*.lan), so
    # the cert would never verify; say so now instead of after minting it.
    [[ "$base" == *.* ]] || { echo "ERROR: $h would not be accepted by TLS clients; use a name with two or more labels, e.g. *.mirror.lan" >&2; exit 2; }
    dns_i=$((dns_i + 1)); san+="DNS.$dns_i = $h"$'\n'
    nc+=", permitted;DNS:$base"; probes+=("dns probe.$base")
  else
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "ERROR: bad host name: $h" >&2; exit 2; }
    dns_i=$((dns_i + 1)); san+="DNS.$dns_i = $h"$'\n'
    nc+=", permitted;DNS:$h"; probes+=("dns $h")
  fi
}
for h in "${hosts[@]}"; do add_host "$h"; done
[[ -n "$nc" ]] || nc=", permitted;DNS:invalid"
# 127.0.0.1 is always useful: the build host reaches the mirror over loopback.
add_host 127.0.0.1
# ::1 is only in the SAN when asked for: clients that resolve localhost to ::1
# still validate against the DNS name.

# Everything is written to a scratch dir and moved into place at the end, so a
# failure (bad host, failed verification) leaves no half-written certs behind.
WORK="$(mktemp -d "$DIR/.generate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[dn]
CN = selfhost-cdn-mirror local CA

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, keyCertSign, cRLSign
nameConstraints  = critical$nc

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
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
  -config "$WORK/openssl.cnf" -extensions v3_ca 2>/dev/null

echo "==> server key + CSR"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$WORK/server.key" -out "$WORK/server.csr" \
  -config "$WORK/openssl.cnf" -section server_req 2>/dev/null

echo "==> signing server cert (${DAYS} days)"
openssl x509 -req -in "$WORK/server.csr" -sha256 -days "$DAYS" \
  -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
  -out "$WORK/server.crt" \
  -extfile "$WORK/openssl.cnf" -extensions server_ext 2>/dev/null

# Caddy wants the chain in one file, leaf first.
cat "$WORK/server.crt" "$WORK/ca.crt" > "$WORK/fullchain.crt"
chmod 600 "$WORK/ca.key" "$WORK/server.key"
rm -f "$WORK/server.csr" "$WORK/.srl" "$WORK/ca.srl"

echo
echo "==> CA name constraints:"
openssl x509 -in "$WORK/ca.crt" -noout -text \
  | sed -n '/Name Constraints/,/Signature Algorithm/{/Signature Algorithm/!p;}' | sed 's/^ */      /'
echo
echo "==> chain verifies for every SAN (one openssl verify each):"
for p in "${probes[@]}"; do
  kind="${p%% *}"; name="${p#* }"
  flag=-verify_hostname; [[ "$kind" == ip ]] && flag=-verify_ip
  openssl verify -CAfile "$WORK/ca.crt" "$flag" "$name" "$WORK/server.crt" >/dev/null \
    || { echo "ERROR: server.crt does not verify for $name" >&2; exit 1; }
  echo "      ok  $name"
done
# A name that is not in the SAN must NOT verify.
if openssl verify -CAfile "$WORK/ca.crt" -verify_hostname not-in-the-san.invalid "$WORK/server.crt" >/dev/null 2>&1; then
  echo "ERROR: server.crt verifies for a host that is not in the SAN" >&2; exit 1
fi
echo "      ok  not-in-the-san.invalid is refused"
# The constraint itself must hold: a leaf for a domain outside it, signed with
# this CA's own key, must NOT verify.
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/probe.key" -out "$WORK/probe.csr" \
  -subj /CN=example.com 2>/dev/null
printf 'subjectAltName = DNS:example.com\n' > "$WORK/probe.ext"
openssl x509 -req -in "$WORK/probe.csr" -days 1 -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -extfile "$WORK/probe.ext" -out "$WORK/probe.crt" 2>/dev/null
if openssl verify -CAfile "$WORK/ca.crt" -verify_hostname example.com "$WORK/probe.crt" >/dev/null 2>&1; then
  echo "ERROR: the CA's name constraint does not hold: it vouches for example.com" >&2; exit 1
fi
echo "      ok  a cert for example.com from this CA is refused (name constraint)"
echo
# Verified; move into place (each is a rename within $DIR).
for f in openssl.cnf ca.key ca.crt server.key server.crt fullchain.crt; do
  mv -f "$WORK/$f" "$DIR/$f"
done
echo "==> wrote:"
echo "      $DIR/ca.crt         <- the CA to trust (see trust.sh)"
echo "      $DIR/fullchain.crt  <- served by Caddy"
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
