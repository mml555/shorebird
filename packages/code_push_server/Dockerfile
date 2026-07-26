# syntax=docker/dockerfile:1
#
# Multi-stage build for the self-hosted code_push_server control plane.
#
#   Stage 1 (build): compile bin/server.dart to a self-contained native
#                    executable using the official Dart SDK image.
#   Stage 2 (run):   copy the executable + the Dart runtime shared libraries
#                    onto a minimal Debian base and run as a non-root user.
#
# Both the Postgres client (package:postgres) and the MinIO/S3 client
# (package:minio) are pure Dart, so no extra native libraries are needed
# beyond the small runtime the `dart compile exe` output links against
# (libc, and Dart's bundled runtime shipped from /runtime/).
#
# Build:  docker build -t code-push-server:latest .
# Run:    docker run --rm -p 8080:8080 --env-file .env code-push-server:latest

############################
# Stage 1 — build
############################
FROM dart:stable AS build

WORKDIR /app

# Resolve dependencies first so this layer is cached unless the manifest
# changes. This package is standalone (its own pubspec.lock, not a workspace
# member), so `--enforce-lockfile` gives reproducible builds.
COPY pubspec.* ./
RUN dart pub get --enforce-lockfile

# Copy the rest of the source and compile the entrypoint to a native exe.
COPY . .
RUN dart pub get --offline --enforce-lockfile \
    && dart compile exe bin/server.dart -o bin/server

############################
# Stage 2 — runtime
############################
FROM debian:bookworm-slim AS runtime

# `curl`: container HEALTHCHECK probes /healthz. `ca-certificates`: HTTPS S3.
# `libsqlite3-0`: the default (single-container) backend uses SQLite via FFI —
# symlink the versioned lib to the bare name the sqlite3 package dlopen()s
# (arch-agnostic: works on amd64 and arm64 images).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libsqlite3-0 \
    && SO="$(find / -name 'libsqlite3.so.0' 2>/dev/null | head -1)" \
    && ln -sf "$SO" "$(dirname "$SO")/libsqlite3.so" \
    && rm -rf /var/lib/apt/lists/*

# `dart compile exe` produces a self-contained AOT executable that links against
# the system C library. `dart:stable` is Debian-based, so its glibc is ABI-
# compatible with `debian:bookworm-slim` here and no Dart runtime copy is needed
# (the `/runtime/` copy is only for a `scratch` base, whose /lib would collide
# with Debian's /lib symlink).
COPY --from=build /app/bin/server /app/bin/server

# Run as a non-root, unprivileged user. Create /data (owned by appuser) as root
# BEFORE dropping privileges — it's the single-container persistence directory
# (SQLite db + filesystem artifacts), the one thing to back up.
RUN useradd --system --uid 10001 --user-group --home-dir /app --shell /usr/sbin/nologin appuser \
    && mkdir -p /data \
    && chown -R appuser:appuser /app /data
USER appuser

WORKDIR /app

ENV PORT=8080
ENV DATA_DIR=/data
VOLUME /data

# The server binds InternetAddress.anyIPv4 on $PORT (default 8080).
EXPOSE 8080

# Probe the liveness endpoint. Uses the in-container PORT.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1

ENTRYPOINT ["/app/bin/server"]
