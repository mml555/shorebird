#!/usr/bin/env bash
# Shadow dirs for the D-DEMAND-3 fresh replay: everything symlinks to the
# D-DEMAND-1 dir except pairs -> pairs13 and producer -> producer14. Same
# device as shadow13.sh, so the FROZEN accounting code runs unmodified.
set -euo pipefail
for app in wonderous localsend; do
  SRC=/Volumes/build/route-b/demand1/$app
  DST=/Volumes/build/route-b/demand1/d3/$app
  rm -rf "$DST"; mkdir -p "$DST"
  for e in "$SRC"/*; do
    b=$(basename "$e")
    case "$b" in pairs|producer|pairs13|producer13|producer14) continue ;;
      *) ln -s "$e" "$DST/$b" ;; esac
  done
  ln -s "$SRC/pairs13"     "$DST/pairs"
  ln -s "$SRC/producer14"  "$DST/producer"
done
