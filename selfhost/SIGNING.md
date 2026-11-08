<!-- cspell:words hoster SBRBPTCH unvalidated -->

# Patch signing in this fork — what verifies, and what does not

> **Is my patch signed? No — not unless you passed `--public-key-path` (or
> `--public-key-cmd`) when you cut the release.** With the default configuration
> a self-hosted Shorebird patch is downloaded, installed and executed with **no
> signature verification at any point**. Nothing on the server participates in
> patch signing; the security boundary is the device.

Verified against the tree on **2026-08-13**. Every file:line below was read, not
inherited — see [`evidence/g7-signing/verification_path.md`](evidence/g7-signing/verification_path.md)
for the working.

## The decision of record

**Option (ii), "loud opt-in": keep the permissive default, and warn when a
release is cut with no public key.** Recorded here as the decision; the warning
itself is **owed, not landed** — see [What is owed](#what-is-owed).

The alternatives, written down before choosing, because a decision without its
rejected options is indistinguishable from a default nobody examined:

| option | cost | why not |
|---|---|---|
| **(i) ship as-is, documented** | zero code | A self-hoster reasonably assumes signing is on — the config key `patch_verification` exists, defaults to `Strict`, and *reads* as protection. Silence is free and leaves a false sense of integrity |
| **(ii) loud opt-in** ✅ | one warning + tests | Chosen. Preserves every working flow, and the assumption above is exactly what a warning corrects |
| **(iii) fail closed** | breaks every existing self-host flow | Refusing to publish an unsigned release breaks this fork's own acceptance scripts, and both its Android and iOS legs are PROVEN *unsigned*. Almost certainly wrong for a fork whose baseline is unsigned operation |

This is a design call and needed no hardware: the classification rule says a gap
dispatches *"we should decide whether we ship that"*, not a device booking.

## Why nothing verifies — the two gates

The headline is right for a reason that is **not** the one this repo recorded
until today. There are exactly two `check_signature` call sites outside
`signing.rs`, and neither runs in a default production install.

### Gate 1 — boot, and only in `Strict`

`vendor/updater/library/src/cache/lifecycle.rs:796-803`:

```rust
if mode == PatchVerificationMode::Strict {
    if let Some(public_key) = public_key {
        let signature = signature.context("Patch signature is missing")?;
        let actual_hash = signing::hash_file(&path)?;
        signing::check_signature(&actual_hash, &signature, public_key)?;   // :800
    } else {
        shorebird_info!("No public key configured; skipping signature verification");
    }
}
```

`Strict` **is** the default — `vendor/updater/library/src/yaml.rs:7-8` marks it
`#[default]`. So the mode is not what disables verification. **The `else` branch
is.** No public key is configured unless `--public-key-path` was passed at release
time, which sets `SHOREBIRD_PUBLIC_KEY` in the build environment, which
`compileShorebirdYaml` copies to `patch_public_key`
(`vendor/flutter/packages/flutter_tools/lib/src/shorebird/shorebird_yaml.dart:71-74`).
Absent that, the updater logs one info line and proceeds.

Reached from `validate_installed_patch` (`lifecycle.rs:771`), itself reached only
from `validate_next_boot_patch` (`:686`) — i.e. **boot**.

### Gate 2 — install time, which does not exist in production

`vendor/updater/library/src/cache/updater_state.rs:363` verifies in `InstallOnly`
mode — and the function containing it is **`#[cfg(test)]`-gated at `:348`**, with
its own doc comment (`:340-347`) saying so:

> Test-only entry point. The production update flow inflates directly into the
> lifecycle's installed location and transitions `Downloaded → Installed` via
> `lifecycle::record_install_complete`, so no production caller goes through this
> function.

The production install path, `lifecycle::record_install_complete`
(`lifecycle.rs:897-922`), copies the stored signature into `PatchState::Installed`
and verifies **nothing**.

**So the "install" in `InstallOnly` is a lie in both directions**: it is not the
default, and it verifies nowhere in production. `packages/shorebird_cli/lib/src/config/shorebird_yaml.dart:11-13`
documents the mode as "Verify the patch signature and hash before installing, but
not when loading from cache" — which no production code does.

> **Do not go looking for this in `packages/code_push_server/lib/src/signing.dart`.**
> That is **URL** signing — `UrlSigner`, `Hmac(sha256, …)` over `"<token>.<exp>"`
> for time-bounded download links. The server's entire patch-signing role is to
> store `hash_signature` verbatim and echo it back; it carries no RSA library at
> all.

## Turning it on

Four flags, declared at `packages/shorebird_cli/lib/src/common_arguments.dart:106`
(`--public-key-path`), `:115` (`--private-key-path`), `:124` (`--public-key-cmd`)
and `:134` (`--sign-cmd`), validated by `assertAbsentOrValidKeyPairOrCommands()`
(`packages/shorebird_cli/lib/src/extensions/arg_results.dart:142`, rules
documented `:129-141`):

| configuration | valid |
|---|---|
| nothing provided | ✅ no signing — **the default** |
| `--public-key-path` + `--private-key-path` | ✅ file-based |
| `--public-key-cmd` + `--sign-cmd` | ✅ command-based (this is where a KMS or HSM goes) |
| `--public-key-path` + `--sign-cmd` | ✅ mixed |
| both `--public-key-path` and `--public-key-cmd` | ❌ ambiguous public key |
| both `--private-key-path` and `--sign-cmd` | ❌ ambiguous signing method |
| `--sign-cmd` with no public key source | ❌ |
| `--private-key-path` without `--public-key-path` | ❌ |

The public key must be supplied **at release time**, not patch time: it is baked
into the shipped `shorebird.yaml` and is what the device has at boot.

### The algorithm is fixed

`packages/shorebird_cli/lib/src/code_signer.dart:45` — `Signer('SHA-256/RSA')`,
hardcoded. There is no negotiation and no algorithm field on the wire. This is
what makes "KMS-backed signing" an aspiration folded into `--sign-cmd` rather
than a mechanism: your KMS may hold the key, but it must produce a SHA-256/RSA
signature.

What is signed is a **hash string**, not the container:
`vendor/updater/library/src/cache/signing.rs:37` is
`check_signature(message: &str, signature: &str, public_key: &str)`. So the patch
container's shape — `SBRBPTCH` or otherwise — is structurally irrelevant to
signing.

## Key rotation — the manual procedure

There is **no rotation mechanism**, and none is invented here. What exists:

1. Generate a new RSA keypair.
2. **Cut a new release** with `--public-key-path` pointing at the new public key.
   The key is compiled into that release's `shorebird.yaml`; it cannot be changed
   for releases already shipped.
3. Sign all subsequent patches for that release with the matching private key.
4. **Patches signed with the old key are unverifiable under the new release**, and
   patches for *older* releases must keep using the old key for as long as those
   releases are live.

The consequence worth stating plainly: **a compromised private key cannot be
revoked.** Every already-shipped release continues to trust its baked-in public
key until users move to a release built with a new one. Rotation is a re-release,
not a revocation.

## What is owed

* **The warning that makes option (ii) real.** Not landed. It belongs beside the
  existing one at
  `packages/shorebird_cli/lib/src/commands/release/release_command.dart:423-431`,
  which already warns in the *opposite* direction — when `patch_verification` is
  set in `shorebird.yaml` and no public key was provided. The new case is the
  common one: no public key provided at all. One `logger.warn` plus a test.
* **A test crossing the Dart↔Rust key-encoding seam.** `CodeSigner.verify` takes a
  **PEM** (`code_signer.dart:150-153`) while the updater's `ring` verifier consumes
  the **base64 DER** that `base64PublicKey` produces (`:56-58`). Nothing anywhere
  asserts that a Dart-produced signature verifies under the encoding the Rust side
  is actually handed. `--sign-cmd` remains unvalidated for the same reason.
* **On-device tamper rejection.** Only meaningful in `Strict` with a public key
  present, and only observable at next boot. Needs hardware; not in this lane.

## What already existed before this document

`packages/shorebird_cli/test/src/code_signer_test.dart` — **15 tests, all
passing** — predates this work entirely and is credited to nobody here. It covers
signing with PKCS#8 (`:47`) and PKCS#1 (`:72`) keys, that the two agree (`:97`),
`base64PublicKey` against openssl (`:113`), `base64PublicKeyFromPem` (`:137`), the
round trip `sign` → `verify` true (`:150`) / false for a bad signature (`:167`) /
false for a wrong message (`:180`), and the command-based paths `runPublicKeyCmd`
(`:213`) and `signWithCmd` (`:310`).

Two limits on reading that as coverage: the openssl-comparing group is
`onPlatform`-`Skip`ped on Windows (`:198-199`), so it is not a cross-platform
gate; and every one of those tests lives on one side of the encoding seam above.

**Run it from the package directory, not the repo root:**

```bash
cd packages/shorebird_cli && dart test test/src/code_signer_test.dart   # 15/15
```

From the repo root, 8 of the 15 fail with
`PathNotFoundException: test/fixtures/crypto/private.pem` — the fixtures are read
through CWD-relative paths. That is an invocation artifact, not a defect, and it
is worth knowing before someone reports the signing suite as broken.
