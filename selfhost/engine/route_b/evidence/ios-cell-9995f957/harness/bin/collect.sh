# Builds evidence/ from logs/: per-launch syslog excerpts, CLI excerpts with original line numbers, origin and server
# summaries. Home paths -> ~, signed-URL sig and bearer tokens redacted. No keys (this run is unsigned).
# cspell:words NUMS
. "$(dirname "$0")/../env.sh"
cd $R; E=$R/evidence; rm -rf $E; mkdir -p $E/harness/bin $E/screenshots
red() { sed -E "s#$HOME#~#g; s#a\.k\.a\. '[^']*'#a.k.a. '<device name>'#g; s#(sig=)[A-Za-z0-9_%.-]+#\1REDACTED#g; s#(\"sig\":\")[^\"]+#\1REDACTED#g; s#(Bearer )[A-Za-z0-9_.-]+#\1REDACTED#g"; }
for f in logs/*.dbg; do b=$(basename $f .dbg); red < logs/$b.txt > $E/$b.log; done
for f in logs/patch_*.log; do b=$(basename $f .log); n=$(wc -l < $f | tr -d ' ')
  { echo "## $b.log ($n lines; excerpt with original line numbers)"
    grep -naE '\[route-b\]|Published Patch|Not publishing|cannot be built|cannot yet|never used|it calls|it uses|A `Future` value|whole patch|Nothing was|^  package:|Platform:|\[ERR\]|\[WARN\]|Exited with code|exiting with code' $f \
      | grep -avE '^[0-9]+:\[ +\+?[0-9]+ ms\] (executing|Exit code|<-|->)' | cut -c1-1200; } | red > $E/${b}_cli.txt; done
for f in release rollback; do grep -naE '\[WARN\]|\[ERR\]|Published|Route B retention|untabled_overrides|Platform:|[Rr]olled|patchable call sites' logs/$f.log | grep -avE 'executing|Process|Exit code|Artifact Instance|export ' | cut -c1-300 | head -40 | red > $E/${f}_cli.txt; done
for f in steps254 go up down release; do [ -f logs/$f.out ] && red < logs/$f.out > $E/$f.out; done
for f in install.txt analyze.log bootstrap.log patch_numbers.txt; do [ -f logs/$f ] && red < logs/$f > $E/$f; done
red < logs/origin.jsonl > $E/artifact_origin.jsonl; red < logs/connproxy.jsonl > $E/outbound_connect.jsonl
python3 -I - logs/server.log <<'PY' | red > $E/server_requests.log
import re,sys
for p in sys.argv[1:]:
    L=open(p,errors='replace').read().splitlines()
    print(f'# code_push_server request lines from {p} ({len(L)} lines); request bodies and signed-URL query strings are not kept.')
    for l in L:
        m=re.match(r'^(GET|POST|PUT|PATCH|DELETE|HEAD) (\S+) (-> .*)$',l)
        if m: print(m.group(1), re.sub(r'\?.*','',m.group(2)), m.group(3))
PY
for f in bin/*.sh bin/*.py; do red < $f > $E/harness/$f; done; red < env.sh > $E/harness/env.sh
cp shapes/main.dart shapes/variants.py $E/
for s in p05_boot_8; do [ -f shots/$s.png ] && sips -Z 700 shots/$s.png --out $E/screenshots/$s.png >/dev/null; done
grep -rlE "PRIVATE KEY|$HOME|API_KEY=[^"$]|URL_SIGNING_SECRET=[^"$]" $E && echo "LEAK CHECK FAILED" || echo "leak check ok"
du -sh $E
