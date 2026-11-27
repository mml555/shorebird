#!/usr/bin/env python3
# cspell:words strerror Psych ARGV
"""Fail when a tracked YAML file does not load.

The repo's scripts mostly read YAML one line at a time with sed or grep, so a
file can stop being YAML without anything noticing:
selfhost/compatibility.yaml did, from #134 until #187. This loads every tracked
*.yaml and *.yml file (every document in it) with PyYAML's safe loader;
an application tag such as Compose's `!reset` loads as its plain value.

Without PyYAML (the stock macOS python3 has none) it parses each file with
Ruby's Psych instead, so a local run still catches a file that is not YAML.
That parse checks syntax only; CI, which has PyYAML, also builds each document.

Usage: tool/check_yaml_parses.py   (from anywhere inside the checkout)
Exit:  0 all load, 1 one or more do not, 2 git, or both PyYAML and ruby, missing.
"""
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:
    yaml = None

try:
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()
    names = subprocess.run(["git", "-C", top, "ls-files", "-z", "--", "*.yaml", "*.yml"], check=True, capture_output=True).stdout
except (OSError, subprocess.CalledProcessError) as e:
    print(f"check_yaml_parses: cannot list tracked files: {e}", file=sys.stderr)
    sys.exit(2)

files = [n.decode() for n in names.split(b"\0") if n]

# One ruby process parses every file: prints the ::error lines, then the count.
_RUBY_PARSE = r"""
require "psych"
top = ARGV.shift
bad = 0
ARGV.each do |name|
  begin
    Psych.parse_stream(File.read(File.join(top, name), encoding: "UTF-8"), filename: name)
  rescue Psych::SyntaxError, ArgumentError, EncodingError => e
    bad += 1
    puts "::error file=#{name}::does not load as YAML: #{e.message.split.join(" ")}"
  rescue SystemCallError => e
    bad += 1
    puts "::error file=#{name}::cannot be read: #{e.message}"
  end
end
puts "#{ARGV.size - bad} of #{ARGV.size} tracked YAML files parse (Ruby Psych; PyYAML is not installed)"
exit(bad.zero? ? 0 : 1)
"""

if yaml is None:
    ruby = shutil.which("ruby")
    if ruby is None:
        print("check_yaml_parses: neither PyYAML (python3 -m pip install pyyaml) nor ruby is installed", file=sys.stderr)
        sys.exit(2)
    sys.exit(subprocess.run([ruby, "-e", _RUBY_PARSE, top, *files]).returncode)


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

bad = 0
for name in files:
    try:
        with open(f"{top}/{name}", encoding="utf-8") as f:
            for _ in yaml.load_all(f, Loader=_Loader):
                pass
    except (yaml.YAMLError, UnicodeDecodeError) as e:
        bad += 1
        print(f"::error file={name}::does not load as YAML: {' '.join(str(e).split())}")
    except OSError as e:  # tracked but unreadable: a broken symlink, or deleted in the working tree
        bad += 1
        print(f"::error file={name}::cannot be read: {e.strerror or e}")

print(f"{len(files) - bad} of {len(files)} tracked YAML files load")
sys.exit(1 if bad else 0)
