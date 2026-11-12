# cspell:words xcaddy nutsdb
#
# cache-handler matches run_native.sh; nuts/caddy is the version the unpinned build resolved
# (v0.0.22, which pulls storages/nuts v0.0.21). run_native.sh pins v0.0.23; both need
# NutsDB v1.0.4 and read the Caddyfile's nuts configuration the same way.
# Caddy with the HTTP cache-handler module (Souin) + NutsDB disk storage.
# Stock `caddy:2-alpine` has no disk cache equivalent of nginx's proxy_cache —
# we need that for the CDN mirror (immutable engine artifacts, warmed once per
# revision). Storages are separate modules since Souin 1.7; they must be linked
# at build time.
#
# First build compiles Caddy from source (~1–2 min). Subsequent builds reuse
# the builder layer when the plugin set is unchanged.

FROM caddy:2.11-builder-alpine AS builder

ENV GOTOOLCHAIN=auto

# NutsDB v1.0.4 (what storages/nuts v0.0.21 requires), with one fix: on
# recovery it kept each key as a slice of the buffer holding that key's value,
# so after every restart the whole cache stayed in memory whatever the index
# mode. See nutsdb-v1.0.4-key-copy.patch and selfhost/STATUS.md (CDN section).
# Fetched by commit, not tag, so the source cannot change under the build.
ARG NUTSDB_COMMIT=b346859068f98ef382d83bc4d485fd6fecdc5e86
COPY nutsdb-v1.0.4-key-copy.patch /src/
RUN git init -q /src/nutsdb \
 && git -C /src/nutsdb fetch -q --depth 1 https://github.com/nutsdb/nutsdb "$NUTSDB_COMMIT" \
 && git -C /src/nutsdb checkout -q FETCH_HEAD \
 && git -C /src/nutsdb apply /src/nutsdb-v1.0.4-key-copy.patch

RUN xcaddy build \
    --with github.com/caddyserver/cache-handler@v0.17.0 \
    --with github.com/darkweak/storages/nuts/caddy@v0.0.22 \
    --replace github.com/nutsdb/nutsdb=/src/nutsdb

RUN ./caddy build-info | grep -A1 'github.com/nutsdb/nutsdb' | grep -Eq '^=>[[:space:]]+/src/nutsdb[[:space:]]' \
 || { echo 'the build did not link the patched NutsDB in /src/nutsdb' >&2; exit 1; }

FROM caddy:2.11-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
