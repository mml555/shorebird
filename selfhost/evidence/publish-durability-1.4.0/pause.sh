#!/bin/bash
# pause.sh NAME PORT : slow server (cpus 0.3) + pause/unpause stalls during run
set -u
N=$1; P=$2
cd ~/vanish-repro
docker rm -f vanish-repro-$N >/dev/null 2>&1
docker run -d --name vanish-repro-$N -p $P:8080 --cpus 0.3 --memory 256m -v vanish-repro-$N-data:/data -e DATA_DIR=/data -e API_KEY=sb_api_repro_$N -e URL_SIGNING_SECRET=$(openssl rand -hex 32) \
 -e PUBLIC_BASE_URL=http://10.0.0.41:$P -e SHOREBIRD_JWT_ISSUER=http://10.0.0.41:$P -e RATE_LIMIT_PER_MINUTE=1000000 -e RATE_LIMIT_IP_PER_MINUTE=1000000 -e TRUSTED_PROXIES=127.0.0.1 \
 ghcr.io/mml555/code-push-server:1.4.0 >/dev/null
until curl -sf localhost:$P/healthz >/dev/null; do sleep 1; done
python3 drive.py http://127.0.0.1:$P sb_api_repro_$N out-$N.json 6 8 plain > drv-$N.txt 2>&1 &
D=$!
while kill -0 $D 2>/dev/null; do sleep 2; docker pause vanish-repro-$N >/dev/null; sleep 3; docker unpause vanish-repro-$N >/dev/null; done
cat drv-$N.txt
rm -rf db-$N; mkdir db-$N; docker cp vanish-repro-$N:/data/. db-$N/
python3 verify.py out-$N.json db-$N
