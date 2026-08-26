# manual_api_app — G8's manual-update fixture

Drives updates from Dart instead of letting the runtime apply them:
`checkForUpdate(track:)` and `update(track:)` from `package:shorebird_code_push`,
with `auto_update: false`.

**Why it is not the airgap fixture.** `readCurrentPatch` is already exercised by
every airgap release, so a patch number on screen is not evidence for these
calls — precommitted outcome 9 names that as an easy false green. This fixture
therefore records the patch number **before** `update()` and displays both, so
the assertion is that the number *changed across a call we made*.

`android/` is generated (`flutter create`) and gitignored; `pubspec.yaml`
resolves `shorebird_code_push` by **path** from `vendor/updater/`, so the fixture
tests the vendored updater rather than a published one.

## iOS support (added for the manual-updater-API certification)

`ios/` is generated and **not** committed, matching the other fixtures — nothing
under `flavored_app/ios/` is tracked either. Recreate it with:

```sh
flutter create --platforms=ios --org dev.selfhost --project-name manual_api_app .
```

Then apply the three non-default settings this fixture depends on. They are
listed here because they are not defaults and the generated project is not in
the repo:

1. **Signing** — `DEVELOPMENT_TEAM = SK85S6YZP9` beside each
   `PRODUCT_BUNDLE_IDENTIFIER = dev.selfhost.manualApiApp;` in
   `ios/Runner.xcodeproj/project.pbxproj` (the Runner target only; RunnerTests
   is left alone because its signing is irrelevant here and complicates export).
   Bundle id `dev.selfhost.manualApiApp` is deliberately unique — see below.

2. **`NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`** in
   `ios/Runner/Info.plist`. `base_url` is plain `http://` to a LAN address, which
   ATS blocks without this.

3. **`NSLocalNetworkUsageDescription`** in the same file. Without a usage string
   iOS will not even *prompt* for local-network access, and the updater's check
   then fails with an opaque network error — a prerequisite the flavor arm had to
   discover on the device.

### One device client only, on purpose

The tracks arm cut two clients from one build and hit a hard constraint: copies
of one build share `LC_UUID`, iOS attributes local-network permission by
executable UUID, and a colliding set had connections refused in ~0.2ms for
*every* app involved. This row needs only **one** client, so no bundle is cloned
and that failure mode stays out of the experiment entirely.

### Control-plane app

`shorebird.yaml` is generated per instance (`app_id` is server-assigned). Point
the CLI at the self-hosted plane with `SHOREBIRD_HOSTED_URL`, which takes
precedence over `base_url` and works before any `shorebird.yaml` exists:

```sh
SHOREBIRD_HOSTED_URL=http://10.0.0.7:18080 shorebird init
```

`init` writes `ShorebirdYaml(appId: …)` and **only** that, so `auto_update: false`
and `base_url` must be added afterwards. `auto_update: false` is the hinge of
this fixture: if the runtime may apply a patch on its own, a patch number
appearing on screen proves nothing about `checkForUpdate`/`update`.
