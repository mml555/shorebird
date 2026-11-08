#!/bin/sh
# Verify an EXTRACTED single-profile backup tree (cwd) against its own
# MANIFEST.json. Exits non-zero, with a reason, on any discrepancy.
#
# This runs while the live volume is still untouched. The restore it guards
# used to `rm -rf /data/*` first and validate never — a truncated archive left
# 303 rows with 4 objects on disk, and an archive with no database restored
# green onto a healthy server holding nothing at all.
set -e
[ -f MANIFEST.json ] || { echo "no MANIFEST.json in the archive" >&2; exit 1; }
fmt=$(sed -n 's/.*"format": "\([^"]*\)".*/\1/p' MANIFEST.json | head -1)
[ "$fmt" = "cps-backup/1" ] || { echo "unsupported manifest format: ${fmt:-<none>}" >&2; exit 1; }
[ -f ./code_push.db ] || { echo "archive contains no code_push.db" >&2; exit 1; }

sed -n 's/^    "\(.*\)": "\([0-9a-f]*\)".*/\1 \2/p' MANIFEST.json > /tmp/want.txt
want=$(wc -l < /tmp/want.txt | tr -d ' ')
[ "$want" -gt 0 ] || { echo "manifest lists no files" >&2; exit 1; }

# A `while read` pipeline runs in a subshell in POSIX sh, so failures are
# recorded in a file rather than a variable.
: > /tmp/bad.txt
while read -r f h; do
  if [ ! -f "$f" ]; then echo "MISSING $f" >> /tmp/bad.txt; continue; fi
  a=$(sha256sum "$f" | cut -d' ' -f1)
  [ "$a" = "$h" ] || echo "DIGEST MISMATCH $f" >> /tmp/bad.txt
done < /tmp/want.txt

got=$(find . -type f ! -name MANIFEST.json | wc -l | tr -d ' ')
[ "$got" = "$want" ] || echo "archive holds $got files, manifest lists $want" >> /tmp/bad.txt

if [ -s /tmp/bad.txt ]; then cat /tmp/bad.txt >&2; exit 1; fi
echo "manifest ok: $want files, $(sed -n 's/.*"objects": \([0-9]*\).*/\1/p' MANIFEST.json) objects, backup_id $(sed -n 's/.*"backup_id": "\([^"]*\)".*/\1/p' MANIFEST.json)"
