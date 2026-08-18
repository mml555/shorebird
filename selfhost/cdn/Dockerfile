# cspell:words xcaddy nutsdb
#
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

RUN xcaddy build \
    --with github.com/caddyserver/cache-handler \
    --with github.com/darkweak/storages/nuts/caddy

FROM caddy:2.11-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
