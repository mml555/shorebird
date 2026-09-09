#!/usr/bin/env python3
"""Derive every Stage A specification from G6A's di_full.yaml.

G6A derived its negatives from di_full.yaml by removing exactly one entry, so a
refusal is attributable to the mutation rather than to the harness. Everything
here follows that rule.

WHY A "COMPLETED" BASE SPECIFICATION IS NEEDED. di_full.yaml does not validate
the module. It was written for the HOST compile, where gen_kernel's
--dynamic-interface only ANNOTATES, so it never had to be complete. Handed to
dart2bytecode --validate it refuses the positive module on four counts that
have nothing to do with the negatives under test: `@override` and `@pragma`
are calls into dart:core, and `String` and `Object` are dart:core classes used
as types. Upstream's own test specification lists dart:core entries for exactly
this reason.

So di_module_full.yaml = di_full.yaml plus the smallest set of dart:core
entries that make the POSITIVE module valid, and nothing else. Each addition is
recorded with the diagnostic that demanded it. The three policy negatives are
then derived from di_module_full by removing the SAME entry G6A removed, so
they remain the historical arms rather than new ones.

di_full.yaml is kept as its own arm: "the host specification is insufficient
for module validation" is a finding this lane must bank, not hide.

usage: gen_specs.py <probe-dir> <out-dir>
"""
import hashlib
import json
import pathlib
import sys

PROBE = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
full = (PROBE / 'di_full.yaml').read_text()

CORE_ADDITIONS = [
    ('callable', "  - library: 'dart:core'\n",
     "Cannot invoke member 'override' / 'pragma.' from a dynamic module -- "
     '@override and @pragma are dart:core invocations'),
    ('can-be-used-as-type',
     "  - library: 'dart:core'\n    class: 'Object'\n"
     "  - library: 'dart:core'\n    class: 'String'\n",
     "Cannot use class 'Object' / 'String' as a type in a dynamic module -- "
     "the module's entry() returns Object? and execute() returns String"),
]


def add_to_section(text, section, addition):
    """Insert at the head of an existing section. Never appends a duplicate
    section header: two sections with the same key would make the effective
    policy depend on the YAML loader's merge behaviour."""
    marker = f'{section}:\n'
    i = text.index(marker) + len(marker)
    return text[:i] + addition + text[i:]


module_full = full
for section, addition, _why in CORE_ADDITIONS:
    module_full = add_to_section(module_full, section, addition)
module_full = ('# DERIVED from di_full.yaml: the same host policy plus the\n'
               '# smallest dart:core set that makes the POSITIVE module valid.\n'
               + module_full)
(OUT / 'di_module_full.yaml').write_text(module_full)

# The three policy negatives, each removing exactly the entry G6A removed.
REMOVALS = {
 'di_mf_no_extendable.yaml': (
   "extendable:\n  - library: 'package:dynamic_modules/n_host.dart'\n"
   "    class: 'Base'\n", 'extendable: []\n',
   "extendable: n_host.Base -- the module declares `class PatchChild extends "
   "Base`"),
 'di_mf_no_type.yaml': (
   "  - library: 'package:dynamic_modules/n_host.dart'\n    class: 'Base'\n"
   "can-be-overridden:", 'can-be-overridden:',
   'can-be-used-as-type: n_host.Base -- the module is handed back as a Base '
   'and dispatched through it. The dart:core type entries are left in place, '
   'so exactly one entry differs.'),
 'di_mf_no_overridable.yaml': (
   "can-be-overridden:\n  - library: 'package:dynamic_modules/n_host.dart'\n"
   "    class: 'Base'\n    member: 'execute'\n", 'can-be-overridden: []\n',
   'can-be-overridden: n_host.Base.execute -- the module overrides execute(). '
   'This is the arm whose historical outcome was FAIL_OPEN_SILENT_BYPASS.'),
}
removed = {}
for name, (old, new, why) in REMOVALS.items():
    if old not in module_full:
        raise SystemExit(f'{name}: the entry to remove is not present verbatim '
                         f'in di_module_full; refusing to write a '
                         f'specification whose difference is not exactly one '
                         f'entry')
    body = module_full.replace(old, new, 1)
    if body == module_full:
        raise SystemExit(f'{name}: removal changed nothing')
    (OUT / name).write_text(body)
    removed[name] = why

# One entry the module never uses. n_host.shakenAway() is absent from every
# interface and never called, so permitting it changes nothing the module needs.
(OUT / 'di_mf_plus.yaml').write_text(
    add_to_section(module_full, 'callable',
                   "  - library: 'package:dynamic_modules/n_host.dart'\n"
                   "    member: 'shakenAway'\n"))

(OUT / 'di_empty.yaml').write_text(
    '# DERIVED: a valid specification that permits nothing.\n'
    'extendable: []\ncan-be-used-as-type: []\n'
    'can-be-overridden: []\ncallable: []\n')
(OUT / 'di_broken.yaml').write_text(
    '# DERIVED: deliberately not parseable as YAML.\n'
    'extendable:\n  - library: "unterminated\n\t\tbad: [indent, {mixed:\n')

# ---- the type-exercising module, derived from m_ok by ONE addition -------
# G6A's no_type arm withdraws can-be-used-as-type for n_host.Base, but
# m_ok.dart never USES Base as a type -- it only EXTENDS it, which the
# validator governs under `extendable`. So that arm withdraws a permission the
# module does not exercise and there is nothing for the validator to refuse.
# Whether the RULE is enforced is a different question, and answering it needs
# a module that does exercise it. m_type.dart is m_ok.dart plus one type
# annotation, generated here so the difference is provably that and nothing
# more. It is a NEW arm and is reported as one: the historical arm is left
# exactly as it was.
m_ok = (PROBE / 'm_ok.dart').read_text()
OLD_RET = '  return PatchChild();\n'
NEW_RET = '  final Base b = PatchChild();\n  return b;\n'
if OLD_RET not in m_ok:
    raise SystemExit('m_ok.dart does not contain the expected return; '
                     'refusing to derive m_type.dart by guesswork')
(OUT / 'm_type.dart').write_text(
    '// DERIVED from m_ok.dart: identical except that Base is used as a TYPE,\n'
    '// so the can-be-used-as-type rule is actually exercised.\n'
    + m_ok.replace(OLD_RET, NEW_RET, 1))

manifest = {'base': {}, 'derived': {}, 'core_additions': [
    {'section': s, 'entry': a.strip(), 'demanded_by': w}
    for s, a, w in CORE_ADDITIONS], 'policy_removals': removed}
for p in sorted(PROBE.glob('di_*.yaml')):
    manifest['base'][p.name] = {
        'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
        'origin': 'inherited from SL1 G6A byte-for-byte'}
for p in sorted(list(OUT.glob('di_*.yaml')) + list(OUT.glob('m_*.dart'))):
    manifest['derived'][p.name] = {
        'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
        'origin': 'derived from di_full.yaml by gen_specs.py'}
json.dump(manifest, open(OUT / 'spec_manifest.json', 'w'), indent=2)

print('  inherited:')
for n, r in manifest['base'].items():
    print(f"    {r['sha256'][:16]}  {n}")
print('  derived:')
for n, r in manifest['derived'].items():
    print(f"    {r['sha256'][:16]}  {n}")
print('  dart:core entries added to make the POSITIVE valid:')
for a in manifest['core_additions']:
    print(f"    {a['section']}: {a['entry'][:60]}")
    print(f"      demanded by: {a['demanded_by'][:100]}")
