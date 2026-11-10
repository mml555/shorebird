#!/bin/bash
# run.sh NAME PORT MODE PER WORKERS "EXTRA DOCKER ARGS"  (runs on ci-build)
set -u
N=$1; P=$2; MODE=$3; PER=$4; W=$5; EXTRA=${6:-}
cd ~/vanish-repro
docker rm -f vanish-repro-$N >/dev/null 2>&1
docker run -d --name vanish-repro-$N -p $P:8080 $EXTRA -e DATA_DIR=/data -e API_KEY=sb_api_repro_$N -e URL_SIGNING_SECRET=$(openssl rand -hex 32) \
 -e PUBLIC_BASE_URL=http://10.0.0.41:$P -e SHOREBIRD_JWT_ISSUER=http://10.0.0.41:$P -e RATE_LIMIT_PER_MINUTE=1000000 -e RATE_LIMIT_IP_PER_MINUTE=1000000 \
 -e TRUSTED_PROXIES=127.0.0.1 -e UPLOAD_METHOD=$([ "$MODE" = resumable ] && echo resumable || echo multipart) \
 ghcr.io/mml555/code-push-server:1.4.0 >/dev/null
until curl -sf localhost:$P/healthz >/dev/null; do sleep 1; done
python3 drive.py http://127.0.0.1:$P sb_api_repro_$N out-$N.json $PER $W $MODE
rm -rf db-$N; mkdir db-$N; docker cp vanish-repro-$N:/data/. db-$N/ 
python3 verify.py out-$N.json db-$N
echo "5xx in log: $(docker logs vanish-repro-$N 2>&1 | grep -c -- '-> 5[0-9][0-9]')  unhandled: $(docker logs vanish-repro-$N 2>&1 | grep -ci 'unhandled request error')"
