#!/usr/bin/env python3
"""MAOT-0 (#63) -- derive the construct universes the matrix must cover.

WHY THIS EXISTS. #63's falsification requirement is:

    "The matrix/contract is inadequate if any Dart language/runtime construct
     can be named that has no row or no explicit classification."

A coverage check whose required-row list IS the matrix cannot fail. So the
required list is derived from something the matrix does not author: the
compiler and runtime we intend to fork. Two universes:

  U1  every node class and node-kind enum value in package:kernel's AST --
      the exhaustive statement of what a Dart program can BE after the CFE.
  U2  every heap class in the Dart VM's object.h that reaches Object --
      the exhaustive statement of what live state can BE at runtime.

Neither is authored here. Both are read out of a Dart tree at a named
revision, with per-file digests, and frozen into the repo so the gate runs
without that tree (and off this machine).

TIERS. Not every universe entry deserves its own matrix row: `AddExpression`
is a body content node, and "any expression may change" is one rule, not 78.
So every entry carries a tier, and a matrix row may cover an entire tier
explicitly. The blanket is then VISIBLE and reviewable rather than an
unstated omission -- and a tier this file does not know about is a hard
failure, so a new AST file cannot enter the tree unclassified.

usage: extract_universe.py <dart-tree> <out-dir>
"""

import hashlib
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------- tiers

# The tier a kernel AST source file's declarations belong to. A file present
# in the tree and absent here is a FAILURE, not a default: an unclassified
# file would silently contribute zero universe entries and the coverage gate
# would pass while ignoring it.
KERNEL_FILE_TIERS = {
    'components.dart': 'program_structure',
    'constants.dart': 'constant',
    'declarations.dart': 'declaration',
    'dummies.dart': 'infrastructure',
    'expressions.dart': 'body_content',
    'functions.dart': 'declaration',
    'helpers.dart': 'infrastructure',
    'initializers.dart': 'body_content',
    'libraries.dart': 'declaration',
    'members.dart': 'declaration',
    'misc.dart': 'structural_base',
    'names.dart': 'identity',
    'patterns.dart': 'body_content',
    'statements.dart': 'body_content',
    'typedefs.dart': 'declaration',
    'types.dart': 'type',
    'variables.dart': 'declaration',
}

KERNEL_AST_REL = 'pkg/kernel/lib/src/ast'
VM_OBJECT_REL = 'runtime/vm/object.h'

CLASS_RE = re.compile(
    r'^(?:abstract\s+|sealed\s+|base\s+|final\s+|interface\s+|mixin\s+)*'
    r'class\s+([A-Za-z_][A-Za-z0-9_]*)')
ENUM_RE = re.compile(r'^enum\s+([A-Za-z_][A-Za-z0-9_]*)')
CPP_CLASS_RE = re.compile(
    r'^class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*public\s+([A-Za-z_][A-Za-z0-9_]*)')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git(tree, *args):
    try:
        out = subprocess.run(['git', '-C', tree] + list(args),
                             capture_output=True, text=True, timeout=60)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def parse_enum_values(lines, start):
    """Collect the value identifiers of the Dart enum declared at `start`.

    Comments are stripped BEFORE any structural scan. Kernel's enums carry
    doc comments containing Dart samples like `method(Function f) => f();`,
    and a scanner that looks for `;` or `,` before removing comments reads
    those samples as enum values -- which it did, inventing a value named
    `f` and terminating the enum early.

    Handles both layouts in the tree (one value per line, and all values on
    the declaration line) and enhanced enums, whose members follow a `;`.
    Splitting is done at paren depth 0 so `Value(1), Other(2)` is two values.
    """
    text = '\n'.join(re.sub(r'//.*$', '', ln) for ln in lines[start:])
    open_at = text.find('{')
    if open_at < 0:
        return []
    depth, end = 0, None
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return []
    body = text[open_at + 1:end]

    # Enhanced enums declare members after the first top-level `;`.
    depth, cut = 0, len(body)
    for i, ch in enumerate(body):
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        elif ch == ';' and depth == 0:
            cut = i
            break
    body = body[:cut]

    parts, depth, buf = [], 0, []
    for ch in body:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(buf))
            buf = []
        else:
            buf.append(ch)
    parts.append(''.join(buf))

    values = []
    for part in parts:
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|$)', part.strip())
        if m:
            values.append(m.group(1))
    return values


def extract_kernel(tree):
    ast_dir = os.path.join(tree, KERNEL_AST_REL)
    if not os.path.isdir(ast_dir):
        raise SystemExit(f'no kernel AST dir at {ast_dir}')
    present = sorted(f for f in os.listdir(ast_dir) if f.endswith('.dart'))
    unknown = [f for f in present if f not in KERNEL_FILE_TIERS]
    missing = [f for f in KERNEL_FILE_TIERS if f not in present]
    if unknown:
        raise SystemExit(
            'kernel AST files with no tier assignment: ' + ', '.join(unknown) +
            '\nAssign a tier in KERNEL_FILE_TIERS. An unclassified file would '
            'contribute no universe entries and the coverage gate would pass '
            'while ignoring everything it declares.')

    entries, digests = [], {}
    for fname in present:
        path = os.path.join(ast_dir, fname)
        digests[f'{KERNEL_AST_REL}/{fname}'] = sha256_file(path)
        tier = KERNEL_FILE_TIERS[fname]
        stem = fname[:-len('.dart')]
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().splitlines()
        for i, line in enumerate(lines):
            m = CLASS_RE.match(line)
            if m:
                entries.append({
                    'id': f'K:{stem}:{m.group(1)}',
                    'universe': 'kernel',
                    'kind': 'node_class',
                    'name': m.group(1),
                    'tier': tier,
                    'source': f'{KERNEL_AST_REL}/{fname}',
                    'line': i + 1,
                })
                continue
            m = ENUM_RE.match(line)
            if m:
                enum_name = m.group(1)
                entries.append({
                    'id': f'K:{stem}:{enum_name}',
                    'universe': 'kernel',
                    'kind': 'node_kind_enum',
                    'name': enum_name,
                    'tier': tier,
                    'source': f'{KERNEL_AST_REL}/{fname}',
                    'line': i + 1,
                })
                for val in parse_enum_values(lines, i):
                    entries.append({
                        'id': f'K:{stem}:{enum_name}.{val}',
                        'universe': 'kernel',
                        'kind': 'node_kind_value',
                        'name': f'{enum_name}.{val}',
                        'tier': tier,
                        'source': f'{KERNEL_AST_REL}/{fname}',
                        'line': i + 1,
                    })
    return entries, digests, present, missing


def extract_vm(tree):
    path = os.path.join(tree, VM_OBJECT_REL)
    if not os.path.isfile(path):
        raise SystemExit(f'no VM object header at {path}')
    with open(path, encoding='utf-8', errors='replace') as fh:
        lines = fh.read().splitlines()

    bases, order = {}, []
    for i, line in enumerate(lines):
        m = CPP_CLASS_RE.match(line)
        if m:
            name, base = m.group(1), m.group(2)
            if name not in bases:
                bases[name] = (base, i + 1)
                order.append(name)

    def reaches_object(name, seen=None):
        seen = seen or set()
        cur = name
        while cur in bases and cur not in seen:
            seen.add(cur)
            base = bases[cur][0]
            if base == 'Object':
                return True
            cur = base
        return name == 'Object'

    entries = []
    for name in order:
        base, line = bases[name]
        if base != 'Object' and not reaches_object(name):
            continue
        entries.append({
            'id': f'V:object.h:{name}',
            'universe': 'vm_runtime',
            'kind': 'heap_class',
            'name': name,
            'tier': 'runtime_state',
            'base': base,
            'source': VM_OBJECT_REL,
            'line': line,
        })
    return entries, {VM_OBJECT_REL: sha256_file(path)}


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    tree, outdir = os.path.abspath(argv[1]), os.path.abspath(argv[2])
    os.makedirs(outdir, exist_ok=True)

    k_entries, k_digests, k_files, k_missing = extract_kernel(tree)
    v_entries, v_digests = extract_vm(tree)

    # Provenance is repository + full immutable SHA, never a branch, and the
    # digests are what make the freeze checkable without the tree.
    head = git(tree, 'rev-parse', 'HEAD')
    dirty_paths = git(tree, 'status', '--porcelain', '--',
                      KERNEL_AST_REL, VM_OBJECT_REL)
    prov = {
        'dart_tree_head': head,
        'dart_tree_head_is_full_sha': bool(head) and len(head) == 40,
        'extracted_paths_dirty': bool(dirty_paths),
        'extracted_paths_dirty_detail': dirty_paths or '',
        'source_digests': dict(sorted({**k_digests, **v_digests}.items())),
        'extractor_sha256': sha256_file(os.path.abspath(__file__)),
        'kernel_ast_files_seen': k_files,
        'kernel_ast_files_expected_absent': k_missing,
        'tier_assignment': dict(sorted(KERNEL_FILE_TIERS.items())),
        'note': (
            'The tree path is deliberately NOT part of identity: it is a '
            'checkout location, not provenance. The head SHA and the per-file '
            'digests are. A re-derivation on any machine with the same tree '
            'must reproduce these digests exactly.'),
    }

    for name, entries, universe in (
            ('kernel_declarations.json', k_entries, 'kernel'),
            ('vm_runtime_state.json', v_entries, 'vm_runtime')):
        entries = sorted(entries, key=lambda e: e['id'])
        ids = [e['id'] for e in entries]
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        # Fail closed. Coverage is a map keyed by id, so a duplicate id lets
        # one row appear to cover two distinct constructs.
        if dupes:
            raise SystemExit(
                f'{universe}: duplicate universe ids: {", ".join(dupes)}')
        doc = {
            'schema': 'maot0.universe/1',
            'universe': universe,
            'provenance': prov,
            'duplicate_ids': dupes,
            'tier_counts': {
                t: sum(1 for e in entries if e['tier'] == t)
                for t in sorted({e['tier'] for e in entries})},
            'total': len(entries),
            'entries': entries,
        }
        with open(os.path.join(outdir, name), 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, indent=2, sort_keys=False)
            fh.write('\n')
        print(f'{name}: {len(entries)} entries, {len(dupes)} duplicate ids')

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
