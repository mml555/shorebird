#!/usr/bin/env bash
# cspell:words updater_revision getline
#
# Fails when the docs and the pin manifest stop describing the vendored updater.
# Greps only; no cargo build.
#
#   1. vendor/updater yaml.rs: PatchVerificationMode defaults to InstallOnly.
#      selfhost/SIGNING.md and UPDATER_CONTRACT.md say so; a default change to
#      Strict (or anything else) makes them wrong, and an operator who trusts
#      them picks the wrong verification setting.
#   2. vendor/updater updater.rs: download_and_install_patch still calls
#      check_patch_signature. Without that call a device installs an unsigned
#      or forged offer in InstallOnly mode, and the default above is unsafe.
#   3. selfhost/compatibility.yaml `shorebird.updater_revision` equals the first
#      12 characters of the "Source revision" in vendor/updater/VENDOR.md.
#
# Usage: tool/check_updater_pin.sh   (from anywhere inside the checkout)
# Exit:  0 all hold, 1 one or more drifted, 2 a file or line could not be found.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
yaml_rs="$root/vendor/updater/library/src/yaml.rs"
updater_rs="$root/vendor/updater/library/src/updater.rs"
vendor_md="$root/vendor/updater/VENDOR.md"
compat="$root/selfhost/compatibility.yaml"

for f in "$yaml_rs" "$updater_rs" "$vendor_md" "$compat"; do
  [ -f "$f" ] || { echo "check_updater_pin: missing $f" >&2; exit 2; }
done

fail=0
drift() { echo "check_updater_pin: DRIFT: $*" >&2; fail=1; }

# 1. The default variant: `#[default]` on the line directly before InstallOnly,
#    inside the PatchVerificationMode enum.
enum_body=$(awk '/pub enum PatchVerificationMode/{on=1} on{print} on&&/^}/{exit}' "$yaml_rs")
[ -n "$enum_body" ] || { echo "check_updater_pin: PatchVerificationMode not found in $yaml_rs" >&2; exit 2; }
default_variant=$(printf '%s\n' "$enum_body" | awk '/#\[default\]/{getline; gsub(/[ ,]/,""); print; exit}')
if [ "$default_variant" != "InstallOnly" ]; then
  drift "PatchVerificationMode default in vendor/updater/library/src/yaml.rs is '${default_variant:-none}', but selfhost/SIGNING.md and selfhost/UPDATER_CONTRACT.md say InstallOnly. Update both docs, and decide whether the CLI and operators need to change."
fi

# 2. The download-time check, inside download_and_install_patch.
fn_body=$(awk '/^fn download_and_install_patch\(/{on=1} on{print} on&&/^}/{exit}' "$updater_rs")
[ -n "$fn_body" ] || { echo "check_updater_pin: download_and_install_patch not found in $updater_rs" >&2; exit 2; }
if ! printf '%s\n' "$fn_body" | grep -q 'check_patch_signature('; then
  drift "download_and_install_patch in vendor/updater/library/src/updater.rs no longer calls check_patch_signature. Install-time verification is gone; selfhost/SIGNING.md is wrong and InstallOnly verifies nothing."
fi

# 3. compatibility.yaml (current block only, which ends where `previous:` starts)
#    against VENDOR.md.
manifest_rev=$(awk '/^shorebird:/{on=1;next} /^[a-z_]+:/{on=0} on && /^  updater_revision:/{print $2; exit}' "$compat")
vendor_full=$(sed -n 's/^- Source revision: \([0-9a-f]\{40\}\).*/\1/p' "$vendor_md" | head -1)
if [ -z "$manifest_rev" ]; then
  echo "check_updater_pin: no shorebird.updater_revision in $compat" >&2; exit 2
fi
if [ -z "$vendor_full" ]; then
  echo "check_updater_pin: no 40-character 'Source revision' line in $vendor_md" >&2; exit 2
fi
if [ "${vendor_full:0:12}" != "$manifest_rev" ]; then
  drift "selfhost/compatibility.yaml updater_revision is $manifest_rev, but vendor/updater/VENDOR.md names source revision ${vendor_full:0:12} (${vendor_full}). Re-vendor or restamp so they match."
fi

if [ "$fail" -ne 0 ]; then
  echo "check_updater_pin: FAILED" >&2
  exit 1
fi
echo "check_updater_pin: ok (default InstallOnly, download-time signature check present, updater_revision ${manifest_rev} matches vendor/updater)"
