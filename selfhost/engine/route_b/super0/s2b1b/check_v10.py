#!/usr/bin/env python3
"""Assert the analysis-version-10 contract, clause by clause.

Every clause is a separate assertion with its own name, so a failure says which
part of the contract moved rather than "the document changed".
"""
import json, sys

doc = json.load(open(sys.argv[1]))
lowering = doc['lowering']
fail = 0


def check(label, got, want):
    global fail
    if got == want:
        print('  PASS  %-52s %s' % (label, got))
    else:
        print('  FAIL  %-52s got %r want %r' % (label, got, want))
        fail += 1


def site(target):
    for key, value in lowering.items():
        if key.endswith('#' + target):
            return value
    return None


check('analysisVersion', doc['analysisVersion'], 10)

# ---- 1. zero-argument super method ---------------------------------------
t1 = site('Child.t1')
check('t1 superInvocations count', len(t1['superInvocations']), 1)
check('t1 super member', t1['superInvocations'][0]['member'], 'dispose')
check('t1 super kind', t1['superInvocations'][0]['kind'], 'method')
check('t1 no `calls super` reason',
      [u for u in t1['unsupported'] if 'super' in u], [])
check('t1 no synthetic unconsumed-this',
      [u for u in t1['unsupported'] if 'other than to read a member' in u], [])
check('t1 unsupported is empty', t1['unsupported'], [])
# The site must carry NO arity, and no resolved target of any kind.
check('t1 super entry keys',
      sorted(t1['superInvocations'][0].keys()), ['kind', 'member', 'offset'])
check('t1 origin class', t1['origin']['class'], 'Child')
check('t1 origin member', t1['origin']['member'], 't1')
check('t1 origin memberKind', t1['origin']['memberKind'], 'Method')

# ---- 2. super WITH arguments: reported, and arity NOT claimed -------------
t2 = site('Child.t2')
check('t2 superInvocations count', len(t2['superInvocations']), 1)
check('t2 super member', t2['superInvocations'][0]['member'], 'tag')
check('t2 claims no arity',
      sorted(t2['superInvocations'][0].keys()), ['kind', 'member', 'offset'])

# ---- 3. ordinary receiver call: unchanged -------------------------------
t3 = site('Child.t3')
check('t3 receiver accesses', len(t3['accesses']), 1)
check('t3 access kind', t3['accesses'][0]['kind'], 'invoke')
check('t3 no super sites', t3['superInvocations'], [])
check('t3 unsupported is empty', t3['unsupported'], [])

# ---- 4. genuine `this` escape: unchanged refusal ------------------------
t4 = site('Child.t4')
check('t4 still refuses the escape',
      [u for u in t4['unsupported'] if 'other than to read a member' in u] != [],
      True)
check('t4 no super sites', t4['superInvocations'], [])

# ---- 5. super GETTER stays unsupported, and is NOT a superInvocation ----
t5 = site('Child.t5')
check('t5 no super sites (getter is not v1)', t5['superInvocations'], [])
check('t5 still refuses',
      [u for u in t5['unsupported'] if 'super' in u] != [], True)

# ---- 6. private super method: reported like any other -------------------
t6 = site('Child.t6')
check('t6 superInvocations count', len(t6['superInvocations']), 1)
check('t6 super member', t6['superInvocations'][0]['member'], '_hidden')
check('t6 unsupported is empty', t6['unsupported'], [])

# ---- offsets must be real source positions, not placeholders -------------
for name in ('t1', 't2', 't6'):
    entry = site('Child.' + name)['superInvocations'][0]
    check('%s offset is a real position' % name, entry['offset'] > 0, True)

print()
if fail:
    print('RESULT: %d clause(s) FAILED' % fail)
    sys.exit(1)
print('RESULT: PASS — the v10 contract holds on all six shapes.')
