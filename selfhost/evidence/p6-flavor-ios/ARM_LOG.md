<!-- cspell:words flavoredprobe airgap precommitted nostart -->

# P6 iOS flavor arm — run log

Kept as a log rather than a verdict, because the arm produced a **negative
result** first and the cause is worth more than a clean pass would have been.

## Attempt 1 — release 114, patch 1: NEGATIVE

Baseline tapped and captured (`01_baseline_tap.png`): `FLAVORED-FIXTURE-V1`,
`V1/Foo`, `BAKED-INTO-RELEASE`. The flavor reached the compiler and is visible on
the physical device — that much held.

Patch published (`patch 78`, ready/stable/active/100%). Two taps by hand. The
device still read **`V1/Foo`** (`02_patched_tap.png`).

**Not declared a pass, and not declared a Route B failure.** The updater's own
state was pulled instead of guessed:

    state.json  { "release_version": "1.2.0+1", "queued_events": [] }
                 — no patch, no events

    shorebird.yaml (baked into the app)
                 base_url: http://localhost:18080

**Cause: `localhost` on a phone is the phone.** The app could not reach the
control plane at all, so no patch was ever fetched. Nothing errored anywhere: the
release published, the patch published and rolled out to 100%, and the app showed
its baseline. That is the silent-success shape this project is organised against,
arriving through configuration rather than through Route B.

`airgap_app` — the fixture with banked device evidence — uses the host's LAN
address for exactly this reason. `prepare_flavored_fixture.sh` defaulted to
`localhost` and kept that default even when `--app-id` was supplied, i.e. even
for a release a device is expected to fetch.

**Guard added**: the preparer now REFUSES a `localhost` base_url once an
`--app-id` is present, printing the host's actual LAN address in the remediation.
`ALLOW_LOCALHOST=1` remains for host-only builds no device will fetch.

## The defect this arm found in Route B itself

Before any of the above, the patch would not build at all:

    package:flavored_probe/main.dart#flavorState
        the bytecode compiler refused its replacement body (exit 254)

No compiler diagnostic — the shape that makes a real defect look like a toolchain
shrug. The generated replacement was:

    import 'package:flavored_probe/main.dart';
    String flavorState() => ... appFlavor ...

`appFlavor` is Flutter's global from `package:flutter/services.dart`, which the
target library IMPORTS. **Dart imports are not transitive**, so a replacement
importing only the target library cannot resolve anything the target imports —
a widget, a `jsonEncode`, an `intl` call. P1/P2 never hit it because those bodies
used only the target's own members and `dart:core`.

Fixed: replacements now inherit the target library's `dart:`/`package:` imports
verbatim, combinators and prefixes included. A **relative** import is refused by
name rather than dropped, because copied as-is it resolves against the wrong
directory and rewritten to a file URI it makes the CFE see one library twice.

Two regression tests, both red before the fix. And one defect in the fix itself,
caught by the positive test: the regex lost its raw-string prefix, so `\\s` became
a literal `s`, the pattern matched nothing, and the generated library looked
exactly as before. A refusal-only test would have passed.

## Attempt 2 — release 115, patch 1

Base URL corrected to `http://10.0.0.7:18080`, target body restored to `V1` so
the release is a true baseline, release **115** (`1.3.0+1`) cut and shape-verified
(8/8, binding digest `add3fb11013090a2` = the actual signed App binary), then
installed with `--nostart` so no launch of mine precedes the observations.

Patch **79** published: ready, stable, active, 100 %, `aarch64/ios`
`dd3e88a53bc4bdbe`.

Awaiting the two by-hand taps.

## Releases in this arm, and why each exists

| release | signing | purpose |
|---|---|---|
| 113 (`1.1.0+1`) | `--no-codesign` | the clean CLI/control-plane release-shape proof. Frozen |
| 114 (`1.2.0+1`) | development | first physical baseline. Superseded: device-unreachable `base_url` |
| 115 (`1.3.0+1`) | development | the physical baseline, reachable control plane |

Each was cut rather than re-signed or edited, because the exact-artifact rule
means a changed bundle is a different release.
