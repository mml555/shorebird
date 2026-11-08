#!/usr/bin/env bash
# cspell:words objkey unservable OBJF
# BACKUP-RESTORE-1: decide whether a backup's two halves describe a state the
# live system could ever have been in.
#
# "The DB and the objects disagree" is NOT the right predicate, and using it
# produced a false finding in this lane. An artifact is written in a fixed
# order (api.dart `_upload`):
#
#   INSERT row status=pending   (no object)
#   status := uploading         (no object)
#   store.put(key, bytes)       (object appears, row still `uploading`)
#   status := verified          (object present)
#
# So a row that says `pending` with no object on disk is a FAITHFUL capture of
# an upload that was genuinely in flight -- the live system looks exactly like
# that, and a backup that records it is correct. Only the combinations the
# live system can never occupy are evidence of a torn backup:
#
#   TEAR-1  object present, no row at all        (the row always precedes bytes)
#   TEAR-2  object present, row says `pending`   (put happens only after `uploading`)
#   TEAR-3  row says `verified`, object absent   (verified only follows a successful put)
#
# Inputs: a file of "<storage_key> <status>" lines and a file of object keys.
set -uo pipefail
DBF=${1:?db keys file}; OBJF=${2:?object keys file}
t1=0; t2=0; t3=0; faithful=0
cut -d' ' -f1 "$DBF" | sort > /tmp/brt_db.$$
while IFS=' ' read -r k st; do
  [[ -z "$k" ]] && continue
  if grep -qxF "$k" "$OBJF"; then
    case "$st" in
      pending) t2=$((t2+1)); echo "  TEAR-2 object present but row is pending: $k";;
    esac
  else
    case "$st" in
      verified) t3=$((t3+1)); echo "  TEAR-3 row verified but object absent: $k";;
      pending|uploading) faithful=$((faithful+1));;
    esac
  fi
done < "$DBF"
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  grep -qxF "$k" /tmp/brt_db.$$ || { t1=$((t1+1)); echo "  TEAR-1 object with no row: $k"; }
done < "$OBJF"
rm -f /tmp/brt_db.$$
echo "  TEARS=$((t1+t2+t3))  (T1=$t1 T2=$t2 T3=$t3)   faithful-in-flight=$faithful   rows=$(grep -c . "$DBF") objects=$(grep -c . "$OBJF")"
exit $(( (t1+t2+t3) > 0 ? 1 : 0 ))
