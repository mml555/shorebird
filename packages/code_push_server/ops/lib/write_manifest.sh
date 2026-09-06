#!/bin/sh
# Emit /data/MANIFEST.json describing the single-profile data volume.
# POSIX sh, busybox-compatible: this runs inside a throwaway busybox container
# with the deployment's volume mounted at /data and the server stopped.
#
# Every regular file is listed with its sha256, which is what lets a restore
# detect a truncated, partial or edited archive BEFORE it destroys the copy the
# operator still has.
#
# `code_push.db-shm` is excluded on purpose: it is machine-local shared memory
# that SQLite recreates on open, and shipping a stale one beside a live `-wal`
# is a hazard rather than a backup. `-wal` IS included; it holds committed data.
set -e
BID=${BID:?}; STAMP=${STAMP:?}
# The image the deployment was running. A backup and a server binary are only
# a matched pair if the binary implements the schema the backup carries:
# restoring a pre-upgrade backup with the NEW image still selected does not
# roll anything back, it silently migrates the restored database straight
# forward again and reports success. Measured 2026-09-06.
IMAGE=${IMAGE:-unknown}; IMAGE_ID=${IMAGE_ID:-unknown}
cd /data
rm -f MANIFEST.json
OUT=/tmp/m.json
{
  echo '{'
  echo "  \"format\": \"cps-backup/1\","
  echo "  \"backup_id\": \"$BID\","
  echo "  \"created_at\": \"$STAMP\","
  echo "  \"profile\": \"single\","
  echo "  \"db_engine\": \"sqlite\","
  echo "  \"object_store\": \"files\","
  echo "  \"server_image\": \"$IMAGE\","
  echo "  \"server_image_id\": \"$IMAGE_ID\","
  echo "  \"objects\": $(find ./artifacts -type f 2>/dev/null | wc -l | tr -d ' '),"
  echo '  "files": {'
} > "$OUT"
first=1
find . -type f ! -name 'code_push.db-shm' ! -name 'MANIFEST.json' | sort | while read -r f; do
  h=$(sha256sum "$f" | cut -d' ' -f1)
  if [ "$first" -eq 1 ]; then first=0; else printf ',\n' >> "$OUT"; fi
  printf '    "%s": "%s"' "$f" "$h" >> "$OUT"
done
printf '\n  }\n}\n' >> "$OUT"
cp "$OUT" /data/MANIFEST.json
