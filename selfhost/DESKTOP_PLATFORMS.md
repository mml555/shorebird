# Windows / Linux / macOS on the self-hosted control plane

## TL;DR — the control plane needs no changes for any platform

The server is **platform-agnostic**. `arch` and `platform` are opaque strings
that flow straight through register → storage → device `/patches/check` with no
whitelist and no branching. A grep of `lib/` for
`aarch64|arm64|android|ios|x86_64|xcarchive|libapp|aab|win_archive` returns
**zero hits** — there is no hardcoded platform or arch anywhere in the server
(see the "Server audit" section of `PLATFORM_MATRIX.md`).

Consequently, adding Windows, Linux, or macOS support is **purely a build-host
problem**: you need a machine of that OS to run `shorebird release`/`patch`. The
control plane accepts the artifacts as-is.

### Device-verification status

- **Android** — device-verified (arm64-v8a emulator + a real device) against
  the hardened self-hosted stack.
- **iOS** — device-verified (real iPhone), including signed patches and iOS
  add-to-app framework artifacts.
- **Windows / Linux / macOS** — **not yet exercised end-to-end** against this
  server. The server code paths that handle them (opaque `arch`/`platform`
  pass-through, multi-arch patch readiness) are the *same* paths Android and
  iOS already exercise, so they are expected to work; they are simply untested.
  See `PLATFORM_MATRIX.md` ("We have only exercised android + ios arm64").

> Note: the code paths are generic, but `PLATFORM_MATRIX.md` also lists a small
> set of correctness fixes worth making before running a *multi-platform release
> at a single version* (chiefly: scope the release-finalize "all artifacts
> verified" check by `platform`). Those are server-side robustness items, not
> blockers for a single desktop platform.

---

## Build-host requirement

Flutter/Shorebird desktop builds are **not cross-compilable**. You must build
each desktop target **on that operating system**:

- **Windows** artifacts must be built on **Windows**.
- **Linux** artifacts must be built on **Linux**.
- **macOS** artifacts must be built on **macOS**.

You **cannot** build Windows or Linux releases/patches from macOS (nor Windows
from Linux, etc.). This mirrors `ENGINE_BUILD.md`: "you cannot build the
Windows/Linux engine from macOS." Install the Shorebird CLI on each build host
and point it at your control plane there.

---

## Wiring each build host at the control plane

On every build host, point the CLI at your server before releasing/patching:

```bash
export SHOREBIRD_HOSTED_URL=https://code-push.example.com
export AUTH_SERVICE_URL=https://code-push.example.com
export SHOREBIRD_JWT_ISSUER=https://code-push.example.com
shorebird login          # or use an API key
```

The `base_url` the running app talks to is embedded at **release** time. The
server stamps `PUBLIC_BASE_URL` into every artifact upload/download URL and into
the signed download URLs the device receives from `/patches/check`, so as long
as the release was cut with the CLI pointed at your server, the shipped desktop
app phones home to your control plane — no per-platform server config.

---

## Windows

Build **on Windows**.

```bash
# Release (registers the release + uploads artifacts to your control plane)
shorebird release windows

# Patch an existing release
shorebird patch windows
```

Artifact tags registered / requested (from `PLATFORM_MATRIX.md`):

| Stage | wire `platform` | `arch` value(s) |
|---|---|---|
| Release register | `windows` | `win_archive` (`can_sideload=true`); `windows_supplement` (obfuscated builds only) |
| Patch register | `windows` | `x86_64` |
| Device `/patches/check` | `windows` | `x86_64` |

⚠ The release-side arch (`win_archive`) is **not** the same string as the
patch/device arch (`x86_64`). This is expected: the device asks for the patch
arch `x86_64`, which must match a **patch** artifact row — never the release
`win_archive` tag. The server looks up by `(arch, platform)` exactly, so this
works without special-casing.

---

## Linux

Build **on Linux**.

```bash
shorebird release linux
shorebird patch linux
```

Artifact tags:

| Stage | wire `platform` | `arch` value(s) |
|---|---|---|
| Release register | `linux` | `bundle` (`can_sideload=true`); `linux_supplement` (obfuscated builds only) |
| Patch register | `linux` | `x86_64` |
| Device `/patches/check` | `linux` | `x86_64` |

⚠ Same asymmetry as Windows: release arch (`bundle`) ≠ patch/device arch
(`x86_64`). Handled generically by the server.

---

## macOS

Build **on macOS** (the one desktop target the primary dev host can produce).

```bash
shorebird release macos
shorebird patch macos
```

Artifact tags:

| Stage | wire `platform` | `arch` value(s) |
|---|---|---|
| Release register | `macos` | `app` (`can_sideload=true`, `podfile_lock_hash` set); `macos_supplement` (obfuscated builds only) |
| Patch register | `macos` | **`aarch64` AND `x86_64`** (both, each with `podfile_lock_hash`) |
| Device `/patches/check` | `macos` | `aarch64` (Apple Silicon) or `x86_64` (Intel) |

macOS patches are **multi-arch**: the patcher registers both `aarch64` and
`x86_64`. The server's `_maybeMarkPatchReady` only flips a patch to `ready` once
**all** its artifact rows verify, so a macOS patch correctly stays not-ready
until both arches have uploaded. This is the same all-must-verify path Android's
multi-ABI patches use — no server change needed.

---

## Summary

| Platform | Build host | Release cmd | Patch cmd | Server change |
|---|---|---|---|---|
| Android | any (with Android SDK) | `shorebird release android` | `shorebird patch android` | none (device-verified) |
| iOS | macOS | `shorebird release ios` | `shorebird patch ios` | none (device-verified) |
| macOS | macOS | `shorebird release macos` | `shorebird patch macos` | none (untested) |
| Windows | Windows | `shorebird release windows` | `shorebird patch windows` | none (untested) |
| Linux | Linux | `shorebird release linux` | `shorebird patch linux` | none (untested) |

The only thing you add per platform is a **build host** — never a server code
change.
</content>
