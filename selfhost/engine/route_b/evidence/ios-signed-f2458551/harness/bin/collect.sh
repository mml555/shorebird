# Builds evidence/ from logs/: per-launch syslog excerpts, CLI excerpts with line numbers, origin and server summaries,
# signature verdicts. Home paths -> ~, signed-URL sig and bearer tokens redacted. Private keys are never copied.
# cspell:words NUMS
. "$(dirname "$0")/../env.sh"
cd $R; E=$R/evidence; rm -rf $E; mkdir -p $E/harness/bin $E/screenshots
red() { sed -E "s#~#~#g; s#a\.k\.a\. '[^']*'#a.k.a. '<device name>'#g; s#(sig=)[A-Za-z0-9_%.-]+#\1REDACTED#g; s#(\"sig\":\")[^\"]+#\1REDACTED#g; s#(Bearer )[A-Za-z0-9_.-]+#\1REDACTED#g"; }
for f in logs/*.dbg; do b=$(basename $f .dbg); red < logs/$b.txt > $E/$b.log; done
for f in logs/patch_*.log; do b=$(basename $f .log); n=$(wc -l < $f | tr -d ' ')
  { echo "## $b.log ($n lines; excerpt with original line numbers)"
    grep -naE '\[route-b\]|Published Patch|Not publishing|Changed files|^ +[A-Za-z]+/.*shorebird.yaml|file\(s\) changed|asset changes|allow-asset-diffs|signed with|[Ss]ignature|public key|Platform:|refus|Refus|\[ERR\]|\[WARN\]|Exited with code|exiting with code' $f \
      | grep -avE '^[0-9]+:\[ +\+?[0-9]+ ms\] (executing|Exit code|<-|->)' | cut -c1-300; } | red > $E/${b}_cli.txt; done
for f in release rollback; do grep -naE '\[WARN\]|\[ERR\]|Published|COHERENT|Patch Signing|patch_public_key|public key|Platform:|[Rr]olled|patchable call sites' logs/$f.log | grep -avE 'executing|Process|Exit code|Artifact Instance|export ' | cut -c1-300 | head -40 | red > $E/${f}_cli.txt; done
for f in steps steps_b go go_b up up_b down down_b release; do [ -f logs/$f.out ] && red < logs/$f.out > $E/$f.out; done
for f in install.txt analyze.log bootstrap.log patch_numbers.txt; do red < logs/$f > $E/$f; done
red < logs/origin.jsonl > $E/artifact_origin.jsonl; red < logs/connproxy.jsonl > $E/outbound_connect.jsonl
python3 -I - logs/server_a.log logs/server.log <<'PY' | red > $E/server_requests.log
import re,sys
for p in sys.argv[1:]:
    L=open(p,errors='replace').read().splitlines()
    print(f'# code_push_server request lines from {p} ({len(L)} lines; session {"1" if "server_a" in p else "2"}); request bodies and signed-URL query strings are not kept.')
    for l in L:
        m=re.match(r'^(GET|POST|PUT|PATCH|DELETE|HEAD) (\S+) (-> .*)$',l)
        if m: print(m.group(1), re.sub(r'\?.*','',m.group(2)), m.group(3))
PY
{ echo "# Every signature line from the device launches, and each CLI refusal, verbatim (home paths -> ~)."
  for f in logs/*.dbg; do b=$(basename $f .dbg); grep -aE 'ignature|known bad|Update failed' logs/$b.txt | sed -E "s/^.*<(Notice|Fault|Error)>: /$b: /"; done
  for b in neg_unsigned neg_keyb neg_mismatch neg_keyb_forced; do echo "== patch_$b.log ($(grep -a "patch $b exit=" logs/steps*.out | sed 's/.*exit=/exit /'))"; grep -aE 'Not publishing|signed with your own key|Signature verification|public key|shorebird.yaml$|allow-asset-diffs|Published Patch|asset changes' logs/patch_$b.log | grep -av executing | head -8; done; } | red > $E/signing_verdicts.txt
{ echo '# SHA-256 of each public key, SPKI DER (openssl pkey -pubin -outform DER).'; for k in a b; do printf '%s ' $k; openssl pkey -pubin -in keys/${k}_public.pem -outform DER 2>/dev/null | shasum -a 256 | cut -d' ' -f1; done; } > $E/key_fingerprints.txt
cp keys/a_public.pem keys/b_public.pem $E/
for f in bin/*.sh bin/*.py; do red < $f > $E/harness/$f; done; red < env.sh > $E/harness/env.sh
for s in trio_boot_8 combo_boot_8 combo2_boot_8; do [ -f shots/$s.png ] && sips -Z 700 shots/$s.png --out $E/screenshots/$s.png >/dev/null; done
grep -rlE 'PRIVATE KEY|~' --exclude=collect.sh $E && echo "LEAK CHECK FAILED" || echo "leak check ok"
du -sh $E
