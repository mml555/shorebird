# R12 builder substrate — GENERIC ONLY.
#
# What this image may contain, and nothing else: a pinned Linux base, a JDK, the
# Android SDK, and basic utilities. It deliberately contains NO Flutter, NO Dart
# and NO Shorebird CLI.
#
# WHY THAT BOUNDARY IS LOAD-BEARING. If the toolchain were baked in, a green run
# would prove that a preassembled image works — not that a clean Linux CI builder
# can reproduce the supported environment from owned bytes. The toolchain is
# therefore bootstrapped AFTER the container starts, by run_arm.sh, from our own
# pinned mirror and our own CDN.
#
# Built and run as linux/amd64. On Apple Silicon that is emulated; recorded as a
# scope fact in PREFLIGHT.md, not a defect.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless \
      git curl unzip zip xz-utils ca-certificates file procps coreutils \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk

# Pinned cmdline-tools build, not "latest", so the substrate is reproducible.
ARG CMDLINE_TOOLS_ZIP=commandlinetools-linux-13114758_latest.zip
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
       "https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}" \
    && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip

ENV PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# Levels read out of the PINNED Flutter revision's FlutterExtension.kt
# (a4a3c0d1…): compileSdk/targetSdk 36, minSdk 24, ndk 28.2.13676358.
RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true
# cmake and ninja are here because the first release build auto-installed
# CMake 3.22.1 from dl.google.com MID-ARM. An arm that reaches out for SDK
# components while running is fetching part of its own environment from the
# network at measurement time; the substrate is where that belongs.
RUN sdkmanager --install \
      "platform-tools" \
      "platforms;android-36" \
      "build-tools;36.0.0" \
      "ndk;28.2.13676358" \
      "cmake;3.22.1" >/dev/null
# socat forwards the container's own localhost:18081 to the host's control
# plane. The server is configured PUBLIC_BASE_URL=http://localhost:18081 and
# hands that ABSOLUTE url back for artifact uploads (api.dart:2829), so inside a
# container the CLI dials its own loopback and is refused. Forwarding is
# preferable to repointing PUBLIC_BASE_URL, which is shared infrastructure the
# iOS lane also uses -- and it makes the arm's view of the control plane
# IDENTICAL to the historical host-local endpoint rather than merely equivalent.
RUN apt-get update && apt-get install -y --no-install-recommends ninja-build socat \
    && rm -rf /var/lib/apt/lists/*

# Proof the substrate carries none of the toolchain under test. A cached Flutter
# or Shorebird here would silently turn the decisive arm into a no-op.
RUN ! command -v flutter && ! command -v dart && ! command -v shorebird \
    && [ ! -d /root/.shorebird ] && [ ! -d /root/.pub-cache ] \
    && echo "substrate clean: no flutter/dart/shorebird, no caches"

CMD ["/bin/bash"]
