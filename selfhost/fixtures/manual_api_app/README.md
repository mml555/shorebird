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
