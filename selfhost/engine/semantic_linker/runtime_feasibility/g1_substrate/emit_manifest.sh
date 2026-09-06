#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker
# emit_manifest.sh -- SEMANTIC-LINKER-1 / G1. Record every build input and
# artifact of the matched pair, and re-check that the SUPPORTED producer tree is
# still exactly where G0 froze it.
#
# The last check is not ceremony. This lane cloned 21 GB out of the tree that
# holds the supported cell's own bytes, and "I did not touch it" is a claim like
# any other -- it gets read back off the disk.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
FREEZE="$REPO/selfhost/engine/semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
PRODUCER=${PRODUCER:-/Volumes/build/route-b/flutter}
OVERLAY=${OVERLAY:-$REPO/selfhost/cdn/overlay}
OUT="$HERE/g1_manifest.json"

python3 - "$FREEZE" "$SRC" "$PRODUCER" "$OVERLAY" "$HERE" "$OUT" <<'PY'
import hashlib, json, os, subprocess, sys, datetime
freeze, src, producer, overlay, here, out = sys.argv[1:7]
F = json.load(open(freeze))

def sha(p):
    if not os.path.isfile(p): return None
    h = hashlib.sha256()
    with open(p,'rb') as f:
        for c in iter(lambda: f.read(1<<20), b''): h.update(c)
    return h.hexdigest()

def git(repo,*a):
    try: return subprocess.check_output(['git','-C',repo,*a],stderr=subprocess.DEVNULL).decode().strip()
    except Exception: return None

def eff_tree(repo, path):
    idx = '/tmp/.sl1idx'
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    try:
        os.path.exists(idx) and os.remove(idx)
        subprocess.check_call(['git','-C',repo,'read-tree','HEAD'],env=env,stderr=subprocess.DEVNULL)
        subprocess.check_call(['git','-C',repo,'add','--',path],env=env,stderr=subprocess.DEVNULL)
        return subprocess.check_output(['git','-C',repo,'write-tree'],env=env).decode().strip()
    except Exception: return None
    finally:
        os.path.exists(idx) and os.remove(idx)

dart_dirty = F['producing_source']['dart']['dirty_paths'][0]
ARTIFACTS = ['gen_snapshot','dartaotruntime','dart','vm_platform.dill','dart-sdk/bin/dart']

arms = {}
for arm in ('dm_off','dm_on'):
    d = os.path.join(src,'out','sl1_'+arm)
    args = open(os.path.join(d,'args.gn')).read().splitlines() if os.path.isfile(os.path.join(d,'args.gn')) else []
    arms[arm] = {
        'out_dir': d,
        'dart_dynamic_modules': any(l.startswith('dart_dynamic_modules') for l in args),
        'args_gn_sha256': sha(os.path.join(d,'args.gn')),
        'args_gn_lines': len(args),
        'artifacts': {a: {'sha256': sha(os.path.join(d,a)),
                          'bytes': os.path.getsize(os.path.join(d,a)) if os.path.isfile(os.path.join(d,a)) else None}
                      for a in ARTIFACTS},
    }

# WHICH SHIPPED CELL MEMBERS THIS REBUILD REPRODUCES. Stated per member, because
# "the cell reproduces" would be false and "nothing reproduces" is no longer
# true either. Only members this build actually produces are compared.
import zipfile, tempfile
cell = F['cell']['address']
zp = os.path.join(overlay,'download.shorebird.dev','shorebird',cell,'route-b-compiler-darwin-arm64.zip')
shipped = {}
if os.path.isfile(zp):
    with zipfile.ZipFile(zp) as z, tempfile.TemporaryDirectory() as t:
        for n in ('vm_platform.dill','dartaotruntime'):
            if n in z.namelist():
                z.extract(n,t); shipped[n] = sha(os.path.join(t,n))

repro = {}
for n, s in shipped.items():
    local = arms['dm_on']['artifacts'].get(n,{}).get('sha256')
    repro[n] = {'shipped_sha256': s, 'lane_dm_on_sha256': local, 'byte_identical': (s == local and s is not None)}

dart_repo = os.path.join(src,'flutter','third_party','dart')
prod_dart = os.path.join(producer,'engine','src','flutter','third_party','dart')

m = {
  'schema': 'semantic-linker-1/g1-substrate/1',
  'gate': 'SL1-G1', 'tracker': 36, 'issue': 38,
  'built': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  'lane_source': {
    'root': src,
    'engine_revision': git(os.path.join(src,'flutter'),'rev-parse','HEAD'),
    'engine_tree': git(os.path.join(src,'flutter'),'rev-parse','HEAD^{tree}'),
    'dart_revision': git(dart_repo,'rev-parse','HEAD'),
    'dart_effective_tree': eff_tree(dart_repo, dart_dirty),
    'matches_frozen': None,
  },
  'experiment_patches': {
    'engine': [], 'dart': [],
    'note': ('EMPTY, and that is a result. The frozen lineage already registers '
             'attachBytecodeToFunction and detachBytecodeFromFunction '
             'unconditionally in bootstrap_natives.h and exposes them plus '
             'loadDynamicModule on dart:_internal, so the substrate under test '
             'needs no experiment-only source change. The killgate lane still '
             'banks 0001-attach-bytecode-native.patch because it predates that '
             'landing; it is NOT applied here.'),
  },
  'arms': arms,
  'pair_is_matched': {
    'differ_only_by': 'dart_dynamic_modules',
    'enforced_by': 'build_matched.sh refuses to build unless the two args.gn differ by exactly that one line',
    'executables_differ': {a: arms['dm_off']['artifacts'][a]['sha256'] != arms['dm_on']['artifacts'][a]['sha256']
                           for a in ARTIFACTS},
  },
  'reproduces_shipped_cell_members': repro,
  'dynamic_interface': {
    'requested': os.path.join(here,'probe','di.yaml'),
    'requested_sha256': sha(os.path.join(here,'probe','di.yaml')),
    'applied_dumps': {a: sha(os.path.join(here,'evidence','di_applied_%s.json'%a)) for a in ('dm_off','dm_on')},
  },
  'probe_sources': {n: sha(os.path.join(here,'probe',n)) for n in ('host_probe.dart','replacement.dart','di.yaml')},
  'evidence': {n: sha(os.path.join(here,'evidence',n)) for n in ('probe_dm_off.txt','probe_dm_on.txt')},
  'supported_producer_untouched': {
    'engine_tree_now': git(producer,'rev-parse','HEAD^{tree}'),
    'engine_tree_frozen': F['producing_source']['engine']['tree'],
    'dart_effective_tree_now': eff_tree(prod_dart, dart_dirty),
    'dart_effective_tree_frozen': F['producing_source']['dart']['effective_tree'],
    'cell_out_dir_present': os.path.isdir(os.path.join(producer,'engine','src','out','host_release_arm64')),
  },
}
ls = m['lane_source']
ls['matches_frozen'] = (ls['engine_tree'] == F['producing_source']['engine']['tree']
                        and ls['dart_effective_tree'] == F['producing_source']['dart']['effective_tree'])
sp = m['supported_producer_untouched']
sp['unchanged'] = (sp['engine_tree_now'] == sp['engine_tree_frozen']
                   and sp['dart_effective_tree_now'] == sp['dart_effective_tree_frozen']
                   and sp['cell_out_dir_present'])
json.dump(m, open(out,'w'), indent=2)
print(json.dumps({'lane_matches_frozen': ls['matches_frozen'],
                  'producer_unchanged': sp['unchanged'],
                  'executables_differ': m['pair_is_matched']['executables_differ'],
                  'reproduces': {k: v['byte_identical'] for k,v in repro.items()}}, indent=2))
PY
echo "wrote $OUT"
