#!/bin/bash
# cleanup.sh NAME: remove one run's container and named volume, by exact name.
N=${1:?name}; [[ $N =~ ^[a-z0-9-]+$ ]] || exit 2
docker rm -f "vanish-repro-$N" >/dev/null 2>&1 || true
docker volume rm "vanish-repro-$N-data" >/dev/null 2>&1 || true
