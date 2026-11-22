<!-- cspell:words tombstones tombstoned rsassa -->

# Patch signing: what verifies on the device, and what does not

> **A self-hosted release is unsigned unless you pass your own public key.**
> Without a key, the device accepts any patch the server serves it. Anyone who can
> publish a patch to your server, or answer the device's update check in its
> place, can run code in your app. The server does not make up for this.

This describes the code in this repository. Nothing here was tested on a device;
the [Evidence](#evidence) section at the end says what was checked and how.

## What to do today for production

1. **Cut every release with your own key.** Pass `--public-key-path` and
   `--private-key-path` (or `--public-key-cmd` and `--sign-cmd` for a KMS or HSM)
   to `shorebird release`, and the same key to every `shorebird patch` for that
   release. See [Turning it on](#turning-it-on).
2. **Set `patch_verification: strict`** in the checked-in `shorebird.yaml`
   before you cut the release. Strict re-checks the signature on every boot. The
   default does not (see [When the device verifies](#when-the-device-verifies)).
   Strict does nothing without a key: signature checks need a `patch_public_key`
   in the app.
3. **Back up the private key**, encrypted, somewhere other than the machine that
   signs, with access limited to the few people who may sign. Where you can, keep
   the key in a KMS or HSM and sign with `--sign-cmd`, so no copyable key file
   exists. If you lose the key you cannot patch the releases built with it (see
   [Keys: backup and rotation](#keys-backup-and-rotation)).
4. Do not ignore the warning the CLI prints when no key is given.

## The three signing modes

Each release artifact records one mode, which the CLI reports in the `signing`
field of the upload (parsed by `_parseSigning` in
`packages/code_push_server/lib/src/api.dart`).

| mode | who holds the key | who signs a patch | what the server does |
|---|---|---|---|
| **customer** | you | the `shorebird patch` CLI, with your private key or `--sign-cmd` | requires a `hash_signature` and stores it as sent. It never sees your public key, so it cannot check the signature (`_patchHashSignature`) |
| **managed** | the server: one RSA-2048 key per organization, created on the first `GET /apps/{id}/signing-key` | the server, when the patch artifact is registered | signs the hash the client names; refuses a client-supplied signature |
| **unsigned** (or not reported) | nobody | nobody | stores whatever `hash_signature` the client sent, possibly none |

### Which mode the self-hosted CLI picks

`Releaser.resolvePatchSigningKey` in
`packages/shorebird_cli/lib/src/commands/release/releaser.dart` decides:

1. A key passed with `--public-key-path` or `--public-key-cmd`: **customer**.
2. Otherwise, if `--no-patch-signing` was passed, **or**
   `shorebirdEnv.hostedEnvironment == null`: **unsigned**, with no key embedded.
3. Otherwise **managed**: it fetches the server's key and embeds it.

`hostedEnvironment` (in `shorebird_env.dart`) is null for a server named by
`base_url` in `shorebird.yaml` or by `SHOREBIRD_HOSTED_URL` whose host is not one
of Shorebird's own. (With neither set the CLI talks to Shorebird's production
server, not yours, and does pick managed. A server of yours reached under
Shorebird's host name, through a proxy or DNS override, or with `--dev`, counts as
Shorebird's.) So **on a self-hosted server the CLI never picks managed**, and a
release is unsigned unless you pass a customer key. `assertArgsAreValid` in `release_command.dart` prints a warning in that case
and carries on.

The consequence: the server's managed-signing code (`PatchSigner` in
`patch_signing.dart`, the `signing_keys` table, and the `PATCH_SIGNING_KEY_SECRET`
that production requires) is not reached by the supported CLI. An operator who
sets that secret and believes patches are server-signed is wrong today. A direct
API client can still register a `managed` release, and the server's tests
(`test/managed_signing_test.dart`) cover that path.

## What is signed, and what the device checks

- **The signed message** is the lowercase hex SHA-256 string of the file the
  device ends up holding, as UTF-8 bytes. The scheme is RSASSA-PKCS1-v1_5 with
  SHA-256, and the signature is base64. Code: `CodeSigner` in
  `packages/shorebird_cli/lib/src/code_signer.dart` (`Signer('SHA-256/RSA')`,
  fixed, no negotiation); `PatchSigner.signHash` on the server; on the device
  `check_signature` in `vendor/updater/library/src/cache/signing.rs`.
- For an Android code patch that file is the full new `libapp.so`, not the diff
  (`createDiffBundle` in `patcher.dart` hashes the patch artifact, then diffs it).
  The signature does **not** cover the diff, the download URL, the patch number,
  the release or the CPU architecture. It reaches the installed bytes because the
  updater inflates the diff against the base on the device and then checks that
  the result hashes to the signed string (`check_hash` in `updater.rs`).
- For an iOS Route B patch the hashed file is the container (`ios_patcher.dart`).
  The updater path is the same, so the same signature covers it. This file does
  not describe how the Route B artifact is built; that is not a signing matter.
- An assets-only patch is signed over the sha256 of the zip
  (`patch_command.dart`); the updater hashes the downloaded archive for that kind.
- A symbols sidecar is never signed, and devices never download it.
- **The key** the device checks against is `patch_public_key` in the generated
  (bundled) `shorebird.yaml`: the base64 DER `RSAPublicKey`. The CLI hands it to
  the build as `SHOREBIRD_PUBLIC_KEY` (`artifact_builder.dart`), and the Flutter
  fork's build writes it, and `patch_verification` from the checked-in
  `shorebird.yaml`, into the bundled file. The key is fixed for every copy of that
  release already installed.

## When the device verifies

All of it is in `vendor/updater/library/src`.

| when | what happens | mode |
|---|---|---|
| **Download time** | `download_and_install_patch` (`updater.rs`) calls `check_patch_signature` on the server's `hash` and `hash_signature` before any network fetch. A refusal tombstones that exact (hash, signature) pair, so a forged offer cannot block the genuine patch with the same number | every mode |
| **Install** | `record_install_complete` (`cache/lifecycle.rs`) copies the stored signature and does not verify again | every mode |
| **Boot** | `validate_installed_patch` (`cache/lifecycle.rs`) re-hashes the installed file and re-verifies the signature. A failure marks the patch bad and boots the previous patch or the base. In every mode it also checks that the installed file's size is what was recorded | signature re-check only under `patch_verification: strict`, and only with a public key |

The default is **`install_only`**: `PatchVerificationMode` in `yaml.rs` marks
`InstallOnly` as `#[default]`, and `config.rs` applies `unwrap_or_default()` when
the key is absent. So a release that has a key but no `patch_verification: strict`
is verified at download time and **not** at boot. That covers a network attacker
offering a forged patch. It does not catch a patch file altered on the device
after it was installed. Strict does.

`tool/check_updater_pin.sh`, run in CI, fails if the vendored updater's default,
its download-time call site, or the pinned revision drift from this description.
It checks the vendored copy and the pin in `compatibility.yaml`. It cannot read the
engine's own dependency list, which is not in this repository; see
[Evidence](#evidence).

### What follows from no key

The download-time check verifies a signature **only when the release embeds a
`patch_public_key`**. `check_patch_signature` in `cache/signing.rs` returns success
when no public key is configured, so in that case it checks nothing, in every mode,
and `strict` adds nothing either. The only check
left is that the inflated file matches the hash the server named, and the server
names that hash. So **with no key, the device accepts any patch the server
serves.** With a key, a patch that has no signature, or a wrong one, is refused.

### What the CLI does with `install_only`

- On a self-hosted server, `shorebird release` **refuses** an explicit
  `patch_verification: install_only` in `shorebird.yaml` and exits
  (`assertArgsAreValid` in `release_command.dart`). That refusal depends only on
  the server being self-hosted, not on the engine. Its message says install-time
  signature verification is not implemented, which is not true of the updater this
  repository vendors: it verifies at download time in every mode. So the refusal
  is real but its stated reason is wrong, and `strict` is accepted.
- The refusal gives no protection against the default. If you leave
  `patch_verification` out, the updater uses `install_only` anyway. Setting
  `strict` is the only way to get boot-time checking.
- A second, separate check (`patch_verification.dart`, used at release and patch
  time) warns about or rejects `install_only` for a closed list of engine
  revisions whose updater skipped the signature check (updater#352, since fixed).
  Our pinned engines (`d0714887`, `2c4b0718`) are not on that list, so this check
  does not fire for them.

## The server's role

The server does not decide whether a patch is trustworthy.

- **Customer mode:** it stores `hash_signature` as sent and serves it back from
  `/patches/check`. It cannot verify it. A bad signature is accepted, promoted and
  served, and every device then refuses it.
- **Managed mode:** it signs whatever `hash` the registration names. It does not
  check that hash against the uploaded bytes: patch artifacts are verified for
  size only, and the hash check (`checkHash`) applies to release artifacts. A
  valid API token is therefore enough to get a validly signed patch.
- **Unsigned:** it serves the patch with no signature, and a device whose release
  embedded no key accepts it.
- Do not confuse patch signing with `UrlSigner` in `signing.dart`. That is an
  HMAC over download links that expire.

Hardening that would change this (a server-side signature check, a required
signature for flagged apps, signing at promote time) is planned, not landed.

## Turning it on

Four flags are declared in `packages/shorebird_cli/lib/src/common_arguments.dart`
(`--public-key-path`, `--private-key-path`, `--public-key-cmd`, `--sign-cmd`) and
checked by `assertAbsentOrValidKeyPairOrCommands()` in
`extensions/arg_results.dart`:

| configuration | valid |
|---|---|
| nothing provided | yes; on a self-hosted server that means unsigned |
| `--public-key-path` + `--private-key-path` | yes, file-based |
| `--public-key-cmd` + `--sign-cmd` | yes, command-based (a KMS or HSM goes here) |
| `--public-key-path` + `--sign-cmd` | yes, mixed |
| both `--public-key-path` and `--public-key-cmd` | no, ambiguous public key |
| both `--private-key-path` and `--sign-cmd` | no, ambiguous signing method |
| `--sign-cmd` with no public key source | no |
| `--private-key-path` without `--public-key-path` | no |

Give the public key **at release time**: it is built into the shipped app. At
patch time give the key pair again. For a customer release the CLI refuses a patch
without both halves (`_assertCanSignForRelease` in `patch_command.dart`), and it
verifies the signature against the key you pass before uploading
(`Patcher.signHash`). It does **not** compare that key with the one the release
embedded. A patch signed with a different key than the release's is accepted,
promoted and served, and every device refuses it. Use the same key files, and
try a patch on a test device before rolling it out.

`--no-patch-signing` builds an unsigned release and cannot be combined with a key.

## Keys: backup and rotation

**Your own (customer) key.**

- Nothing in this repository stores or backs it up. Generate it, keep an
  **encrypted** copy off the signing machine, and limit who can read it: whoever
  holds it can sign code for every installed copy of the app. Prefer a KMS or HSM
  with `--sign-cmd` where you have one.
- There is **no rotation and no revocation**. To change the key, cut a **new
  release** with the new public key. Releases already installed keep trusting the
  old key, and patches for them must keep using it for as long as those releases
  are live. A leaked private key cannot be revoked for releases already shipped.
- A lost private key means you can no longer patch the releases built with it.
  This cost a rebuild of one iOS test release
  ([`UPSTREAM_PARITY.md`](UPSTREAM_PARITY.md), "iOS release (ipa) on a device").

**The server's managed key, and `PATCH_SIGNING_KEY_SECRET`.**

- Managed private keys are stored encrypted (JWE `dir` + `A256GCM`) under a key
  derived from `PATCH_SIGNING_KEY_SECRET` (`patch_signing.dart`). Production
  requires the secret to be at least 32 characters and different from
  `URL_SIGNING_SECRET` and `API_KEY` (`config.dart`).
- **Back it up, and never change it.** If it is lost or changed, the stored keys
  cannot be decrypted and the server refuses to start, naming the variable
  (`checkPatchSigningKeys` in `api.dart`). Shipped apps embed the matching public
  keys, so the releases built with those keys can never get another signed patch.
  See [`backup_restore/SECRETS_BOUNDARY.md`](backup_restore/SECRETS_BOUNDARY.md),
  which also says to keep `.env` in a separate, encrypted backup.
- There is no tool to re-wrap the keys under a new secret, and no key revocation.
  The JWE `kid` header exists for a future tool; only `v1` is implemented.
- A database dump together with the secret is enough to sign for every app in the
  organization. Keep them in separate backups.
- Because the supported CLI does not use managed mode today, a normal
  self-hosted release does not depend on this secret. Production still requires it.

## Tests and checks

- Dart signer against the production Rust verifier:
  `packages/shorebird_cli/test/src/code_signer_rust_seam_test.dart`. It does not
  cover `--sign-cmd` output.
- `packages/shorebird_cli/test/src/code_signer_test.dart` covers signing with
  PKCS#8 and PKCS#1 keys, `base64PublicKey`, a sign and verify round trip, and the
  command-based paths. Its fixtures are read by relative path, so run it from
  `packages/shorebird_cli`.
- `tool/check_updater_pin.sh` (run in CI) fails when the vendored updater's
  default verification mode, its download-time signature check, or its revision
  differs from what these documents state.
- On-device tamper rejection under Strict is **not tested** here. It needs a
  device and shows only at the next boot.
- [`evidence/g7-signing/`](evidence/g7-signing/verification_path.md) was written
  for the older updater and is **historical**: its line numbers and its "no
  install-time check" finding no longer hold.

## Evidence

How the statements above were established, for whoever maintains this file.

- Read against `fork/main` at `03a9b405d` on 2026-11-16. Before that date this
  file described an older updater (strict as the default, no install-time check);
  the vendored updater had been replaced and the text had not. `UPDATER_CONTRACT.md`
  was corrected in the same change.
- The engine side was checked by hand on 2026-11-16 against an engine checkout at
  `d0714887`: its `DEPS` `updater_rev` is `87c198d30f875a3da317d70935e1025dc13064dd`;
  that updater's `yaml.rs` defaults to `InstallOnly` and its `download_and_install_patch`
  calls `check_patch_signature`; the Flutter fork's `compileShorebirdYaml` copies
  `patch_verification` and sets `patch_public_key`; `flutter_command.dart` reads
  `SHOREBIRD_PUBLIC_KEY`. Hosted CI cannot repeat this, because that checkout is not
  in this repository. The engine-side guard is `selfhost/ci/engine_updater_evidence_guard.sh`
  (#206), run on a host that has the engine tree.
- `tool/check_updater_pin.sh` repeats the vendored half in CI.
- The Dart signer is verified by the production Rust verifier in
  `code_signer_rust_seam_test.dart` (commit `0b80cdb73`).
- Not established from this repository: the key sizes the engine's verifier
  accepts, and on-device behaviour.
- On the Flutter 3.50 engine (`e737ede3`, 2026-11-22) the updater is `a58774ab8a88a04ae5f96ce4e5a9825561a2f2f3` (`DEPS` `updater_rev` at `52347b61`); its `yaml.rs` still defaults `patch_verification` to `install_only` (`library/src/yaml.rs:8-14`). Not re-read here beyond that default; the 2026-11-16 reading above is about `d0714887`.
