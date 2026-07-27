# iOS code signing with the self-hosted control plane

The server handles iOS **identically to Android** — `shorebird release ios`
uploads `ios/xcarchive`, `ios/runner`, `ios/ios_supplement` (all sha256-verified)
and the updater's `/patches/check` + signed-URL download path is
platform-agnostic. **No `code_push_server` change is ever needed for iOS.** The
only iOS-specific work is Apple **code signing** of the app bundle, which is
Apple's requirement, not ours.

This was verified end-to-end on a physical iPhone (see
[`BEHAVIORAL_FINDINGS.md`](BEHAVIORAL_FINDINGS.md)). The tooling below turns that
one-off into three supported, scripted signing modes plus a one-command flow.

> Apple **bundle** signing (this doc) is separate from Shorebird **patch**
> signing (`--public-key-path` / `--private-key-path`, the `hash_signature` the
> server passes through). You can use either, both, or neither.

## Pick a signing mode

| Mode | Use when | How the release is signed |
|---|---|---|
| **auto** | You use Xcode and have an Apple ID / `DEVELOPMENT_TEAM` set on the target | `shorebird release ios` signs directly via the Xcode project. The normal path. |
| **manual** | Headless / CI, or you want explicit control — you have a cert (`.p12`) + provisioning profile | `shorebird release ios --export-options-plist=<plist>` with a generated plist. |
| **resign** | No Apple ID is signed into Xcode, but a dev cert + device-provisioning profile already exist on the machine | `shorebird release ios --no-codesign`, then re-sign the unsigned build with `codesign`. |

All three are driven by one wrapper, `tool/ios_ship.sh`, which infers the mode
(`IOS_EXPORT_OPTIONS` → manual, else `IOS_PROFILE` → resign, else auto) or takes
`IOS_SIGN_MODE=auto|manual|resign` explicitly.

## One-command flow

From your Flutter app directory, with the CLI pointed at your server
(`SHOREBIRD_TOKEN=sb_api_...` or OAuth env, and `base_url` in `shorebird.yaml`):

```bash
# auto (Xcode-signed): release + install + patch
APP_DIR=$PWD DEVICE=<udid> tool/ios_ship.sh both

# manual (CI/explicit): profile → export-options-plist is generated for you
APP_DIR=$PWD DEVICE=<udid> IOS_SIGN_MODE=manual IOS_PROFILE=dist.mobileprovision \
  IOS_METHOD=ad-hoc tool/ios_ship.sh both

# resign (no Xcode account): only the profile is required — team + bundle are
# read from it, and the identity is auto-selected if there's exactly one
APP_DIR=$PWD DEVICE=<udid> IOS_SIGN_MODE=resign IOS_PROFILE=dev.mobileprovision \
  tool/ios_ship.sh both
```

`ios_ship.sh <release|patch|both>` runs `shorebird release ios` with the right
flags, installs to the device (`xcrun devicectl`), and for `patch`/`both`
publishes the patch and reminds you to relaunch twice (download on launch N,
apply on N+1 — same as Android).

## The tools (all in `packages/code_push_server/tool/`)

- **`ios_ship.sh`** — the orchestrator above.
- **`ios_export_options.sh`** — generate a valid `export-options-plist` for the
  manual path. It pins the one Shorebird rule the CLI enforces:
  `manageAppVersionAndBuildNumber = false` (if Xcode rewrites the build number,
  the shipped version won't match the recorded release and **patches silently
  fail**). Reads team / bundle / profile-name from the profile:
  ```bash
  tool/ios_export_options.sh --profile dist.mobileprovision \
      --method app-store-connect --out export_options.plist
  ```
- **`ios_resign.sh`** — re-sign an unsigned build. Extracts the **real
  entitlements from the provisioning profile** (so push, app-groups,
  associated-domains, keychain-groups survive — a hand-written minimal
  entitlements set strips them), signs nested frameworks/plugins inside-out,
  validates the target device against the profile (`IOS_DEVICE_UDID`), and reads
  team + bundle from the profile:
  ```bash
  IOS_DEVICE_UDID=<udid> tool/ios_resign.sh build/.../Runner.app "" dev.mobileprovision
  ```
- **`ios_ci_keychain.sh`** — headless signing setup for CI: import a `.p12` into a
  throwaway keychain and install the profile, so the manual path works with no
  Xcode UI. Pass the export password via `IOS_P12_PASSWORD` (never on argv).
- **`lib/ios_signing.sh`** — shared, read-only profile/keychain inspection used
  by the above (decode profile, extract entitlements/team/bundle/UUID/devices,
  resolve identity).

## CI recipe (headless manual signing)

```bash
export IOS_P12_PASSWORD='...'                       # from your secret store
tool/ios_ci_keychain.sh setup --p12 cert.p12 --profile dist.mobileprovision
APP_DIR=$PWD DEVICE=<udid> IOS_SIGN_MODE=manual \
  IOS_PROFILE=dist.mobileprovision IOS_METHOD=app-store-connect \
  tool/ios_ship.sh release
tool/ios_ci_keychain.sh teardown                    # always, even on failure
```

## Notes

- **Reaching the server from the device.** iOS has no `adb reverse`, so the
  iPhone reaches the host over the LAN (or your TLS domain in production). Set
  `PUBLIC_BASE_URL` and the app's `shorebird.yaml` `base_url` to a host the
  device can reach, and keep them on the same network. Production TLS is
  recommended (see `PRODUCTION.md`); the updater accepts https `base_url` and the
  signed download URLs unchanged.
- **Provisioning must include the device.** For dev/ad-hoc installs the profile
  must list the target UDID; `ios_resign.sh` fails fast if it doesn't (and warns
  for a distribution profile, which has no device list).
- **Everything else is platform-agnostic.** Rollouts, withdraw/rollback,
  metrics, multi-tenancy, and signed download URLs all apply to iOS unchanged —
  they're keyed by platform+arch in the same tables and endpoints as Android.
</content>
