<!-- cspell:words unvalidated precommitted -->

# G7 — the verification path, read rather than assumed

**Identity.** Re-derived 2026-08-13 17:08-17:12 EDT against the tree at the commit
this file lands in. `code_push_server` 1.3.0; Dart SDK 3.12.2 stable; CLI version
`1.6.115+selfhost.1`. **No cell address or engine hash appears here on purpose** —
nothing in this lane is inside cell `4df8f9b6`, and writing one in would falsely
couple `G7` to that mint. No device, no run, no release: this is a
source-determined classification, which is what the classification rule dispatches
for a KNOWN GAP.

## The retraction

`PARITY.md` recorded, until this commit:

> **KNOWN GAP** The default `patch_verification: install_only` performs **no
> signature verification anywhere on the production path**

**The headline survives. The mechanism sentence is false**, and it is false in the
first clause: `install_only` is **not** the default.

`vendor/updater/library/src/yaml.rs:1-12`:

```rust
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PatchVerificationMode {
    #[default]
    Strict,        // :7-8
    InstallOnly,
}
```

A reader who checked the cited mechanism would find `Strict`, conclude the row was
wrong, and have no way to tell that the *conclusion* was right. That is why the
old text is kept visible as a retraction rather than edited away.

## Both call sites, because showing one invites disbelief

`grep -rn "check_signature" vendor/updater/library/src` outside `signing.rs`
returns exactly two live call sites (plus two comments):

| site | mode | reached from | runs in production? |
|---|---|---|---|
| `cache/lifecycle.rs:800` | `Strict` only (`:796`) | `validate_installed_patch` `:771` ← `validate_next_boot_patch` `:686` — **boot** | **only if a public key exists** |
| `cache/updater_state.rs:363` | `InstallOnly` only | `install_patch`, **`#[cfg(test)]`-gated at `:348`** | **no** |

> **Citation corrected:** the order cites `updater_state.rs:330-332/347/363` at
> `vendor/updater/library/src/updater_state.rs`. The file is at
> **`vendor/updater/library/src/cache/updater_state.rs`**, and the `#[cfg(test)]`
> attribute is at **`:348`**, not `:347` (`:347` is the last line of the doc
> comment). The line the verification happens on, `:363`, is correct.

### Gate 1 fails open, by design and in one line

`lifecycle.rs:796-803` — the `if let Some(public_key)` has an `else` that logs
`"No public key configured; skipping signature verification"` and returns `Ok`.
The public key arrives only via `--public-key-path`/`--public-key-cmd` at release
time → `SHOREBIRD_PUBLIC_KEY` → `compileShorebirdYaml` →
`compiled['patch_public_key']`
(`vendor/flutter/packages/flutter_tools/lib/src/shorebird/shorebird_yaml.dart:71-74`).

### Gate 2 does not exist in production

`cache/updater_state.rs:340-347`, the function's own doc comment:

> Test-only entry point. … no production caller goes through this function. Gated
> to `#[cfg(test)]` so a future refactor can't accidentally reintroduce the
> divergence.

The production path is `lifecycle::record_install_complete` (`lifecycle.rs:897-922`),
read in full: it matches `PatchState::Downloaded { signature, .. }`, writes
`PatchState::Installed { signature, size }`, and deletes the compressed download.
**No verification of any kind appears in it.**

## The server does not participate

`packages/code_push_server/lib/src/signing.dart:8` is `class UrlSigner`, `:14` is
`Hmac(sha256, utf8.encode(_secret))` over `"<token>.<exp>"` — time-bounded
download URLs, not patch signatures. Confirmed by reading; §7 already records that
the package carries no RSA library.

## The pre-existing test suite, credited to nobody here

`packages/shorebird_cli/test/src/code_signer_test.dart` — **15 tests**, every one
of them older than this lane. Run from the package directory: **15/15 pass**.

All ten line anchors the order cites were re-read and are **correct**: `:47`,
`:72`, `:97`, `:113`, `:137`, `:150`, `:167`, `:180`, `:213`, `:310`.

> **Two corrections to the order:**
> 1. Its "Do not" section says the file has **"20-plus tests"**. It has **15**
>    (`grep -c "^\s*test("` = 15, and the runner reports `+15`). The point the
>    section makes — that crediting an existing test to a new goal is the same
>    error as crediting a host probe with PROVEN — is unaffected and stands.
> 2. Precondition 7 says `dart test packages/shorebird_cli` is green. **It is
>    not**, for two independent reasons, neither of which is a defect:
>    * from the repo root, **8 of the 15** signing tests fail with
>      `PathNotFoundException: Cannot open file, path = 'test/fixtures/crypto/private.pem'`
>      — the fixtures are read CWD-relative, so the suite must be run from
>      `packages/shorebird_cli`;
>    * `integration_test/shorebird_cli_integration_test.dart` fails to **load**
>      with `SHOREBIRD_HOSTED_URL environment variable is not set`.
>
>    Both are invocation/environment facts. Recorded because "the signing suite is
>    broken" is exactly what the first one looks like at a terminal.

## The seam nothing tests

`CodeSigner.verify` takes a **PEM** (`code_signer.dart:150-153`). The updater's
`ring` verifier is handed the **base64 DER** produced by `base64PublicKey`
(`:56-58`, which delegates to `base64PublicKeyFromPem`). Every one of the 15 tests
sits on the Dart side of that boundary: the round trip at `:150` signs and
verifies with the *same* Dart code and the *same* PEM.

So **nothing asserts that a Dart-produced signature verifies under the encoding
the Rust side actually consumes.** That, plus the still-unvalidated `--sign-cmd`
row, is what a new test would be for — cheap version: a golden asserting
`base64PublicKey`'s output is exactly what `signing.rs`'s decoder accepts.

## Status effect

**None of the §7 rows is upgraded.** This is precommitted outcome #5: a written
decision does not upgrade a status. The rows stay **KNOWN GAP** / **NOT BUILT**;
what changed is that the KNOWN GAP now cites a mechanism that is true, and the
rotation row is backed by a written procedure in `SIGNING.md` rather than by
nothing.
