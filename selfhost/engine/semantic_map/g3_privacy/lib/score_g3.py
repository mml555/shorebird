#!/usr/bin/env python3
"""score_g3.py -- SEMANTIC-MAP-1 G3 (#52). Score the privacy-domain map.

WHAT THIS GATE HAS TO SHOW. The map must refuse a patch that reaches outside its
privacy domain BEFORE publication, rather than letting it fail at load. So the
policy below consumes only map rows -- no compiler, no device -- and every
adversarial arm must refuse with an ATTRIBUTABLE category, not merely refuse.

REFUSAL IS NOT THE DEFAULT. A gate whose every arm refuses proves nothing: a
policy of `return REFUSE` would pass it. The positive control is therefore a
first-class arm, and if it ever refuses the whole gate fails.
"""
import ast
import json
import pathlib
import sys

# ---------------------------------------------------------------- the policy
# One category per cause. The remedies differ, which is why they are not
# collapsed: a cross-domain reach is a patch-authoring error, a platform reach
# is refused by construction, NOT_RETAINED is fixed by re-releasing, and an
# ungranted write cannot be fixed by any release this fork has ever produced.
CROSS_DOMAIN = 'CROSS_DOMAIN_PRIVATE'
PLATFORM_DOMAIN = 'PLATFORM_DOMAIN_PRIVATE'
NOT_RETAINED = 'NOT_RETAINED'
WRITE_NOT_GRANTED = 'WRITE_NOT_GRANTED'
READ_NOT_GRANTED = 'READ_NOT_GRANTED'
CONSTRUCT_NOT_GRANTED = 'CONSTRUCT_NOT_GRANTED'
NO_SUCH_MODE = 'NO_SUCH_MODE'
ACCEPT = 'ACCEPT'


def decide(row, mode, granted, grant_scope):
    """May a patch whose grant scope is `grant_scope` access `row` in `mode`?

    `granted` is the release's capability manifest, as the set of keys it
    published. `mode` is 'read', 'write' or 'construct'.

    CONSTRUCTION IS ITS OWN MODE. The shipped manifest keeps constructibility in
    a separate list with its own key shape (`#_Boxed.new`), so a constructor is
    neither read nor written -- treating it as a read reported NO_SUCH_MODE for
    a legitimate construction of a private class.
    """
    # EFFECTIVE privacy decides, not the member's own name.
    #
    # A public method of a private class carries privacy_domain == 'public'
    # (its Name is public) with owner_is_private == True. The first version
    # gated on `is_private or owner_is_private` and then compared the MEMBER's
    # domain against the grant scope, so `'public' != 'package:its/lib.dart'`
    # and a legitimate same-library access was refused CROSS_DOMAIN_PRIVATE.
    # The corpus had no private class, so nothing exercised it.
    domain = row['effective_privacy_domain']

    # A wholly public declaration needs no private grant at all.
    if domain == 'public':
        if mode == 'write' and not row['write_mode_exists']:
            return NO_SUCH_MODE
        if mode == 'construct' and not row['construct_mode_exists']:
            return NO_SUCH_MODE
        return ACCEPT

    # 1. THE PLATFORM IS NEVER RESOLVABLE. Checked before the scope comparison
    #    so a grant that NAMES a platform library cannot launder itself by
    #    matching: `--resolve-private-names-in-library dart:core` would satisfy
    #    `domain == grant_scope` and must still be refused.
    if domain.startswith('dart:') or (grant_scope or '').startswith('dart:'):
        return PLATFORM_DOMAIN

    # 2. ONE SCOPE PER PATCH. The flag makes EVERY private name in the named
    #    library resolvable, so a body reaching a second library's private is
    #    outside what any single grant can authorise.
    if domain != grant_scope:
        return CROSS_DOMAIN

    # 3. RETAINED IS NOT THE SAME QUESTION AS PRIVATE. A tree-shaken private
    #    member is absent from the release, so no grant can make it resolvable.
    if not row['retained_in_release']:
        return NOT_RETAINED

    # 4. MODE. A write must be provably granted, and for a mutable field the
    #    manifest key cannot even express which mode it authorised -- so the
    #    write can never be proven granted, and is refused.
    if mode == 'construct':
        if not row['construct_mode_exists']:
            return NO_SUCH_MODE
        if row['capability_key_construct'] not in granted:
            return CONSTRUCT_NOT_GRANTED
        return ACCEPT

    if mode == 'write':
        if not row['write_mode_exists']:
            return NO_SUCH_MODE
        if not row['capability_key_identifies_mode']:
            return WRITE_NOT_GRANTED
        if row['capability_key_write'] not in granted:
            return WRITE_NOT_GRANTED
        return ACCEPT

    if row['capability_key_read'] is None:
        return NO_SUCH_MODE
    if row['capability_key_read'] not in granted:
        return READ_NOT_GRANTED
    return ACCEPT


def policy_return_surface():
    """Every category `decide()` can return, READ FROM ITS OWN SOURCE.

    The first version carried a hand-written set of five while `decide()` could
    return eight, so `READ_NOT_GRANTED`, `CONSTRUCT_NOT_GRANTED` and
    `NO_SUCH_MODE` were outside the exhaustion check entirely -- the newest
    category, added with the `construct` mode, was unexercised and the gate said
    every category was covered. A hand-maintained inventory is how a harness
    comes to overstate itself; this one cannot drift from the policy because it
    is derived from it.

    Fail-closed: a return the reader cannot resolve to a literal aborts rather
    than being silently dropped from the inventory.
    """
    tree = ast.parse(pathlib.Path(__file__).read_text())
    consts = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    consts[t.id] = node.value.value
    fn = next(n for n in tree.body
              if isinstance(n, ast.FunctionDef) and n.name == 'decide')
    surface = set()
    for node in ast.walk(fn):
        if isinstance(node, ast.Return) and node.value is not None:
            v = node.value
            if isinstance(v, ast.Name) and v.id in consts:
                surface.add(consts[v.id])
            elif isinstance(v, ast.Constant) and isinstance(v.value, str):
                surface.add(v.value)
            else:
                print('score_g3: decide() has a return the category inventory '
                      f'cannot resolve to a literal: {ast.dump(v)}', file=sys.stderr)
                raise SystemExit(2)
    return surface


# ---------------------------------------------------------------- the harness
def main():
    if len(sys.argv) < 4:
        print('usage: score_g3.py <work-dir> <expectations.json> <out.json>',
              file=sys.stderr)
        return 2
    work, exp_path, out_json = sys.argv[1], sys.argv[2], sys.argv[3]
    exp = json.load(open(exp_path))

    docs = {}
    for name in exp['corpora']:
        try:
            docs[name] = json.load(open(f'{work}/{name}.json'))
        except OSError:
            docs[name] = None

    lines, results, fails = [], [], 0
    extra = {}

    def arm(title):
        lines.append('')
        lines.append(f'--- {title} ---')

    def find(doc, library, owner, name, kind=None):
        for r in doc['rows']:
            if (r['library'] == library and (r['owner'] or None) == owner
                    and r['name'] == name
                    and (kind is None or r['kind'] == kind)):
                return r
        return None

    # ---- 1. the domain is derived for EVERY declaration --------------------
    arm('a privacy domain is derived for every declaration')
    base = docs.get(exp['base_corpus'])
    if base is None:
        lines.append('  FAILED  base corpus rows unavailable')
        fails += 1
    else:
        underivable = [r for r in base['rows']
                       if r['privacy_domain'].startswith('UNDERIVABLE')]
        # The derivation must be a KERNEL fact, never an inference from the
        # name. A row whose derivation is not one of these is not derived.
        # A CLASS derivation is deliberately NOT a `kernel:Name.*` label:
        # Kernel has no Name node for a class, so claiming one would assert a
        # fact that does not exist. Each allowed value names what was actually
        # read.
        allowed = {'kernel:Name.isPrivate=false', 'kernel:Name.libraryReference',
                   'kernel:Name.libraryReference(foreign-domain)',
                   'derived:Class.name(no-leading-underscore)',
                   'derived:Class.name(leading-underscore)+Class.enclosingLibrary'
                   '(kernel-has-no-Name-node-for-a-class)'}
        bad = [r for r in base['rows'] if r['domain_derivation'] not in allowed]
        extra['domains'] = base['domains']
        extra['underivable'] = len(underivable)
        if underivable:
            lines.append(f'  FAILED  {len(underivable)} row(s) have no derivable '
                         f'domain and were CLASSIFIED, per the stop condition:')
            for r in underivable[:4]:
                lines.append(f'            {r["name"]} -> {r["privacy_domain"]}')
            fails += 1
        elif bad:
            lines.append(f'  FAILED  {len(bad)} row(s) carry a domain that was not '
                         f'derived from a kernel fact: {bad[0]["domain_derivation"]}')
            fails += 1
        else:
            lines.append(f'  ok      all {base["count"]} rows carry a domain derived '
                         f'from Name.isPrivate / Name.libraryReference')
        lines.append('          census (EFFECTIVE domains): ' + ', '.join(
            f'{v} {k}' for k, v in sorted(base['domains'].items())))

        # THE DISCRIMINATING CASE. Two libraries declare the same private simple
        # name. If the domain were inferred from the identifier they would
        # collide; Kernel's Name equality says they are different names.
        a = find(base, 'package:corpus/app.dart', None, '_privateHelper')
        h = find(base, 'package:corpus/helper.dart', None, '_privateHelper')
        if a and h and a['privacy_domain'] != h['privacy_domain']:
            lines.append('  ok      the same private simple name in two libraries gets '
                         'two domains')
            lines.append(f'            {a["privacy_domain"]}')
            lines.append(f'            {h["privacy_domain"]}')
        else:
            lines.append('  FAILED  two libraries declaring `_privateHelper` did not '
                         'produce two distinct domains, so the domain is not '
                         'library-scoped')
            fails += 1

    # ---- 1b. the owner rule, on a corpus that has private owners -----------
    arm('a PUBLIC member of a PRIVATE class is still access-controlled')
    po = docs.get('g3_privowner')
    if po is None:
        lines.append('  FAILED  g3_privowner rows unavailable, so the owner rule is '
                     'not exercised')
        fails += 1
    else:
        # THE COUNTS MUST AGREE. private_count is computed from effective
        # privacy and the census is a separate traversal; they disagreed while
        # the census was still keyed on the member's own domain (11 vs 4), and
        # the number that mattered was the one nobody was looking at.
        non_public = sum(v for k, v in po['domains'].items() if k != 'public')
        if non_public != po['private_count']:
            lines.append(f'  FAILED  census disagrees with private_count: '
                         f'{non_public} non-public in the census vs '
                         f'{po["private_count"]} counted')
            fails += 1
        else:
            lines.append(f'  ok      census and private_count agree: {non_public} '
                         f'effectively-private of {po["count"]} rows')
        extra['privowner_domains'] = po['domains']
        extra['privowner_member_own_domains'] = po['member_own_domains']

        ping = find(po, 'package:corpus/app.dart', '_Hidden', 'ping', 'method')
        if ping is None:
            lines.append('  FAILED  _Hidden.ping not found')
            fails += 1
        else:
            # Its OWN name is public; only the owner is private. A member-only
            # model records domain `public` here and then compares that against
            # a library URI.
            okrow = (ping['is_private'] is False
                     and ping['owner_is_private'] is True
                     and ping['effective_privacy_domain'] == 'package:corpus/app.dart'
                     and ping['effective_domain_source'].startswith('owner'))
            if okrow:
                lines.append('  ok      _Hidden.ping: own name public, owner private, '
                             'effective domain from the OWNER')
                lines.append(f'            member privacy_domain     = '
                             f'{ping["privacy_domain"]}')
                lines.append(f'            effective_privacy_domain  = '
                             f'{ping["effective_privacy_domain"]}')
                lines.append(f'            effective_domain_source   = '
                             f'{ping["effective_domain_source"]}')
            else:
                lines.append(f'  FAILED  _Hidden.ping effective domain is '
                             f'{ping["effective_privacy_domain"]} via '
                             f'{ping["effective_domain_source"]}')
                fails += 1

        # THE OWNER-LEVEL ANALOGUE of the two `_privateHelper` declarations: two
        # libraries each declaring a private class of the same simple name. The
        # effective domain of their members is read from the OWNER, so if owner
        # domains collided every member of both classes would share one domain.
        a = find(po, 'package:corpus/app.dart', '_Hidden', 'ping', 'method')
        h = find(po, 'package:corpus/helper.dart', '_Hidden', 'ping', 'method')
        if a and h and a['effective_privacy_domain'] != h['effective_privacy_domain']:
            lines.append('  ok      the same private CLASS name in two libraries gives '
                         'its members two domains')
            lines.append(f'            {a["effective_privacy_domain"]}')
            lines.append(f'            {h["effective_privacy_domain"]}')
        else:
            lines.append('  FAILED  two libraries declaring `_Hidden` did not give '
                         'their members distinct effective domains')
            fails += 1

        # The unnamed constructor is the quietest case: its Name text is '', so
        # `''.startsWith('_')` is false and its own privacy is public.
        ctor = find(po, 'package:corpus/app.dart', '_Hidden', '', 'constructor')
        if ctor and ctor['effective_privacy_domain'] == 'package:corpus/app.dart' \
                and ctor['effective_domain_source'].startswith('owner'):
            lines.append("  ok      _Hidden's unnamed constructor (Name text '') takes "
                         'its domain from the owner')
        else:
            lines.append('  FAILED  the unnamed constructor of a private class did not '
                         'take the owner\'s domain')
            fails += 1

    # ---- 2. read and write are distinguished, not merged -------------------
    arm('read and write capability are distinguished, not merged')
    if base is not None:
        collapsed = [r for r in base['rows']
                     if r['write_mode_exists']
                     and not r['capability_key_identifies_mode']]
        extra['write_collapsed'] = [
            f'{r["library"]}#{r["owner"] or ""}#{r["name"]}' for r in collapsed]
        setter = find(base, 'package:corpus/app.dart', 'Shape', 'scale', 'setter')
        getter = find(base, 'package:corpus/app.dart', 'Shape', 'perimeter',
                      'getter')
        if setter and getter and setter['capability_key_write'] and \
                getter['capability_key_read'] and \
                setter['capability_key_write'] != getter['capability_key_read']:
            lines.append('  ok      an accessor names its mode: '
                         f'{setter["capability_key_write"].split("#")[-1]} vs '
                         f'{getter["capability_key_read"].split("#")[-1]}')
        else:
            lines.append('  FAILED  accessor read/write keys are not distinct')
            fails += 1
        # A FINDING, not a pass and not a failure: the shape exists in the
        # corpus and in the real releases, and the map states it.
        if collapsed:
            lines.append(f'  FINDING {len(collapsed)} mutable private field(s) whose '
                         f'ONE manifest key authorises both modes:')
            for r in collapsed:
                lines.append(f'            {r["library"]}#{r["owner"]}#{r["name"]}')
            lines.append('          The map records capability_key_identifies_mode='
                         'false, so a write is refused before publication rather '
                         'than accepted on the strength of a read grant.')

    # ---- 3. the adversarial arms ------------------------------------------
    arm('adversarial arms: each must refuse, and refuse for the right reason')
    for case in exp['cases']:
        doc = docs.get(case['corpus'])
        cid = case['id']
        if doc is None:
            lines.append(f'  FAILED  {cid:28} corpus {case["corpus"]} unavailable')
            fails += 1
            results.append({'id': cid, 'outcome': 'NO_EVIDENCE'})
            continue
        row = find(doc, case['library'], case.get('owner'), case['name'],
                   case.get('kind'))
        if row is None:
            lines.append(f'  FAILED  {cid:28} subject not found: '
                         f'{case["library"]}#{case.get("owner") or ""}#{case["name"]}')
            fails += 1
            results.append({'id': cid, 'outcome': 'SUBJECT_MISSING'})
            continue
        # The release's manifest, built from the map itself: every retained
        # private READ key. This models a release that recorded reads -- which
        # is what every real manifest in this repo contains, and none contains a
        # `set:` key.
        # Built on EFFECTIVE privacy. Keyed on `is_private` alone, a public
        # member of a private class was left out of the synthetic grant set,
        # so the accept case below would have failed as READ_NOT_GRANTED even
        # once the domain comparison was fixed.
        granted = {r['capability_key_read'] for r in doc['rows']
                   if r['effective_privacy_domain'] != 'public'
                   and r['retained_in_release']
                   and r['capability_key_read']}
        # Constructibility is published separately by the real manifest, so it
        # is granted separately here too.
        granted |= {r['capability_key_construct'] for r in doc['rows']
                    if r['effective_privacy_domain'] != 'public'
                    and r['retained_in_release']
                    and r['capability_key_construct']}

        # A RELEASE MAY RETAIN SOMETHING AND STILL NOT GRANT IT. That is not a
        # hypothetical: the shipped manifest carries `constructionWithheld` and
        # `refused` lists precisely for it. `withhold_modes` removes this
        # subject's own key for the named modes from the synthetic manifest, so
        # the ungranted categories can be reached without inventing a key.
        withheld = set()
        for m in case.get('withhold_modes') or []:
            k = row.get(f'capability_key_{m}')
            if k is None:
                lines.append(f'  FAILED  {cid:28} withhold_modes names {m!r}, but the '
                             f'subject has no key for that mode, so nothing was '
                             f'withheld and the arm would prove nothing')
                fails += 1
                k = None
            else:
                withheld.add(k)
        granted = granted - withheld
        got = decide(row, case['mode'], granted, case['grant_scope'])
        want = case['expected']
        problems = []
        if got != want:
            problems.append(f'{got} (want {want})')
        # AN ARM THAT IS NOT ADVERSARIAL PROVES NOTHING. A case declared as a
        # refusal must actually refuse, and the positive control must accept.
        if want == ACCEPT and got != ACCEPT:
            problems.append('the positive control refused, so every refusal below '
                            'may be a policy that refuses everything')
        if problems:
            fails += 1
            lines.append(f'  FAILED  {cid:28} ' + '; '.join(problems))
        else:
            verb = 'accepts' if got == ACCEPT else 'refuses'
            lines.append(f'  ok      {cid:28} {case["mode"]:5} {verb:8} {got}')
        results.append({
            'id': cid, 'corpus': case['corpus'], 'mode': case['mode'],
            'grant_scope': case['grant_scope'], 'expected': want, 'got': got,
            'subject': f'{case["library"]}#{case.get("owner") or ""}#{case["name"]}',
            'withhold_modes': case.get('withhold_modes') or [],
        })

    # EVERY CATEGORY THE POLICY CAN RETURN MUST BE EXERCISED. Otherwise a
    # category could be dead code and the arms would still all pass.
    arm('every refusal category is exercised by some arm')
    exercised = {r['got'] for r in results}
    declared = policy_return_surface()
    missing = declared - exercised
    stray = exercised - declared
    extra['categories_exercised'] = sorted(exercised)
    extra['policy_return_surface'] = sorted(declared)
    lines.append(f'  policy return surface, read from decide()\'s own source: '
                 f'{len(declared)} categories')
    if missing:
        lines.append(f'  FAILED  never exercised: {sorted(missing)} — an unexercised '
                     f'category may be unreachable')
        fails += 1
    if stray:
        # An outcome no return statement can produce means the reader and the
        # policy have diverged.
        lines.append(f'  FAILED  produced but not in the policy surface: '
                     f'{sorted(stray)}')
        fails += 1
    if not missing and not stray:
        lines.append(f'  ok      all {len(declared)} categories exercised: '
                     f'{", ".join(sorted(declared))}')

    print('\n'.join(lines))
    print()
    print(f'SUMMARY checks_failed={fails}')
    print('G3 PRIVACY VERIFIED' if fails == 0 else 'G3 PRIVACY FAILED')

    json.dump({
        'schema': 'semantic-map-1/g3-privacy-score/1', 'gate': 'SM1-G3',
        'issue': 52, 'checks_failed': fails,
        'results': results, 'arms': extra,
    }, open(out_json, 'w'), indent=2)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
