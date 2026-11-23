# Builds evidence/ from logs/: logcat excerpts, CLI verdict excerpts, origin summary, server request counts. Home paths -> ~, sig redacted.
. "$(dirname "$0")/../env.sh"
cd $R; E=$R/evidence; mkdir -p $E
red() { sed -E "s#/Users/mendel#~#g; s#(sig=)[A-Za-z0-9_%.-]+#\1REDACTED#g; s#(\"sig\":\")[^\"]+#\1REDACTED#g; s#(Bearer )[A-Za-z0-9_.-]+#\1REDACTED#g"; }
for f in logs/*.txt; do b=$(basename $f .txt); case $b in patch_numbers|syslog) continue;; esac
  { echo "# $b: $(cat logs/$b.pid 2>/dev/null)"; grep -aE 'flutter :|shape:|AndroidRuntime|FATAL|Fatal' $f | grep -av 'avc:' | sed -E 's/^([0-9-]+ [0-9:.]+) +[0-9]+ +[0-9]+ /\1 /' ; } | red > $E/logcat_$b.txt; done
for f in logs/patch_*.log; do b=$(basename $f .log)
  grep -aE "Published Patch|carrying|refus|Refus|cannot|Nothing was uploaded|Platform:|^  package:|dart: method|SDK|Iterable|exit|Creating artifact|Uploading|Error|error:|Could not|\[ERR\]|\[WARN\]" $f | grep -av "^\[        \]" | cut -c1-300 | head -40 | red > $E/cli_$b.txt; done
for f in release rollback1; do [ -f logs/$f.log ] && { grep -aE "WARN|ERR|Published|Release|engine|revision|Platform|Rolled|rolled|Patch" logs/$f.log | cut -c1-300 | head -40 | red > $E/cli_$f.txt; }; done
cp logs/origin.jsonl $E/artifact_origin.jsonl 2>/dev/null
python3 -I - <<'PY' > $E/artifact_origin_summary.txt
import json,re,collections
rows=[json.loads(l) for l in open('logs/origin.jsonl')]
print('requests',len(rows)); c=collections.Counter(r['status'] for r in rows); print('status',dict(c))
print('redirects',sum(len(r['redirects']) for r in rows))
print('final hosts',collections.Counter(re.sub(r'^(https?://[^/]+).*',r'\1',r['final_url']) for r in rows))
cell=[r for r in rows if 'f2458551' in r['path'] or '09c6f422' in r['path']]
print('paths naming cell f2458551 or engine 09c6f422:',len(cell))
fb=[r for r in rows if 'f0a7d291' in r['path']]; print('paths naming fallback f0a7d291:',len(fb))
print('X-Overlay',collections.Counter(r.get('x_overlay') for r in rows))
print('X-Engine-Hash',collections.Counter(r.get('x_engine_hash') for r in rows))
print('bytes 200',sum(r['bytes'] for r in rows if r['status']==200))
other=[r['path'] for r in rows if not('f2458551' in r['path'] or '09c6f422' in r['path'])]
print('requests not naming the cell/engine (%d):'%len(other))
for p in sorted(set(other)): print('  ',p[:150])
print('non-200:'); 
for r in rows:
  if r['status']!=200: print('  ',r['status'],r['path'][:140])
PY
python3 -I - <<'PY' | red > $E/server_requests.txt
import re,collections
c=collections.Counter(); st=collections.Counter(); n=0
for l in open('logs/server.log',errors='replace'):
    m=re.match(r'^(GET|POST|PUT|PATCH|DELETE|HEAD) (\S+) -> (\d+) ',l)
    if not m: continue
    n+=1; p=re.sub(r'[0-9a-f]{8}-[0-9a-f-]{27}','<id>',m.group(2)); p=re.sub(r'\?.*','',p); p=re.sub(r'/(releases|patches)/\d+',r'/\1/<n>',p)
    c[(m.group(1),p,m.group(3))]+=1; st[m.group(3)[0]+'xx']+=1
print('total requests',n,dict(st))
for k,v in sorted(c.items(),key=lambda x:str(x[0])): print(v,*k)
PY
grep -ac . logs/server.log | sed 's/^/server.log lines: /' >> $E/server_requests.txt
cp logs/bootstrap.log $E/bootstrap.log 2>/dev/null; red < logs/bootstrap.log > $E/bootstrap.log
for f in up.out release.out steps.out go.out up_b.out steps_b.out go_b.out; do [ -f logs/$f ] && red < logs/$f | cut -c1-400 > $E/$f; done
red < logs/connproxy.jsonl > $E/connproxy.jsonl 2>/dev/null
$ADB -s $DEV shell dumpsys package $PKG | grep -E "versionName|versionCode|firstInstallTime|lastUpdateTime|targetSdk|allowBackup|usesCleartext" | head -8 > $E/install_info.txt
for p in ro.product.model ro.build.version.release ro.build.fingerprint; do echo "$p=$($ADB -s $DEV shell getprop $p)"; done >> $E/install_info.txt
echo "apk sha256 $(shasum -a 256 release.apk | cut -d' ' -f1)" >> $E/install_info.txt
ls -l release.apk | awk '{print "apk bytes",$5}' >> $E/install_info.txt
echo COLLECT_DONE
