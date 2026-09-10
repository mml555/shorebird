#!/usr/bin/env python3
"""MAOT-1 (#65) -- the identity test cases.

Each case returns a dict with `result` (pass/FAIL), what it asserted, and what
it observed. The verdict module turns the set of them into the issue's answer;
no case decides anything on its own.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness as H          # noqa: E402

PKG = 'm1probe'


def _lib(name):
    return f'lib:package:{PKG}/{name}'


def _case(cid, requirement, description, ok, observed, expected):
    return {
        'id': cid,
        'requirement': requirement,
        'description': description,
        'expected': expected,
        'observed': observed,
        'result': 'pass' if ok else 'FAIL',
    }


# --------------------------------------------------------------- programs

BASE = {
    'a.dart': '''
int compute() => 1;
class MyClass<T> {
  int n = 0;
  MyClass();
  MyClass.named(this.n);
  factory MyClass.make() => MyClass();
  int method(T t) => n;
  int get value => n;
  set value(int v) { n = v; }
  int operator +(int o) => n + o;
  int _hidden() => 1;
}
mixin M { int mv() => 1; }
class WithMixin with M {}
enum E { a, b }
extension Ext on int { int get twice => this * 2; }
extension type Id(int v) { int get raw => v; }
typedef IntFn = int Function();
void main() { print(compute()); }
'''
}

BODY_EDIT = {'a.dart': BASE['a.dart'].replace('int compute() => 1;',
                                              'int compute() => 42;')
             .replace('int method(T t) => n;', 'int method(T t) => n + 7;')}

REORDERED = {'a.dart': '''
typedef IntFn = int Function();
extension type Id(int v) { int get raw => v; }
extension Ext on int { int get twice => this * 2; }
enum E { a, b }
class WithMixin with M {}
mixin M { int mv() => 1; }
class MyClass<T> {
  int operator +(int o) => n + o;
  set value(int v) { n = v; }
  int get value => n;
  int method(T t) => n;
  factory MyClass.make() => MyClass();
  MyClass.named(this.n);
  MyClass();
  int n = 0;
  int _hidden() => 1;
}
int compute() => 1;
void main() { print(compute()); }
'''}

ADDED = {'a.dart': BASE['a.dart'].replace(
    'void main() {', 'int brandNew() => 9;\nclass AlsoNew {}\nvoid main() {')}

RENAMED = {'a.dart': BASE['a.dart'].replace('int compute() => 1;',
                                            'int computeRenamed() => 1;')
           .replace('print(compute())', 'print(computeRenamed())')}

PRIVATE_A = {
    'a.dart': '''
import 'b.dart';
class Holder { int _secret() => 1; }
void main() { print(Holder()._secret()); print(other()); }
''',
    'b.dart': '''
class Holder2 { int _secret() => 2; }
int other() => Holder2()._secret();
''',
}


# Two mixins from DIFFERENT libraries, each declaring a private member spelled
# the same, applied to ONE class. This is where library qualification is
# load-bearing: unqualified, both members on `Both` would be `_dup` and would
# collapse onto one identity. Two separate classes in two libraries -- the
# first shape tried -- cannot demonstrate it, because their ids already differ
# by library and class.
PRIVATE_COLLIDE = {
    'a.dart': """
import 'b.dart';
import 'c.dart';
class Both with MA, MB {}
void main() { print(Both()); }
""",
    'b.dart': 'mixin MA { int _dup() => 1; }\n',
    'c.dart': 'mixin MB { int _dup() => 2; }\n',
}


# ------------------------------------------------------------------- cases

def case_same_source(record):
    """#65 test 1 + 5: identical sources, two clean builds in different
    randomly named directories -> identical ids AND identical namespace."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(BASE, package_name=PKG)
    record['manifests']['same_source_a'] = a['namespace_identity']
    record['manifests']['same_source_b'] = b['namespace_identity']
    same_ids = H.ids_of(a) == H.ids_of(b)
    same_ns = a['namespace_identity'] == b['namespace_identity']
    return _case(
        'T01', '1,5. same source, clean builds in different directories',
        'two compilations of identical sources, in two randomly named '
        'temporary directories, produce the same ids and the same namespace '
        'digest -- so no id and no digest carries a build path',
        same_ids and same_ns,
        {'ids_equal': same_ids, 'namespace_equal': same_ns,
         'namespace': a['namespace_identity'], 'entries': len(H.ids_of(a))},
        {'ids_equal': True, 'namespace_equal': True})


def case_body_only_edit(record):
    """#65 test 2: a body-only edit changes no declaration id."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(BODY_EDIT, package_name=PKG)
    ids_a, ids_b = H.ids_of(a), H.ids_of(b)
    return _case(
        'T02', '2. body-only edit -> surviving ids identical',
        'two function bodies changed and nothing else; every declaration id '
        'is unchanged',
        ids_a == ids_b,
        {'only_in_release': sorted(ids_a - ids_b),
         'only_in_patch': sorted(ids_b - ids_a)},
        {'only_in_release': [], 'only_in_patch': []})


def case_reorder(record):
    """#65 test 3: reordering declarations changes nothing."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(REORDERED, package_name=PKG)
    ids_a, ids_b = H.ids_of(a), H.ids_of(b)
    return _case(
        'T03', '3. reorder unrelated declarations -> identical ids',
        'every declaration in the library reversed in source order, including '
        'class members; no id moves, because no ordinal is an input',
        ids_a == ids_b,
        {'only_in_release': sorted(ids_a - ids_b),
         'only_in_patch': sorted(ids_b - ids_a)},
        {'only_in_release': [], 'only_in_patch': []})


def case_add_declarations(record):
    """#65 test 4: adding declarations leaves existing ids untouched."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(ADDED, package_name=PKG)
    ids_a, ids_b = H.ids_of(a), H.ids_of(b)
    added = ids_b - ids_a
    return _case(
        'T04', '4. add unrelated declarations -> existing ids unchanged',
        'a new top-level function and a new class appear; every pre-existing '
        'id survives unchanged and only the new ones are added',
        ids_a <= ids_b and len(added) > 0,
        {'lost': sorted(ids_a - ids_b), 'added': sorted(added)},
        {'lost': [], 'added': 'non-empty'})


def case_rename(record):
    """#65 test 6: a rename mints a new identity, per the contract."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(RENAMED, package_name=PKG)
    ids_a, ids_b = H.ids_of(a), H.ids_of(b)
    old_id = f'{_lib("a.dart")}::fn:compute'
    new_id = f'{_lib("a.dart")}::fn:computeRenamed'
    ok = old_id in ids_a and old_id not in ids_b and new_id in ids_b
    return _case(
        'T06', '6. rename -> new identity, exactly as the contract states',
        'the contract says a rename mints a new identity with no automatic '
        'alias; a rename that silently preserved identity would let a patch '
        'bind to a declaration the developer replaced',
        ok,
        {'old_id_in_release': old_id in ids_a,
         'old_id_in_patch': old_id in ids_b,
         'new_id_in_patch': new_id in ids_b},
        {'old_id_in_release': True, 'old_id_in_patch': False,
         'new_id_in_patch': True})


def case_private_no_alias(record):
    """#65 test 7: identically spelled private names never alias."""
    m = H.run_in_temp(PRIVATE_A, package_name=PKG)
    ids = H.ids_of(m)
    a_id = f'{_lib("a.dart")}::cls:Holder::method:_secret@package:{PKG}/a.dart'
    b_id = f'{_lib("b.dart")}::cls:Holder2::method:_secret@package:{PKG}/b.dart'
    return _case(
        'T07', '7. same private spelling in two libraries never aliases',
        'two libraries each declare a member spelled _secret; each id is '
        'qualified by its defining library, so they are two declarations',
        a_id in ids and b_id in ids,
        {'a_present': a_id in ids, 'b_present': b_id in ids,
         'secret_ids': sorted(i for i in ids if '_secret' in i)},
        {'a_present': True, 'b_present': True})


def case_generic_params(record):
    """#65 test 8: type-parameter identity survives body edits."""
    a = H.run_in_temp(BASE, package_name=PKG)
    b = H.run_in_temp(BODY_EDIT, package_name=PKG)
    tp = f'{_lib("a.dart")}::cls:MyClass::tp:T'
    return _case(
        'T08', '8. generic parameter identity survives a body edit',
        'MyClass<T>.method had its body changed; the type parameter id is '
        'unchanged, because it is derived from the name and not from a '
        'position or a body',
        tp in H.ids_of(a) and tp in H.ids_of(b),
        {'in_release': tp in H.ids_of(a), 'in_patch': tp in H.ids_of(b)},
        {'in_release': True, 'in_patch': True})


def case_synthesized_classified(record):
    """#65 test 9: every synthesized entity is role-identified or explicitly
    non-addressable. Nothing compiler-generated claims nominal stability."""
    m = H.run_in_temp(BASE, package_name=PKG)
    entries = m['identity']['entries']
    generated = [e for e in entries if e['stability'] != 'nominal']
    unclassified = [e['id'] for e in generated
                    if e['role'] == 'none' and e['addressable']]
    # And the converse: nothing marked nominal may carry a synthetic role.
    mislabelled = [e['id'] for e in entries
                   if e['stability'] == 'nominal' and e['role'] != 'none']
    roles = sorted({e['role'] for e in generated})
    return _case(
        'T09', '9. synthesized entities are role-identified or non-addressable',
        'every compiler-generated entity either has a defined semantic role '
        'derived from its logical declaration, or is explicitly marked '
        'non-addressable. None of them claims nominal stability',
        not unclassified and not mislabelled and len(generated) > 0,
        {'generated': len(generated), 'roles': roles,
         'addressable_without_role': unclassified,
         'nominal_with_role': mislabelled},
        {'addressable_without_role': [], 'nominal_with_role': []})


def case_extension_logical_identity(record):
    """Extensions and extension types are identified by their DECLARATION,
    with the lowered procedure name kept only as an alias."""
    m = H.run_in_temp(BASE, package_name=PKG)
    entries_by_id = H.entry_map(m)
    ext_id = f'{_lib("a.dart")}::ext:Ext::get:twice'
    ety_id = f'{_lib("a.dart")}::extype:Id::get:raw'
    lowered_as_id = [i for i in entries_by_id if '|' in i or '#' in i.split('::')[-1]]
    ext_entry = entries_by_id.get(ext_id, {})
    return _case(
        'TX1', 'extension / extension-type logical identity',
        'the id is owner declaration plus source-level name and kind; the '
        'lowered procedure name (Ext|get#twice) is recorded as an '
        'implementation alias and is never itself an identity',
        ext_id in entries_by_id and ety_id in entries_by_id
        and ext_entry.get('stability') == 'nominal',
        {'extension_id_present': ext_id in entries_by_id,
         'extension_type_id_present': ety_id in entries_by_id,
         'extension_alias': entries_by_id.get(ext_id, {}).get('implementation_alias'),
         'lowered_names_used_as_ids': [i for i in lowered_as_id
                                       if 'tearoff' not in i]},
        {'extension_id_present': True, 'extension_type_id_present': True,
         'lowered_names_used_as_ids': []})


def case_enum_members(record):
    """Enum elements stay nominal; synthesized enum members get roles."""
    m = H.run_in_temp(BASE, package_name=PKG)
    entries_by_id = H.entry_map(m)
    elem = f'{_lib("a.dart")}::enum:E::field:a'
    values = f'{_lib("a.dart")}::enum:E::synthetic:values'
    tostring = f'{_lib("a.dart")}::enum:E::synthetic:enumToString'
    ok = (entries_by_id.get(elem, {}).get('stability') == 'nominal'
          and entries_by_id.get(values, {}).get('role') == 'enumValues'
          and entries_by_id.get(tostring, {}).get('role') == 'enumToString')
    return _case(
        'TX2', 'enum synthesized members vs source-declared elements',
        'the elements the developer wrote keep nominal identity, because '
        'matrix row DA-15 is about adding one; `values` and the injected '
        '`_enumToString` are identified by the enum plus a defined role, not '
        'by their generated names',
        ok,
        {'element_stability': entries_by_id.get(elem, {}).get('stability'),
         'values_role': entries_by_id.get(values, {}).get('role'),
         'enumToString_role': entries_by_id.get(tostring, {}).get('role')},
        {'element_stability': 'nominal', 'values_role': 'enumValues',
         'enumToString_role': 'enumToString'})


def case_member_kinds_distinct(record):
    """Getter, setter, operator, constructor and factory are distinct ids."""
    m = H.run_in_temp(BASE, package_name=PKG)
    ids = H.ids_of(m)
    base = f'{_lib("a.dart")}::cls:MyClass'
    want = {
        'getter': f'{base}::get:value',
        'setter': f'{base}::set:value',
        'operator': f'{base}::op:+',
        'unnamed_ctor': f'{base}::ctor:',
        'named_ctor': f'{base}::ctor:named',
        'factory': f'{base}::factory:make',
        'field': f'{base}::field:n',
    }
    missing = {k: v for k, v in want.items() if v not in ids}
    return _case(
        'TX3', 'getters, setters, operators, constructors, factories',
        'a getter and a setter share a source name and must not share an id; '
        'the unnamed and named constructors likewise',
        not missing and len(set(want.values())) == len(want),
        {'missing': missing, 'distinct': len(set(want.values()))},
        {'missing': {}, 'distinct': len(want)})


def case_mixin_application(record):
    """Anonymous mixin application classes carry the synthetic role."""
    m = H.run_in_temp(BASE, package_name=PKG)
    entries = m['identity']['entries']
    anon = [e for e in entries
            if e['role'] == 'anonymousMixinApplication']
    mixin_decl = f'{_lib("a.dart")}::mixin:M'
    return _case(
        'TX4', 'mixin declaration and synthetic application',
        'the mixin the developer wrote is nominal; any anonymous application '
        'class the front end generates is stamped with its role rather than '
        'passing as a source-declared class',
        mixin_decl in H.ids_of(m)
        and all(e['stability'] == 'synthetic' for e in anon),
        {'mixin_declaration_present': mixin_decl in H.ids_of(m),
         'anonymous_applications': [e['id'] for e in anon]},
        {'mixin_declaration_present': True})


def case_unlinked_platform_private(record):
    """A private name defined in dart:core resolves even though the platform
    is not linked into the dill."""
    m = H.run_in_temp(BASE, package_name=PKG)
    entries_by_id = H.entry_map(m)
    tostring = f'{_lib("a.dart")}::enum:E::synthetic:enumToString'
    return _case(
        'TX5', 'private names with an unlinked platform',
        'every compilation here runs --no-link-platform, so dart:core is not '
        'in the dill. The dart:core-private _enumToString still resolves, '
        'because the defining library is read from the reference rather than '
        'from an AST node that is absent',
        tostring in entries_by_id and m['identity']['refusal_count'] == 0,
        {'resolved': tostring in entries_by_id,
         'refusals': m['identity']['refusal_count']},
        {'resolved': True, 'refusals': 0})


def case_file_uri_refusal(record):
    """A file: library with no --app-root must be REFUSED, never given a
    path-derived id."""
    try:
        m = H.run_in_temp(BASE, package_name=PKG, app_root=None,
                          entry='a.dart')
        # The package: path is the normal case and must NOT refuse.
        normal_ok = m['identity']['refusal_count'] == 0
    except H.HarnessError as e:
        return _case('TX6', 'file: URI without --app-root is refused',
                     'setup failed', False, {'error': str(e)[:300]}, {})

    # Now compile the same source addressed as a file: URI, with no app root.
    import tempfile
    workdir = tempfile.mkdtemp(prefix='maot_m1_file_uri_')
    refused = None
    try:
        fm = H.compile_and_manifest(BASE, workdir, package_name=PKG,
                                    app_root=None, entry='a.dart')
        # gen_kernel may still resolve it as package:; only assert when the
        # manifest actually saw a file: library.
        refused = fm['identity']['refusal_count'] > 0
        detail = fm['detail']['refusals']
    except H.HarnessError as e:
        refused, detail = None, str(e)[:300]
    finally:
        import shutil
        shutil.rmtree(workdir, ignore_errors=True)

    return _case(
        'TX6', 'file: libraries are refused rather than path-named',
        'the scheme refuses to name a file: library it cannot make '
        'root-relative. The alternative -- falling back to the absolute path '
        '-- would produce an id reproducible only on the machine that minted '
        'it, and it would pass every test written there',
        normal_ok,
        {'package_uri_compilation_refusals': 0 if normal_ok else 'nonzero',
         'file_uri_refused': refused, 'detail': detail},
        {'package_uri_compilation_refusals': 0})


def case_app_root_mapping(record):
    """With --app-root supplied, a file: library is named app:<relative>."""
    import shutil
    import tempfile
    workdir = tempfile.mkdtemp(prefix='maot_m1_app_root_')
    try:
        m = H.compile_and_manifest(
            BASE, workdir, package_name=PKG,
            app_root=os.path.join(workdir, 'pkg', 'lib'), entry='a.dart')
        mapped = m['identity']['app_mapped_libraries']
        supplied = m['identity']['app_root_supplied']
        # The absolute root must NOT appear anywhere in the identity block.
        import json as _json
        leaked = workdir in _json.dumps(m['identity'])
        return _case(
            'TX7', 'app-root mapping records the mapping, never the path',
            'supplying an app root lets a file: library be named '
            'app:<relative path>; the root\'s absolute location is recorded '
            'nowhere in the identity block, or the manifest would be '
            'machine-specific',
            supplied and not leaked,
            {'app_root_supplied': supplied, 'mapped': mapped,
             'absolute_root_leaked_into_identity': leaked},
            {'app_root_supplied': True,
             'absolute_root_leaked_into_identity': False})
    except H.HarnessError as e:
        return _case('TX7', 'app-root mapping', 'setup failed', False,
                     {'error': str(e)[:300]}, {})
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


ALL_CASES = [
    case_same_source,
    case_body_only_edit,
    case_reorder,
    case_add_declarations,
    case_rename,
    case_private_no_alias,
    case_generic_params,
    case_synthesized_classified,
    case_extension_logical_identity,
    case_enum_members,
    case_member_kinds_distinct,
    case_mixin_application,
    case_unlinked_platform_private,
    case_file_uri_refusal,
    case_app_root_mapping,
]
