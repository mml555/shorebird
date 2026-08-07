# Canonical air-gap acceptance fixture

The app the sealed two-platform acceptance run builds, patches and rolls back.

**This is not the app the 2026-08-06 acceptance used.** That one lived in a
session scratchpad, the scratchpad was cleaned, and its path was never recorded
— so that run cannot be reproduced, and no continuity is claimed with it. This
fixture exists so the *next* pass is reproducible. The guarantee changes from
"regression against a specific historical app" (unprovable) to "reproducible
sealed acceptance using durable, documented fixtures", which is the better one.

## What is committed vs generated

| | |
|---|---|
| **Committed** | `pubspec.yaml`, `pubspec.lock`, `lib/main.dart`, `assets/probe.json`, this README |
| **Generated** (gitignored) | `ios/`, `android/`, `.dart_tool/`, `build/`, and the real `shorebird.yaml` |

`ios/` and `android/` are `flutter create` output — bulky and fully derived, so
they are rebuilt rather than stored. `shorebird.yaml` is generated because
**`app_id` is server-generated**: `POST /api/v1/apps` ignores a requested id, so
it differs per control-plane instance and cannot be a committed constant. The
committed placeholder says `REPLACE-ME`, and the harness refuses to run against
it.

## Preparing it

```bash
# once per control-plane instance — create the app, note the id
curl -sS -X POST http://localhost:18080/api/v1/apps \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"display_name":"airgap-fixture"}'

selfhost/scripts/prepare_airgap_fixture.sh --app-id <id>
```

That materializes the platform dirs and builds the **pub seed** from the
committed lockfile into `selfhost/fixtures/airgap/pub-cache`, with a contract in
`SEED.txt` (seed path, lockfile sha256, package count, index). `airgap_run.sh`
defaults `AIRGAP_PUB_CACHE` to it.

**The seed is never an ambient `~/.pub-cache`.** The 2026-08-06 run used one and
left no record of its contents, which is the other half of why it could not be
reproduced.

## What it renders, and why these four lines

```
release:        AIRGAP-FIXTURE-V1     <- compiled in; a CODE patch changes it
asset:          BAKED-INTO-RELEASE    <- probe.json via the runtime bundle
assets patch:   none                  <- the patch whose assets are served
code patch:     none                  <- the running code patch
```

Splitting **assets patch** from **code patch** is the whole point. An
assets-only patch is deliberately never offered to the native updater — it
would inflate an asset archive as a binary diff and tombstone the patch — so
anything reading only the updater's patch number sees "no patch" and cannot
distinguish a working asset overlay from a broken one.

That is why the fixture depends on **`code_push_runtime`, not
`shorebird_code_push`**: it does its own discovery and reports
`assetsPatchNumber` separately from `patchNumber`. With the wrong package the
iOS assets-only check fails for a reason that has nothing to do with what is
being tested.

The correct result after an assets-only patch is therefore:

```
release:        AIRGAP-FIXTURE-V1     <- UNCHANGED
asset:          PATCHED-AIRGAP        <- changed
assets patch:   1
code patch:     none                  <- still none
```

## How the harness asserts it

The app **beacons** its rendered state as a query string:

```
GET <base_url>/selfhost-beacon/state?release=…&asset=…&assets_patch=…&code_patch=…
```

No server endpoint is required — the control plane logs every request line, so
a 404 there is a success and the URL *is* the payload. The harness greps that
log. Screenshots (`build/airgap-release.png`, `build/airgap-patched.png`) are
human-readable evidence, never the correctness mechanism: OCR is a bad
assertion.

`base_url` comes from the bundled `shorebird.yaml`, the same address the
updater uses, so the beacon cannot drift from the control plane under test.
Beacon failures are swallowed — a beacon that cannot send must not change what
the app displays.

`AIRGAP_SKIP_DEVICE=1` publishes without verifying, and says so loudly. A PASS
under that flag means publication succeeded and nothing more.

## Per-run housekeeping

**Bump `version:` in `pubspec.yaml` before each acceptance run.** The control
plane rejects a duplicate release version, and the harness derives
`--release-version` from that field.
