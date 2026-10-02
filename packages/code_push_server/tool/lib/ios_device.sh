# shellcheck shell=bash
# cspell:words iosdev xctrace noinstall justlaunch mobileprovision udid coredevice
#
# Installing and launching on a physical iPhone, across the CoreDevice divide.
#
# `xcrun devicectl` (CoreDevice) only speaks to **iOS 17 and newer**. An older
# device is not merely unsupported — it is *invisible* to it, so `devicectl
# device install` fails with a device-not-found style error that reads like a
# pairing or signing problem. An iPhone 7 tops out at iOS 15.8, and older
# hardware is exactly what ends up on a test bench, so both transports have to
# work.
#
# Below iOS 17 we use `ios-deploy`. Flutter bundles a copy, which is preferred
# over any on PATH so the tool matches the toolchain in use.
#
# Sourced by ios_ship.sh and e2e_device.sh. Self-contained: defines its own
# error helper rather than depending on lib/ios_signing.sh, which is about
# profiles and keychains, not transport.

iosdev::_err() { echo "ERROR: $*" >&2; }

# The iOS version of an attached device, or empty if it cannot be determined.
#
# `xctrace` is used rather than `devicectl list devices` precisely because the
# latter cannot see the devices this function exists to detect.
iosdev::os_version() {
  local udid="${1:?udid required}"
  # Lines look like: `Name (17.5.1) (00008020-000...)`. Take the FIRST
  # parenthesised group that begins with a digit — a greedy match would return
  # the UDID instead, and a UDID starting with a digit would then parse as a
  # nonsense version.
  xcrun xctrace list devices 2>/dev/null \
    | grep -F "$udid" \
    | head -1 \
    | sed -nE 's/^[^(]*\(([0-9][0-9.]*)\).*/\1/p'
}

# Path to a usable ios-deploy, preferring Flutter's bundled copy so the tool
# matches the toolchain in use.
#
# Never name a local `path` here: in zsh that is the array tied to $PATH, so
# `local path` blanks PATH for the whole function and every lookup inside it
# silently finds nothing. This file is bash, but it is short enough to source
# from an interactive zsh while debugging, and that failure looks like
# "ios-deploy is not installed" when it is.
iosdev::ios_deploy() {
  local flutter_bin flutter_root bundled found
  flutter_bin="$(command -v flutter 2>/dev/null || true)"
  if [ -n "$flutter_bin" ]; then
    # Resolve the symlink: Homebrew puts a link in bin/ pointing into the
    # Caskroom, and the bundled artifacts live next to the *real* binary.
    flutter_root="$(cd "$(dirname "$(iosdev::_resolve "$flutter_bin")")/.." 2>/dev/null && pwd || true)"
    bundled="$flutter_root/bin/cache/artifacts/ios-deploy/ios-deploy"
    if [ -x "$bundled" ]; then printf '%s\n' "$bundled"; return 0; fi
  fi
  found="$(command -v ios-deploy 2>/dev/null || true)"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  return 1
}

# Follow a symlink chain to the real file. `readlink -f` is GNU-only; macOS
# ships a readlink without it until quite recently.
iosdev::_resolve() {
  local target="$1" link
  while [ -L "$target" ]; do
    link="$(readlink "$target")"
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/$link" ;;
    esac
  done
  printf '%s\n' "$target"
}

# True when the device should be driven by devicectl rather than ios-deploy.
#
# Unknown version assumes modern, which is only sound because both callers fall
# back to ios-deploy when devicectl fails. `xctrace` does intermittently report
# no version for a busy device — observed on an iOS 15 device immediately after
# an install — so this guess is wrong often enough to need that fallback.
iosdev::_is_coredevice() {
  local major="${1%%.*}"
  [ -z "$major" ] && return 0
  [ "$major" -ge 17 ] 2>/dev/null
}

# Extract the .app from an .ipa; echoes the .app path. ios-deploy takes a
# bundle directory, not an archive, while devicectl accepts either.
iosdev::_app_from_ipa() {
  local ipa="$1" tmp app
  tmp="$(mktemp -d)" || return 1
  unzip -q "$ipa" -d "$tmp" || { iosdev::_err "could not unzip $ipa"; return 1; }
  app="$(find "$tmp/Payload" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)"
  [ -n "$app" ] || { iosdev::_err "no .app inside $ipa"; return 1; }
  printf '%s\n' "$app"
}

# iosdev::install <udid> <artifact.app|artifact.ipa>
iosdev::install() {
  local udid="${1:?udid required}" artifact="${2:?artifact required}"
  local ver app deploy
  ver="$(iosdev::os_version "$udid")"
  echo "installing $(basename "$artifact") -> $udid (iOS ${ver:-unknown})"

  if iosdev::_is_coredevice "$ver"; then
    if xcrun devicectl device install app --device "$udid" "$artifact"; then
      echo "installed (devicectl)"
      return 0
    fi
    # Fall through rather than fail. `xctrace` occasionally returns no version
    # for a device that is busy or mid-reconnect, and an unknown version is
    # assumed modern — so a devicectl failure here may simply mean the device is
    # older than the guess. Observed for real on an iOS 15 device that had just
    # been installed to.
    iosdev::_err "devicectl install failed (iOS ${ver:-unknown}); trying ios-deploy"
  fi

  deploy="$(iosdev::ios_deploy)" || {
    iosdev::_err "iOS $ver needs ios-deploy (devicectl is iOS 17+ only) and none was found.
  Install it with: brew install ios-deploy"
    return 1
  }
  app="$artifact"
  case "$artifact" in
    *.ipa) app="$(iosdev::_app_from_ipa "$artifact")" || return 1 ;;
  esac
  # --no-wifi is deliberate: this project tests over cable only, and letting
  # ios-deploy pick a wireless peer silently installs to the wrong transport.
  "$deploy" --id "$udid" --bundle "$app" --no-wifi || {
    iosdev::_err "ios-deploy install failed"
    return 1
  }
  echo "installed (ios-deploy)"
}

# iosdev::launch <udid> <bundle-id> [app-or-ipa]
#
# The third argument is only needed on the pre-17 path, where ios-deploy
# launches from the bundle rather than by identifier.
iosdev::launch() {
  local udid="${1:?udid required}" bundle_id="${2:?bundle id required}" artifact="${3:-}"
  local ver app deploy
  ver="$(iosdev::os_version "$udid")"

  if iosdev::_is_coredevice "$ver"; then
    if xcrun devicectl device process launch --terminate-existing --device "$udid" \
      "$bundle_id"; then
      return 0
    fi
    # Same fallback as install: an unknown version is assumed modern, so a
    # devicectl failure can mean "actually an older device" rather than "launch
    # failed". Only worth retrying when we were given a bundle to launch from.
    [ -n "$artifact" ] || return 1
    iosdev::_err "devicectl launch failed (iOS ${ver:-unknown}); trying ios-deploy"
  fi

  deploy="$(iosdev::ios_deploy)" || { iosdev::_err "ios-deploy not found"; return 1; }
  if [ -z "$artifact" ]; then
    iosdev::_err "launching on iOS $ver needs the .app/.ipa path (ios-deploy cannot launch by bundle id)"
    return 1
  fi
  app="$artifact"
  case "$artifact" in
    *.ipa) app="$(iosdev::_app_from_ipa "$artifact")" || return 1 ;;
  esac
  "$deploy" --id "$udid" --bundle "$app" --no-wifi --justlaunch --noinstall
}
