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
#      check_patch_signature as a statement. Without that call a device installs
#      an unsigned or forged offer in InstallOnly mode, and the default above is
#      unsafe. A commented-out call does not count.
#   3. selfhost/compatibility.yaml `shorebird.updater_revision` equals the first
#      12 characters of the "Source revision" in vendor/updater/VENDOR.md.
#
# WHAT THIS DOES NOT SEE: the updater the shipped engine builds. That is the
# `updater_rev` in the Flutter fork's DEPS, which is not in this repository, so
# hosted CI cannot read it. This script checks the vendored copy and the pin in
# compatibility.yaml (which stands in for DEPS). The engine-side check is
# selfhost/ci/engine_updater_evidence_guard.sh (#206), run on a host that has the
# engine tree.
#
# Usage: tool/check_updater_pin.sh [checkout-root]   (default: this script's repo)
# Exit:  0 all hold, 1 one or more drifted, 2 a file or line could not be found.
set -euo pipefail

root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
yaml_rs="$root/vendor/updater/library/src/yaml.rs"
updater_rs="$root/vendor/updater/library/src/updater.rs"
vendor_md="$root/vendor/updater/VENDOR.md"
compat="$root/selfhost/compatibility.yaml"

for f in "$yaml_rs" "$updater_rs" "$vendor_md" "$compat"; do
  [ -f "$f" ] || { echo "check_updater_pin: missing $f" >&2; exit 2; }
done

fail=0
drift() { echo "check_updater_pin: DRIFT: $*" >&2; fail=1; }

# (awk programs below read all their input rather than exit early: under pipefail
# an early exit SIGPIPEs the sed upstream and the script dies with 141.)
# Rust source with // comments (and so /// docs) removed. Crude on purpose: a
# `//` inside a string literal is cut too, which only matters for these matches
# if the thing sought is inside such a string.
code() { sed 's,//.*$,,' "$1"; }

# 1. The default variant: the first variant after a #[default] attribute inside
#    the PatchVerificationMode enum, skipping further attributes and blank lines.
enum_body=$(code "$yaml_rs" | awk '/enum[[:space:]]+PatchVerificationMode/{on=1} on&&!done{print} on&&/^[[:space:]]*}/{done=1}')
[ -n "$enum_body" ] || { echo "check_updater_pin: PatchVerificationMode not found in $yaml_rs" >&2; exit 2; }
default_variant=$(printf '%s\n' "$enum_body" | awk '
  /^[[:space:]]*#\[default\]/ {armed=1; next}
  armed && /^[[:space:]]*#\[/ {next}
  armed && /^[[:space:]]*$/ {next}
  armed && !got {gsub(/[[:space:],]/,""); sub(/[({=].*/,""); print; got=1}')
if [ "$default_variant" != "InstallOnly" ]; then
  drift "PatchVerificationMode default in vendor/updater/library/src/yaml.rs is '${default_variant:-none}', but selfhost/SIGNING.md and selfhost/UPDATER_CONTRACT.md say InstallOnly. Update both docs, and decide whether the CLI and operators need to change."
fi

# 2. The download-time check, inside download_and_install_patch (any visibility
#    and generics), as a call statement rather than a mention.
fn_body=$(code "$updater_rs" | awk '/^[[:space:]]*(pub(\([a-z]+\))?[[:space:]]+)?fn[[:space:]]+download_and_install_patch[[:space:]]*[<(]/{on=1} on&&!done{print} on&&/^[[:space:]]*}/{done=1}')
[ -n "$fn_body" ] || { echo "check_updater_pin: download_and_install_patch not found in $updater_rs" >&2; exit 2; }
if ! printf '%s\n' "$fn_body" | grep -Eq '(^|[^[:alnum:]_])(crate::cache::|cache::|signing::)?check_patch_signature[[:space:]]*\('; then
  drift "download_and_install_patch in vendor/updater/library/src/updater.rs no longer calls check_patch_signature. Install-time verification is gone; selfhost/SIGNING.md is wrong and InstallOnly verifies nothing."
fi

# 3. compatibility.yaml (current block only, which ends at the next top-level
#    key) against VENDOR.md. The value may be quoted and may carry a comment.
manifest_rev=$(awk '/^shorebird:/{on=1;next} /^[A-Za-z_]+:/{on=0} on && /^  updater_revision:/ && !got{print $2; got=1}' "$compat" | tr -d "\"'")
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
