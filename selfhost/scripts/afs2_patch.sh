#!/usr/bin/env bash
# cspell:words armeabi bidiff reqs vmcode hashlib hexdigest namelist
# ANDROID-FINAL-STACK-2 stage B: an ordinary Android code patch against the
# release built on the new cell.
#
# The ORDINARY producer and nothing else: no Route B (that is iOS-only), no
# hand-built artifacts, no manifest injection. Android patching is bidiff, and
# the point of this stage is that the ordinary path is what runs.
set -uo pipefail
REPO=/Users/mendell/shorebird
source /Volumes/build/route-b/afs2/control.env
SB="$CLI/bin/shorebird"
APK=${APK:?}
BASE="http://localhost:$PORT"
ORIGIN="http://127.0.0.1:$OPORT"
CHECKS_ONLY=0
[[ "${1:-}" == "--checks-only" ]] && CHECKS_ONLY=1
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

step "7b. the release record and the APK are the SAME artifact"
# A precondition, not a nicety. `shorebird patch` diffs against the release the
# CONTROL PLANE holds; the device runs the APK. If those two disagree the patch
# is computed against something other than what is installed, and every later
# observation is about the wrong pair. The binding is checkable: each release
# artifact's recorded hash must equal the sha256 of the corresponding libapp.so
# inside the APK.
python3 - "$WORK/release_artifacts.json" "$APK" <<'PY2'
import hashlib, json, sys, zipfile
arts = json.load(open(sys.argv[1]))
arts = arts.get('artifacts', arts if isinstance(arts, list) else [])
by_arch = {a['arch']: a['hash'] for a in arts}
# The CLI's arch names for Android, mapped to the APK's ABI directories.
pairs = [('arm', 'armeabi-v7a'), ('aarch64', 'arm64-v8a'), ('x86_64', 'x86_64')]
bad = 0
with zipfile.ZipFile(sys.argv[2]) as az:
    for arch, abi in pairs:
        want = by_arch.get(arch)
        entry = f'lib/{abi}/libapp.so'
        got = hashlib.sha256(az.read(entry)).hexdigest() if entry in az.namelist() else None
        state = 'MATCH' if (want and got and got.startswith(want[:32])) else 'MISMATCH'
        if state != 'MATCH':
            bad += 1
        print(f'    {arch:8} -> {abi:12} release={str(want)[:32]}  apk={str(got)[:32]}  {state}')
sys.exit(1 if bad else 0)
PY2
[[ $? -eq 0 ]] && ok "all three release artifacts are the libapp.so copies in the APK" \
               || bad "the release record and the APK disagree — the patch would target the wrong artifact"

if [[ "$CHECKS_ONLY" == 1 ]]; then
  echo; echo "  (checks only: the source edit and the patch invocation are skipped,"
  echo "   so this cannot publish a second patch)"
else

step "8. one line changes, inside the never-inline function"
python3 - "$APP/lib/main.dart" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert "'AFS2-V1-RELEASE'" in s, 'marker not found'
s = s.replace("'AFS2-V1-RELEASE'", "'AFS2-V2-PATCHED'")
s = s.replace("'AFS2-V1-RELEASE!'", "'AFS2-V2-PATCHED!'")
open(p, 'w').write(s)
print('    marker now AFS2-V2-PATCHED')
PY
grep -q "AFS2-V2-PATCHED" "$APP/lib/main.dart" && ok "the source now carries the patched marker" \
                                               || bad "the edit did not land"
grep -q "AFS2-V1-RELEASE" "$APP/lib/main.dart" && bad "the release marker is still in the source" \
                                               || ok "and the release marker is gone from the source"

step "9. shorebird patch android — the ordinary bidiff producer"
BEFORE_REQ=$(wc -l < "$WORK/requests.jsonl" 2>/dev/null || echo 0)
set +e
( cd "$APP" && SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" SHOREBIRD_HOSTED_URL="$BASE" \
  SHOREBIRD_TOKEN="$API_KEY" "$SB" patch android --release-version 1.0.0+1 --no-confirm ) \
  > "$WORK/patch.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
tail -12 "$WORK/patch.log" | sed 's/^/    | /'
[[ "$RC" == 0 ]] && ok "the patch completed" || bad "the patch exited $RC"
fi   # end of the mutating block

step "9b. THE ORDINARY PRODUCER: bidiff, not Route B and not the AOT linker"
# NOT a text grep over the build log. A first version of this control grepped
# for "route.b|aot-tools|analyze_snapshot" and reported two failures, neither
# real: the CLI unconditionally ATTEMPTS `aot-tools.dill` and warns on the 404,
# and the string `route-b` appears in this rig's own scratch PATH. A log line
# mentioning a tool is not the tool running.
#
# What actually discriminates:
#   1 aot-tools.dill was requested, 404'd, and the patch STILL SUCCEEDED, so
#     the linker cannot be load-bearing on this path;
#   2 no Route B compiler artifact was fetched at all;
#   3 the patch artifacts are DIFFS -- three orders of magnitude smaller than
#     the release artifacts they patch, which a full snapshot could not be.
python3 - "$WORK/requests.jsonl" "$CELL" <<'PY2'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
aot = [r for r in rows if r['path'].endswith('aot-tools.dill')]
rb = [r for r in rows if 'route-b-compiler' in r['path'] or 'dart2bytecode' in r['path']]
print(f"    aot-tools.dill requests: {len(aot)}  statuses: {sorted({r['status'] for r in aot})}")
print(f"    Route B compiler artifact requests: {len(rb)}")
fail = 0
if not aot:
    print('    NOTE the linker artifact was never even requested')
elif any(r['status'] == 200 for r in aot):
    print('    FAIL aot-tools.dill was SERVED — the linker may be on this path')
    fail = 1
if rb:
    print('    FAIL a Route B compiler artifact was fetched for an Android patch')
    fail = 1
sys.exit(fail)
PY2
[[ $? -eq 0 ]] && ok "the linker artifact 404'd and no Route B compiler was fetched, yet the patch succeeded" \
               || bad "a linker or Route B artifact was involved in the Android patch"

step "10. PATCH IDENTITY, as the control plane records it"
curl -fsS "$BASE/api/v1/apps/$APP_ID/releases/$REL_ID/patches" \
  -H "Authorization: Bearer $API_KEY" > "$WORK/patches.json"
python3 - "$WORK/patches.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
n = 0
for p in d['patches']:
    print(f"    patch id={p['id']} number={p['number']} status={p['status']} channel={p['channel']}")
    for a in p['artifacts']:
        n += 1
        print("      artifact %-14s %-9s %9s bytes  sha256=%s"
              % (a['arch'], a['platform'], a['size'], a['hash']))
print(f"    patch artifacts: {n}")
sys.exit(0 if n == 3 else 1)
PY
[[ $? -eq 0 ]] && ok "exactly three patch artifacts (one per shipped ABI)" \
               || bad "the patch does not carry three artifacts"
python3 - "$WORK/patches.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))['patches'][0]
sys.exit(0 if p['number'] == 1 else 1)
PY
[[ $? -eq 0 ]] && ok "it is patch number 1" || bad "the patch number is not 1"

step "10b. the patch artifacts are DIFFS, not snapshots"
python3 - "$WORK/patches.json" "$WORK/release_artifacts.json" <<'PY2'
import json, sys
pa = json.load(open(sys.argv[1]))['patches'][0]['artifacts']
ra = json.load(open(sys.argv[2]))
ra = ra.get('artifacts', ra if isinstance(ra, list) else [])
rel = {a['arch']: a['size'] for a in ra}
fail = 0
for a in pa:
    r = rel.get(a['arch'])
    if not r:
        print(f"    {a['arch']}: no release artifact to compare"); fail = 1; continue
    ratio = a['size'] / r
    verdict = 'DIFF' if ratio < 0.05 else 'NOT A DIFF'
    if verdict != 'DIFF':
        fail = 1
    print(f"    {a['arch']:8} patch {a['size']:>8} vs release {r:>9}  = {ratio:.3%}  {verdict}")
sys.exit(fail)
PY2
[[ $? -eq 0 ]] && ok "each patch artifact is well under 5% of the release artifact it patches" \
               || bad "a patch artifact is snapshot-sized, not diff-sized"

step "11. no identity-bearing artifact was fallback-served"
# In --checks-only there is no patch invocation, so there is no "during the
# patch" window; the scan then covers the WHOLE session, which is a strictly
# stronger claim and is labelled as such rather than silently reinterpreted.
if [[ "${BEFORE_REQ:-}" == "" ]]; then
  BEFORE_REQ=0
  echo "    scope: every artifact request in this session (checks-only run)"
else
  echo "    scope: requests made during the patch build"
fi
# The patch reuses the release's toolchain from the warm cache. If it had gone
# back to the network for an identity-bearing member, that would be a second
# provenance question and this lane would need to answer it.
AFTER_REQ=$(wc -l < "$WORK/requests.jsonl")
echo "    artifact requests during the patch: $((AFTER_REQ - BEFORE_REQ))"
python3 - "$WORK/requests.jsonl" "$BEFORE_REQ" "$CELL" <<'PY'
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
new = rows[int(sys.argv[2]):]
cell = sys.argv[3]
ident = [r for r in new
         if re.search(r'android-(arm|arm64|x64)-release/|download\.flutter\.io', r['path'])]
for r in new:
    print(f"      {r['status']} {r['path'][:100]}")
print(f"    identity-bearing artifact requests during the patch: {len(ident)}")
for r in ident:
    if r['redirects']:
        print(f"      FALLBACK-SERVED {r['path']}")
sys.exit(1 if any(r['redirects'] for r in ident) else 0)
PY
[[ $? -eq 0 ]] && ok "no identity-bearing artifact was fallback-served during the patch" \
               || bad "an identity member was fallback-served during the patch"

step "12. the audit trail"
curl -fsS "$BASE/admin/audit?limit=60" -H "Authorization: Bearer $API_KEY" > "$WORK/audit.json"
python3 - "$WORK/audit.json" <<'PY'
import json, sys
ev = json.load(open(sys.argv[1]))['events']
for e in ev:
    print('    %-28s %-8s %-4s patch=%-4s' % (e['operation'], e['result'],
                                              e['http_status'], e['patch_number']))
refused = [e for e in ev if e['result'] != 'success']
print(f"    events: {len(ev)}   non-success: {len(refused)}")
PY

step "RESULT"
if [[ $fail -eq 0 ]]; then echo "  STAGE B PASSED"; else echo "  STAGE B: $fail FAILURE(S)"; exit 1; fi
