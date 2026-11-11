#!/bin/bash
# run.sh NAME PORT MODE PER WORKERS [MOUNT_SUBDIR]  (on ci-build, from ~/vanish-repro)
#   MODE: plain | interrupt | resumable. MOUNT_SUBDIR: bind-mount ~/vanish-repro/<MOUNT_SUBDIR>
#   (world-writable, created here) instead of the named volume.
# Run a-d: a=run.sh a PORT plain 3 2; b1=plain 10 16; c1=interrupt 10 8 bind-c1; d1=resumable 10 8.
. "$(dirname "$0")/lib.sh"
MODE=${3:?mode}; PER=${4:?per}; W=${5:?workers}
[[ $MODE =~ ^(plain|interrupt|resumable)$ ]] || exit 2
if [[ -n ${6:-} ]]; then
  [[ $6 =~ ^[a-z0-9-]+$ ]] || exit 2
  mkdir -p "$DIR/$6" && chmod 777 "$DIR/$6"; MOUNT=$DIR/$6
fi
[[ $MODE == resumable ]] && UPLOAD_METHOD=resumable
# shellcheck disable=SC2119
start_server
python3 drive.py "http://127.0.0.1:$P" "sb_api_repro_$N" "out-$N.json" "$PER" "$W" "$MODE"
read_back
log_summary
