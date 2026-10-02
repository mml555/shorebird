#!/usr/bin/env bash
# cspell:words killswitch libexec mobileprovision plutil PlistBuddy
#
# prepare_killswitch_fixture.sh -- materialize selfhost/fixtures/killswitch_app.
#
# WHY A SEPARATE SCRIPT, again. prepare_airgap_fixture.sh hardcodes its fixture
# and dies on an unknown flag; prepare_twoengine_fixture.sh is the same shape for
# a different fixture. A third script contends with nothing, and editing either
# of the others would touch a script that device gates use while device gates
# are running.
#
# WHAT IT DOES
#   1. `flutter create` the ios/ tree if absent (generated and gitignored).
#   2. Inject DEVELOPMENT_TEAM, WITHOUT WHICH THE ARCHIVE SUCCEEDS AND THE EXPORT
#      FAILS -- see the block at step 2. This has cost a release attempt before.
#   2b. Inject the NATIVE half of the execution receipt into AppDelegate.swift.
#   3. Write shorebird.yaml from the template with a real app_id.
#
# It deliberately does NOT delete UIApplicationSceneManifest the way the
# twoengine script does: that fixture needed the host to own the window, this one
# renders an ordinary Flutter app and the scene manifest is harmless here.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIXTURE="$(cd "$HERE/../fixtures/killswitch_app" >/dev/null 2>&1 && pwd)"
FLUTTER="${FLUTTER:-$HOME/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/flutter}"
APP_ID="${APP_ID:-}"
# NOT localhost. On the DEVICE, localhost is the phone — the app would never
# reach the control plane, would never see a patch, and the arm would read as
# "the patch did not apply" rather than as a misconfigured fixture. Measured
# 2026-08-14: with localhost, state.json on device carried no patch state at all.
# The sibling airgap_app uses this same LAN address for the same reason.
BASE_URL="${BASE_URL:-http://10.0.0.7:18080}"
TEAM="${TEAM:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id)   APP_ID="${2:?}"; shift 2 ;;
    --base-url) BASE_URL="${2:?}"; shift 2 ;;
    --team)     TEAM="${2:?}"; shift 2 ;;
    --flutter)  FLUTTER="${2:?}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

cd "$FIXTURE"
echo "==> fixture: $FIXTURE"
echo "==> flutter: $FLUTTER"

# 1. The generated iOS tree.
if [ -d ios ]; then
  echo "==> ios/ already present"
else
  echo "==> flutter create --platforms=ios"
  "$FLUTTER" create --platforms=ios --org dev.selfhost --project-name killswitch_probe . >/dev/null
  echo "==> ios/ created"
fi

# 2. THE SIGNING TEAM, and it is a step rather than an assumption.
#
# `flutter create` writes no DEVELOPMENT_TEAM, so CODE_SIGN_STYLE = Automatic has
# nothing to match and `flutter build ipa` fails at EXPORT with "No profiles for
# 'dev.selfhost.killswitchProbe' were found" plus "No Accounts" -- AFTER a
# successful archive, which makes it read as a signing-account problem rather
# than a missing setting.
#
# The team is auto-detected from an installed WILDCARD profile (`<TEAM>.*`),
# which is what already covers this fixture's siblings. A wildcard match means no
# new profile has to be created for a new bundle id.
if [ -z "$TEAM" ]; then
  for prof in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    [ -f "$prof" ] || continue
    appid=$(security cms -D -i "$prof" 2>/dev/null |
      plutil -extract Entitlements.application-identifier raw - 2>/dev/null)
    case "$appid" in
      *.\*) TEAM="${appid%%.*}"; break ;;
    esac
  done
fi
if [ -n "$TEAM" ]; then
  PBX=ios/Runner.xcodeproj/project.pbxproj
  if grep -q "DEVELOPMENT_TEAM" "$PBX"; then
    echo "==> DEVELOPMENT_TEAM already present"
  else
    /usr/bin/sed -i '' \
      "s|^\(.*\)PRODUCT_BUNDLE_IDENTIFIER = \(.*\);|\1PRODUCT_BUNDLE_IDENTIFIER = \2;\n\1DEVELOPMENT_TEAM = $TEAM;|" \
      "$PBX"
    echo "==> DEVELOPMENT_TEAM = $TEAM injected ($(grep -c DEVELOPMENT_TEAM "$PBX") sites)"
  fi
else
  echo "==> WARNING: no wildcard provisioning profile found and no --team given." >&2
  echo "    The archive will succeed and the IPA EXPORT will fail. Pass --team." >&2
fi

# 2b. THE NATIVE HALF OF THE EXECUTION RECEIPT.
#
# WHY IT IS NEEDED AT ALL. On 2026-08-14 the fixture produced a blank screen with
# its Dart-side marker unmoved, and the verdict written from it -- "main() DID NOT
# RUN, not at all" -- could not actually be supported: an unmoved Dart marker is
# equally consistent with the app never having launched, with the engine never
# starting, and with main() being entered and dying on its first statement. No
# Dart-side instrument can tell those apart, because all three leave Dart silent.
#
# These two lines can. `native launch` proves the process reached
# didFinishLaunchingWithOptions; `native engine` proves the implicit FlutterEngine
# was created. A receipt holding `native engine` with no `dart-main-entered` after
# it is a POSITIVE observation that the engine started and Dart did not.
#
# NSHomeDirectory() is the sandbox root here. That is NOT the same trap as the
# Dart side's: `Platform.environment['HOME']` is unset on iOS, which is why the
# Dart half derives the sandbox from Directory.systemTemp.parent instead. The two
# must resolve to the same directory, and the first device run confirms it by
# showing native and dart lines in ONE file.
#
# Written wholesale rather than patched in: the file is generated, this fixture
# has no plugins by design, and a regex against a template that upstream rewrites
# is how a silent no-op gets shipped.
APPD=ios/Runner/AppDelegate.swift
if grep -q "g15Receipt" "$APPD" 2>/dev/null; then
  echo "==> AppDelegate.swift already carries the native receipt"
else
  cat > "$APPD" <<'SWIFT'
import Flutter
import UIKit

// G15 NATIVE EXECUTION RECEIPT -- injected by prepare_killswitch_fixture.sh.
// ios/ is generated and gitignored, so this file is not the place to edit it.
// See lib/main.dart for what the phases mean and why the receipt exists.
//
// NSHomeDirectory() IS the sandbox root for native code. The Dart half cannot
// use the equivalent -- HOME is unset on iOS -- so it derives the sandbox from
// Directory.systemTemp.parent. Both must land in the same Documents directory.
func g15Receipt(_ phase: String) {
  let dir = NSHomeDirectory() + "/Documents"
  let path = dir + "/g15_receipt"
  try? FileManager.default.createDirectory(
    atPath: dir, withIntermediateDirectories: true)
  guard let data = "native \(phase)\n".data(using: .utf8) else { return }
  if let fh = FileHandle(forWritingAtPath: path) {
    fh.seekToEndOfFile()
    fh.write(data)
    fh.closeFile()
  } else {
    FileManager.default.createFile(atPath: path, contents: data)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BEFORE super: super is what creates the implicit engine and runs Dart, so
    // a receipt written after it would not distinguish "the process started"
    // from "the engine started".
    g15Receipt("launch")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    g15Receipt("engine")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
SWIFT
  echo "==> AppDelegate.swift rewritten with the native receipt"
fi

# 3. shorebird.yaml. Unlike twoengine_app's, these values ARE contacted: this arm
#    needs a real release and a real patch, because the question is whether the
#    updater tombstones a patch it should not.
if [ -z "$APP_ID" ]; then
  echo "==> no --app-id given; leaving shorebird.yaml alone" >&2
else
  sed -e "s|^app_id: .*|app_id: $APP_ID|" \
      -e "s|^base_url: .*|base_url: $BASE_URL|" \
      shorebird.yaml.template > shorebird.yaml
  echo "==> shorebird.yaml written (app_id $APP_ID, base_url $BASE_URL)"
fi

echo "==> ready"
