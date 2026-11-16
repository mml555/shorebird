#!/usr/bin/env python3
"""Fail when a tracked YAML file does not load.

The repo's scripts mostly read YAML one line at a time with sed or grep, so a
file can stop being YAML without anything noticing:
selfhost/compatibility.yaml did, from #134 until #187. This loads every tracked
*.yaml and *.yml file (every document in it) with PyYAML's safe loader;
an application tag such as Compose's `!reset` loads as its plain value.

Usage: tool/check_yaml_parses.py   (from anywhere inside the checkout)
Exit:  0 all load, 1 one or more do not, 2 PyYAML or git is missing.
"""
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("check_yaml_parses: PyYAML is not installed (python3 -m pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

try:
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()
    names = subprocess.run(["git", "-C", top, "ls-files", "-z", "--", "*.yaml", "*.yml"], check=True, capture_output=True).stdout
except (OSError, subprocess.CalledProcessError) as e:
    print(f"check_yaml_parses: cannot list tracked files: {e}", file=sys.stderr)
    sys.exit(2)


class _Loader(yaml.SafeLoader):
    """The safe loader, plus: an application tag (Compose's `!reset`) loads as
    its plain value. This checks syntax, not what a tag means."""


def _untagged(loader, _suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_scalar(node)


_Loader.add_multi_constructor("!", _untagged)

files = [n.decode() for n in names.split(b"\0") if n]
bad = 0
for name in files:
    try:
        with open(f"{top}/{name}", encoding="utf-8") as f:
            for _ in yaml.load_all(f, Loader=_Loader):
                pass
    except (yaml.YAMLError, UnicodeDecodeError) as e:
        bad += 1
        print(f"::error file={name}::does not load as YAML: {' '.join(str(e).split())}")

print(f"{len(files) - bad} of {len(files)} tracked YAML files load")
sys.exit(1 if bad else 0)
