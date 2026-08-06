#!/usr/bin/env bash
# publish_patch_tool.sh — build the `patch` binary from OUR source and package it
# the way the CLI expects, removing one download from Shorebird's bucket.
#
# Independence item 6 (see selfhost/UPSTREAM_INDEPENDENCE.md). This one is easy
# and was simply undone: the differ's source has always been ours, at
# vendor/updater/patch (bidiff + zstd via comde).
#
# Verified 2026-08-03: our build's output is BYTE-IDENTICAL to the binary
# Shorebird ships, on a 3 MB input with three localized edits (same sha256, same
# 15,177-byte patch). So this is a drop-in substitution, not a lookalike.
#
# The contract, from packages/shorebird_cli/lib/src/cache.dart PatchArtifact:
#   URL   {storageBaseUrl}/{storageBucket}/shorebird/{engineRevision}/patch-<plat>.zip
#   body  a ZIP with the executable named `patch` at its root
#   check checksum is null -> no verification, so our bytes are accepted as-is
#
# Both URL components are already env-overridable in our fork
# (SHOREBIRD_STORAGE_BASE_URL / SHOREBIRD_STORAGE_BUCKET), so serving this from
# the overlay needs no CLI change.
#
# Windows is not buildable here and stays mirrored — a recorded, deliberate gap.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=""
REV=""
BUCKET="download.shorebird.dev"
OUT_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}"
  cat <<'EOF'

Usage:
  publish_patch_tool.sh --out <dir>
  publish_patch_tool.sh --overlay <dir> --rev <engineRevision> [--bucket <name>]

  --out <dir>       Just build and package the zip into <dir>.
  --overlay <dir>   Also install into an overlay tree at
                    <overlay>/<bucket>/shorebird/<rev>/.
  --rev <sha>       Engine revision the CLI will ask for (required with --overlay).
  --bucket <name>   Default: download.shorebird.dev
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --rev) REV="${2:?}"; shift 2 ;;
    --bucket) BUCKET="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$OVERLAY" && -z "$REV" ]] && die "--overlay requires --rev"
[[ -z "$OVERLAY" && -z "$OUT_DIR" ]] && { usage; exit 1; }

command -v cargo >/dev/null || die "cargo not found"
command -v zip   >/dev/null || die "zip not found"

# --- name the artifact the way PatchArtifact.storageUrl does -------------------
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in
            arm64) PLAT=darwin-arm64 ;;
            x86_64) PLAT=darwin-x64 ;;
            *) die "unsupported macOS arch: $(uname -m)" ;;
          esac ;;
  Linux)  [[ "$(uname -m)" == "x86_64" ]] || die "only linux-x64 is packaged"
          PLAT=linux-x64 ;;
  *) die "unsupported host: $(uname -s) (Windows must be built on Windows)" ;;
esac
note "host artifact: patch-$PLAT.zip"

# --- build --------------------------------------------------------------------
BUILD_DIR="${TMPDIR:-/tmp}/selfhost-patch-build"
note "building patch (release) from vendor/updater"
CARGO_TARGET_DIR="$BUILD_DIR" cargo build --release \
  --manifest-path "$REPO_ROOT/vendor/updater/Cargo.toml" \
  -p patch --bin patch >/dev/null

BIN="$BUILD_DIR/release/patch"
[[ -x "$BIN" ]] || die "build produced no executable at $BIN"

# Sanity: the CLI invokes it as `patch <base> <new> <out>`. If the interface ever
# drifts, fail here rather than at patch-creation time on a user's machine.
# Captured into a variable rather than piped: printing usage exits non-zero, and
# under `pipefail` that would fail the check even when the text matches.
IFACE="$("$BIN" 2>&1 || true)"
grep -q 'Usage: patch <base> <new> <output>' <<<"$IFACE" \
  || die "unexpected CLI interface from the built binary: $IFACE"
note "interface check passed"

# --- package ------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$BIN" "$STAGE/patch"
chmod +x "$STAGE/patch"

DEST_DIR="${OUT_DIR:-$OVERLAY/$BUCKET/shorebird/$REV}"
mkdir -p "$DEST_DIR"
# Absolutize: the zip below is written from inside $STAGE, so a relative
# --overlay/--out path would otherwise resolve against the wrong directory.
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
ZIP="$DEST_DIR/patch-$PLAT.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -q "$ZIP" patch )   # `patch` at the zip root, as extractArtifact expects

note "wrote $ZIP ($(wc -c < "$ZIP" | tr -d ' ') bytes)"

# --- verify the round trip ----------------------------------------------------
# Producing a zip the CLI cannot unpack would fail much later and confusingly.
VERIFY="$(mktemp -d)"
unzip -q "$ZIP" -d "$VERIFY"
[[ -x "$VERIFY/patch" ]] || die "zip does not contain an executable ./patch"
UNPACKED="$("$VERIFY/patch" 2>&1 || true)"
grep -q 'Usage: patch' <<<"$UNPACKED" || die "unpacked binary does not run"
rm -rf "$VERIFY"
note "round-trip verified: unzips to a working ./patch"

if [[ -n "$OVERLAY" ]]; then
  note "installed into overlay for engine revision $REV"
  note "the CLI will fetch it when SHOREBIRD_STORAGE_BASE_URL/_BUCKET point at this overlay"
fi
