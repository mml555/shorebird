# Signing Arm A — the Dart to Rust cryptographic seam: CLOSED

The values the CLI actually emits are accepted by the verifier that actually
runs on a device.

## What was missing

The existing Dart signing tests sign and verify **with Dart**; the Rust tests
verify **hand-generated constants**. Neither crosses the boundary that matters:

    Dart CodeSigner                Rust cache::signing::check_signature
      sign()          -> b64 sig  ->  b64 decode -> ring RSA_PKCS1_SHA256
      base64PublicKey -> b64 DER  ->  b64 decode -> UnparsedPublicKey

A key-encoding or signature-format disagreement across that gap would pass every
existing test and fail on a device. The prior 15 Dart signing tests are **not**
Arm A evidence and are not claimed as such.

## The verifier is the production one

Reached through the existing test-hooks boundary, with nothing reimplemented:

    library_test_hooks::shorebird_test_check_signature   (new C symbol, test-only)
      -> updater::testing_check_signature                (new, #[cfg(any(test, feature = "test-hooks"))])
        -> cache::signing::check_signature               (UNCHANGED production fn)

`cache::signing` was widened to **`pub(crate)`**, not `pub`. No production C
API was added; `test-hooks` remains off by default, so the cdylib that ships in
the engine neither enables it nor links the hooks crate. OpenSSL is used only as
a **signer**, never as the oracle.

## Result

```
ARM A IDENTITIES
  message                : 25bf2ef564e30fcc785e0e84f7a08dc1a0caa33b5676e5bd1b625739ee84c63c
  sha256(public PEM)     : 1ce6cb240418a625bd5e9ba03520b895173d5151f7d0ff5d29fcac208af2d9bf
  sha256(DER path)       : 288ad42d4f1dd39af933ca0a1fa2ae28f1b90252fd6da14d1e5632baa11c7baa
  sha256(DER cmd)        : 288ad42d4f1dd39af933ca0a1fa2ae28f1b90252fd6da14d1e5632baa11c7baa
  sha256(sig file)       : 5ab1f5ad0928ee90913165d109e3da553d3006443331b65c49cc5d65fecbc9b3
  sha256(sig cmd)        : 5ab1f5ad0928ee90913165d109e3da553d3006443331b65c49cc5d65fecbc9b3
  rust: file-backed      : ACCEPT
  rust: command-backed   : ACCEPT
  rust: mutated signature: REJECT
  rust: wrong message    : REJECT
```

Identical `sha256(DER path)` and `sha256(DER cmd)` — the two public-key
surfaces resolve to the same bytes. Identical `sha256(sig file)` and
`sha256(sig cmd)` — RSA PKCS#1 v1.5 SHA-256 is deterministic for a fixed
key and message, so an independent OpenSSL signer produces the same signature as
the Dart one. That equality is asserted, not merely observed; if it ever fails
while both still verify, the assertion stays and the reason gets explained.

## The four CLI surfaces exercised

| surface | call |
|---|---|
| `--public-key-path` | `CodeSigner.base64PublicKey(public.pem)` |
| `--private-key-path` | `CodeSigner.sign(message, private.pem)` |
| `--public-key-cmd` | `runPublicKeyCmd('openssl rsa -in … -pubout')` then `base64PublicKeyFromPem` |
| `--sign-cmd` | `signWithCmd(data, 'openssl dgst -sha256 -sign … \| openssl base64 -A')` |

The command-backed arm shells out to real OpenSSL rather than calling back into
Dart, so it exercises a genuinely foreign signer. The message is a 64-character
lowercase SHA-256 hex string, which is the shape production patch signing signs.

## Negative controls

* **one flipped byte** in the decoded signature, same message, same key → REJECT;
* the **same valid signature against a different 64-hex message** → REJECT. This
  is the one that proves the verifier binds to the actual patch hash rather than
  recognising a structurally valid signature.

K2 is deliberately not used here; it belongs to the device causal arm.

## Anti-vacuity

The FFI path was mutation-tested: making `shorebird_test_check_signature`
return 0 unconditionally makes the negatives fail with *"a mutated signature was
ACCEPTED"*. Without that, four green lines could have meant nothing more than a
hook that always says yes.

A second test pins the algorithm itself — `RSA_PKCS1_2048_8192_SHA256` and
`BASE64_STANDARD` in `signing.rs` — because Arm A is meaningless if the
verifier were later switched to another scheme.

`setUpAll` **refuses** rather than skips when OpenSSL is absent: a silently
skipped crypto-seam test is indistinguishable from a passing one.

## Key material

Generated per run into a temp directory and deleted in `tearDownAll`. No
private key is committed, and the evidence above records only hashes.

## Suite state

`shorebird_cli`: 2623 pass, 1 pre-existing skip. `cargo test -p updater --lib`:
262 pass. Production `cargo build -p updater` unaffected.
