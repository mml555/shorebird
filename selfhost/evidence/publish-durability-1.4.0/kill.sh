#!/bin/bash
# kill.sh NAME PORT SECONDS_BEFORE_KILL KILLS : kill -9 the server mid-run, restart, drive continues
set -u
N=$1; P=$2; T=$3; K=$4
cd ~/vanish-repro
docker rm -f vanish-repro-$N >/dev/null 2>&1
docker run -d --name vanish-repro-$N -p $P:8080 -v vanish-repro-$N-data:/data -e DATA_DIR=/data -e API_KEY=sb_api_repro_$N -e URL_SIGNING_SECRET=$(openssl rand -hex 32) \
 -e PUBLIC_BASE_URL=http://10.0.0.41:$P -e SHOREBIRD_JWT_ISSUER=http://10.0.0.41:$P -e RATE_LIMIT_PER_MINUTE=1000000 -e RATE_LIMIT_IP_PER_MINUTE=1000000 -e TRUSTED_PROXIES=127.0.0.1 \
 ghcr.io/mml555/code-push-server:1.4.0 >/dev/null
until curl -sf localhost:$P/healthz >/dev/null; do sleep 1; done
python3 drive.py http://127.0.0.1:$P sb_api_repro_$N out-$N.json 10 8 interrupt > drv-$N.txt 2>&1 &
D=$!
for i in $(seq 1 $K); do sleep $T; docker kill vanish-repro-$N >/dev/null; sleep 1; docker start vanish-repro-$N >/dev/null; done
wait $D
cat drv-$N.txt
docker kill vanish-repro-$N >/dev/null 2>&1   # final unclean stop before reading
rm -rf db-$N; mkdir db-$N; docker cp vanish-repro-$N:/data/. db-$N/
python3 verify.py out-$N.json db-$N
