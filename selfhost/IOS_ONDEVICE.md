# iOS on-device patch — completing the last mile

The self-hosted control plane already handles iOS **identically to Android**:
`shorebird release ios` uploads `ios/xcarchive`, `ios/runner`, and
`ios/ios_supplement` artifacts to our server (all sha256-verified), and the
updater's `/patches/check` + signed-URL download path is platform-agnostic. This
was verified with `shorebird release ios --no-codesign` in
[`BEHAVIORAL_FINDINGS.md`](BEHAVIORAL_FINDINGS.md).

**Status: DONE — verified on a physical iPhone.** See
[`BEHAVIORAL_FINDINGS.md`](BEHAVIORAL_FINDINGS.md). The signing gap was closed
without an Xcode account using a build-unsigned + CLI-resign flow
(`packages/code_push_server/tool/ios_resign.sh`), reusing an existing dev cert +
provisioning profile already on the machine. Two signing routes:

- **Automatic (simplest if you use Xcode):** sign an Apple ID into Xcode ▸
  Settings ▸ Accounts, set the app's `DEVELOPMENT_TEAM`, and `shorebird release
  ios` codesigns directly. Requires the Xcode account.
- **Resign (no Xcode account, what we used):** `shorebird release ios
  --no-codesign`, then `tool/ios_resign.sh <Runner.app> <cert-sha1>
  <profile.mobileprovision> <team-id> <bundle-id>`, then install with `xcrun
  devicectl device install app`. The provisioning profile must already include
  the target device's UDID, and the matching dev cert must be in the keychain.

Either way there is no `code_push_server` change required.

## Exact steps to finish it

1. **Use a real, registered bundle id** (not `com.example.spikeapp`). In an app
   with a bundle id under your Apple Developer team:
   - Xcode → Runner target → Signing & Capabilities → select your Team, enable
     "Automatically manage signing" (or install a provisioning profile).
   - Register the target iPhone's UDID with the team (automatic signing does
     this on first device build).
2. **Point the app + CLI at the server.** iOS devices have no `adb reverse`, so
   the device reaches the host over the LAN:
   - Start the server with `PUBLIC_BASE_URL=http://<host-LAN-ip>:8080` (or your
     TLS domain in production).
   - In `shorebird.yaml`: `base_url: http://<host-LAN-ip>:8080` (bundled into the
     app, read by the on-device updater). Ensure the iPhone is on the same Wi-Fi.
   - CLI env: `SHOREBIRD_HOSTED_URL` (+ `AUTH_SERVICE_URL`/`SHOREBIRD_JWT_ISSUER`
     if using OAuth login, or `SHOREBIRD_TOKEN=sb_api_...`).
3. **Release + install:**
   ```bash
   shorebird release ios            # codesigned; produces a device IPA/xcarchive
   # install via Xcode (Window ▸ Devices) or: ios-deploy --bundle <app>.app
   ```
4. **Patch + verify:**
   ```bash
   shorebird patch ios --release-version=<v>
   ```
   Relaunch the app twice (updater downloads on launch N, applies on N+1), same
   as Android. Signed patches work identically (`--public-key-path` on release,
   `--public-key-path` + `--private-key-path` on patch).

## Notes
- Production TLS is recommended for the LAN/remote reach (see `PRODUCTION.md`);
  the updater accepts https `base_url` and our signed download URLs unchanged.
- Everything else (rollouts, withdraw/rollback, metrics, multi-tenancy) applies
  to iOS with no additional work, since it is all keyed by platform+arch in the
  same tables and endpoints.
