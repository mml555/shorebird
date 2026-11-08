#!/usr/bin/env bash
# cspell:words objkey RUNTAG STOPFILE writerrev
# BACKUP-RESTORE-1: a writer that exercises the control plane's real two-phase
# artifact write while a backup runs.
#
# Every operation is journalled with a UTC timestamp and a monotonic sequence
# number, so afterwards each write can be placed on either side of the
# backup's two phases (T1 pg_dump, T2 mc mirror) instead of being guessed at.
#
# Two writer shapes, because they probe different halves of the tear:
#   fast  -- register row AND upload bytes back to back (an ordinary release)
#   split -- register the row, then hold the bytes back for HOLD seconds, so
#            the row and its object can straddle the backup boundary
set -uo pipefail
BASE=${BASE:?}; KEY=${KEY:?}; APP=${APP:?}; JOURNAL=${JOURNAL:?}
SHAPE=${SHAPE:-fast}; HOLD=${HOLD:-0}; STOPFILE=${STOPFILE:?}
# `releases` has a UNIQUE (app_id, version). Without a per-run tag every rerun
# collides on the versions the previous run used, the server answers 500, and
# the writer spins doing nothing -- which is exactly what happened, silently,
# for four consecutive "clean" reproducibility runs.
RUNTAG=${RUNTAG:?set RUNTAG (unique per run)}
api(){ curl -fsS -H "Authorization: Bearer $KEY" "$@"; }
J(){ python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }
# BSD date has no %N, and it prints a literal "N" rather than failing -- which
# would have silently given every journal line the same sub-second value.
now(){ python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())'; }
log(){ printf '%s %s %s\n' "$(now)" "$1" "$2" >> "$JOURNAL"; }

n=0; ok=0; consecutive_failures=0
# A writer that cannot write is not a control, it is a hole in the experiment.
# Abort loudly rather than spin.
give_up(){ log "writer.ABORTED" "$1 (successes=$ok)"; echo "WRITER ABORTED: $1" >&2; exit 9; }
while [[ ! -f "$STOPFILE" ]]; do
  n=$((n+1))
  V="9.$n.0+${RUNTAG}$n"
  RID=$(api -X POST "$BASE/api/v1/apps/$APP/releases" -H 'Content-Type: application/json' \
        -d "{\"version\":\"$V\",\"flutter_revision\":\"writerrev\",\"display_name\":\"w$n\"}" \
        2>/dev/null | J 'print(d["release"]["id"])' 2>/dev/null)
  if [[ -z "$RID" ]]; then
    consecutive_failures=$((consecutive_failures+1))
    (( consecutive_failures >= 10 )) && give_up "10 consecutive release creations failed"
    sleep 0.2; continue
  fi
  consecutive_failures=0
  log "release.created" "seq=$n release_id=$RID version=$V"

  f=$(mktemp); { printf 'writer %s %s\n' "$n" "$(now)"; head -c 3072 /dev/urandom; } > "$f"
  sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f" | cut -d' ' -f1)
  reg=$(api -X POST "$BASE/api/v1/apps/$APP/releases/$RID/artifacts" \
        -F arch=aarch64 -F platform=android -F "hash=$sha" -F "size=$sz" 2>/dev/null) \
    || { rm -f "$f"; consecutive_failures=$((consecutive_failures+1)); (( consecutive_failures >= 10 )) && give_up "10 consecutive artifact registrations failed"; sleep 0.2; continue; }
  AID=$(printf '%s' "$reg" | J 'print(d["id"])')
  URL=$(printf '%s' "$reg" | J 'print(d["url"])')
  log "artifact.row" "seq=$n release_id=$RID artifact_id=$AID sha=$sha"

  if [[ "$SHAPE" == split && "$HOLD" != 0 ]]; then
    # The gap the two-phase write opens. A backup that snapshots the DB here
    # and the objects later captures a row whose bytes never existed at T1.
    sleep "$HOLD"
  fi
  if api -X POST -F "file=@$f" "$URL" >/dev/null 2>&1; then
    log "artifact.bytes" "seq=$n release_id=$RID artifact_id=$AID sha=$sha"; ok=$((ok+1))
  else
    log "artifact.bytes.FAILED" "seq=$n release_id=$RID artifact_id=$AID"
  fi
  rm -f "$f"
  [[ "$SHAPE" == fast ]] && sleep 0.05
done
log "writer.stopped" "attempts=$n completed=$ok"
(( ok > 0 )) || { echo "WRITER COMPLETED NOTHING" >&2; exit 9; }
