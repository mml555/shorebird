#!/usr/bin/env bash
# cspell:words dwarfdump
#
# preserve_release_evidence.sh -- copy a release's own bytes aside, BEFORE any
# patch build can overwrite them.
#
# WHY THIS EXISTS. `assert_installed_release.sh` compares an `.app` against the
# release a patch targets, and its header already says to run it before the patch
# build because `shorebird patch ios` re-archives over
# `build/ios/archive/Runner.xcarchive`. That instruction is followed and the
# evidence is still lost: the FIRST patch overwrites the archive, so the second
# and later patches against the same release have nothing release-owned left to
# compare with.
#
# That is exactly what happened on release 24. Identity was verified at install
# time and every later launch used `--noinstall`, so the claim "the device is
# running release 24" was sound — but it had become an ARGUMENT rather than a
# measurement, and an argument cannot be re-checked by whoever reads the result
# later.
#
# So: at install time, copy the artifact aside and record its LC_UUID. Every
# later patch re-runs the comparison against these bytes instead of against
# whatever the working tree now holds.
#
#   preserve_release_evidence.sh <release-version> <path/to/Runner.app|.xcarchive>
#
# Writes, under selfhost/evidence/releases/<version>/:
#   App          the App.framework binary — the bytes the build id is read from
#   LC_UUID      that binary's LC_UUID, lowercased and dash-stripped
#   RECORDED     when, from where, and the patchability measurement
set -euo pipefail

VERSION=${1:?usage: preserve_release_evidence.sh <release-version> <Runner.app|.xcarchive>}
TARGET=${2:?need the .app or .xcarchive to preserve}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
OUT=${OUT:-$SELFHOST/evidence/releases/$VERSION}

die() { echo "ERROR: $*" >&2; exit 1; }

# Accept whichever level of the bundle the caller happens to have, same as
# verify_patchable_release.sh does.
APP=$TARGET
case "$TARGET" in
  *.xcarchive) APP="$TARGET/Products/Applications/Runner.app" ;;
esac
BIN="$APP/Frameworks/App.framework/App"
[ -f "$BIN" ] || die "no App binary at $BIN"

# REFUSE TO OVERWRITE. The point of this directory is that it is immutable: a
# second release cut under the same version, or a patch build re-running this by
# accident, must not silently replace the bytes a later comparison depends on.
if [ -e "$OUT/LC_UUID" ]; then
  existing=$(tr -d '\n' < "$OUT/LC_UUID")
  incoming=$(dwarfdump --uuid "$BIN" | sed -n 's/^UUID: \([0-9A-Fa-f-]*\).*/\1/p' \
    | tr -d '-' | tr '[:upper:]' '[:lower:]')
  [ "$existing" = "$incoming" ] || die \
    "$OUT already holds evidence for a DIFFERENT binary ($existing, incoming $incoming). Refusing to overwrite; move it aside deliberately."
  echo "already preserved: $VERSION -> $existing"
  exit 0
fi

mkdir -p "$OUT"
cp "$BIN" "$OUT/App"
UUID=$(dwarfdump --uuid "$OUT/App" | sed -n 's/^UUID: \([0-9A-Fa-f-]*\).*/\1/p' \
  | tr -d '-' | tr '[:upper:]' '[:lower:]')
[ -n "$UUID" ] || die "could not read an LC_UUID from the preserved binary"
printf '%s\n' "$UUID" > "$OUT/LC_UUID"

# Patchability travels WITH the identity, because interpreting a device result
# needs both and they were separated once already — a release that was never
# patchable produced four runs of `applied 1/1 targets` and no behaviour change.
PATCHABLE="not measured"
if [ -x "$HERE/../verify_patchable_release.sh" ]; then
  PATCHABLE=$("$HERE/../verify_patchable_release.sh" "$APP" 2>&1 \
    | sed -n 's/^patchable sites *: //p' | head -1)
  PATCHABLE=${PATCHABLE:-"measurement failed"}
fi

cat > "$OUT/RECORDED" <<EOF
release        : $VERSION
preserved from : $BIN
preserved at   : $(date -u +%FT%TZ)
LC_UUID        : $UUID
patchable      : $PATCHABLE
size           : $(wc -c < "$OUT/App" | tr -d ' ') bytes

These are the RELEASE's own bytes. Compare later patches against them:

  assert_installed_release.sh <app-or-archive> --expect $UUID

The working archive is NOT a substitute: \`shorebird patch ios\` re-archives over
build/ios/archive, so after the first patch it holds the patch build instead.
EOF

echo "preserved release $VERSION"
echo "  LC_UUID   : $UUID"
echo "  patchable : $PATCHABLE"
echo "  at        : $OUT"
