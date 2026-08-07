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

## What it renders, and why in three lines

```
release state:   AIRGAP-FIXTURE-V1     <- compiled in; a CODE patch changes it
asset state:     BAKED-INTO-RELEASE    <- assets/probe.json; an ASSETS patch changes it
patch number:    null                  <- from the updater
```

Splitting code state from asset state is the point. The iOS leg publishes an
**assets-only** patch, so the correct result there is a *changed asset line
beside an unchanged release line* — that pairing is what distinguishes "the
asset arrived through app-side discovery" from "a code patch landed", and a
single combined line could not show it.

`readCurrentPatch()` failures render as `ERROR: …` rather than blanking the
screen: an unreadable patch number is itself a result worth seeing on a
screenshot.

## Per-run housekeeping

**Bump `version:` in `pubspec.yaml` before each acceptance run.** The control
plane rejects a duplicate release version, and the harness derives
`--release-version` from that field.
