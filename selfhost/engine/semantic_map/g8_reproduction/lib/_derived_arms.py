"""The ONE definition of the per-artifact derived negative arms.

This rule lived in two places -- falsify_reproduction.py generated the arms and
check_inventory.py re-listed them to build `declared_ids` -- and the two drifted
the moment corruption arms were added: the falsifier tested 42 derived arms
while the checker still declared 21, so `inventory == tested == caught` failed
with 35 declared against 56 tested. The equality is only meaningful if both
sides read the same rule, so there is now exactly one.

TWO arms per mandatory artifact:
  -deleted    absent evidence must refuse
  -corrupted  present-but-altered evidence must refuse, which is the more
              dangerous case because it still looks like evidence
"""


def derived_arms(inventory):
    out = []
    for gate, spec in inventory['gates'].items():
        for rel in spec['artifacts']:
            name = rel.rsplit('/', 1)[-1]
            base = f'auto-{gate}-{name}'
            target = f'{gate}/{rel}'
            out.append({'id': f'{base}-deleted', 'target': target,
                        'mutation': 'delete',
                        'expect_code': 'ARTIFACT_MISSING_OR_EMPTY',
                        'derived': True})
            out.append({'id': f'{base}-corrupted', 'target': target,
                        'mutation': 'flip_middle_byte',
                        'expect_code': 'ARTIFACT_CORRUPTED',
                        'derived': True})
    return out


def derived_ids(inventory):
    return [e['id'] for e in derived_arms(inventory)]
