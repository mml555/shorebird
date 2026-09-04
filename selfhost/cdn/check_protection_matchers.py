#!/usr/bin/env python3
"""Assert what the Caddy protection matchers actually COVER.

`caddy validate` checks that a regex parses. It says nothing about whether the
regex still matches the paths it is supposed to protect, and an alternation edit
can silently drop a suffix while remaining syntactically perfect:

    d4c0dbc2…|cd848320…/(ios|ios-profile)/artifacts\\.zip

parses, and protects neither H3's ios artifacts nor anything else useful,
because the first alternative is a bare hash under an end-anchored expression.
That regression shipped once. This is the mechanical check that catches it.

Reads the matchers out of the Caddyfile and evaluates a table of concrete paths,
so the assertion is about coverage rather than about syntax.
"""
import re
import sys
from pathlib import Path

CADDYFILE = Path(__file__).with_name('Caddyfile')

# Every cell whose engine artifacts must never fall through to another source.
PROTECTED_CELLS = [
    'a5a8be5854c529268378ce16762a16d6e31763e9',
    '64ff9f592ae319eea04db6092b71319d4778b873',
    'd4c0dbc2905286eb4537d5f9a7802693096ca1fd',   # H3
    'cd848320d605ff8af5060cabf9a8d1b35853f752',   # v13 successor
]
# Cells whose sky/gpu packages are protected but whose iOS modes are not.
SKY_ONLY_CELLS = [
    '70974f811d448da19a927c581678ef1dbd33605c',
    '4df8f9b6139b67d2cfe9f6aa8212372cade36278',
]


def matchers(text):
    """Every `path_regexp <re>` in the file, compiled."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('path_regexp '):
            out.append(re.compile(line[len('path_regexp '):].strip()))
    return out


def covered(res, path):
    return any(r.search(path) for r in res)


def main():
    res = matchers(CADDYFILE.read_text())
    if not res:
        sys.exit('no path_regexp matchers found -- the parse is wrong')

    expect_covered, expect_uncovered = [], []
    for cell in PROTECTED_CELLS:
        for mode in ('ios', 'ios-profile'):
            expect_covered.append(
                f'/flutter_infra_release/flutter/{cell}/{mode}/artifacts.zip')
        for pkg in ('sky_engine', 'flutter_gpu'):
            expect_covered.append(
                f'/flutter_infra_release/flutter/{cell}/{pkg}.zip')
    for cell in SKY_ONLY_CELLS:
        for pkg in ('sky_engine', 'flutter_gpu'):
            expect_covered.append(
                f'/flutter_infra_release/flutter/{cell}/{pkg}.zip')

    # ANDROID: all three RELEASE ABIs, and only the release ones.
    #
    # `android-arm64-release/` was protected while `android-arm-release/` and
    # `android-x64-release/` were not, and nothing here would have noticed --
    # each of the latter two carries a host gen_snapshot that compiles a shipped
    # libapp.so, so a fallback there substitutes another lineage's compiler.
    # The uncovered half of this table is the part that keeps the fix narrow:
    # the profile/debug objects are CACHE/TRANSPORT, cannot change a release,
    # and must stay fallback-permitted so an unsupported cell's `precache`
    # still completes.
    for cell in PROTECTED_CELLS:
        for abi in ('arm', 'arm64', 'x64'):
            for obj in ('darwin-x64.zip', 'artifacts.zip'):
                expect_covered.append(
                    f'/flutter_infra_release/flutter/{cell}/'
                    f'android-{abi}-release/{obj}')

    # Maven is protected host-wide and hash-generically, which is the only thing
    # that can work: Gradle validates the version inside the .pom body against
    # the coordinate, so a fallback is refused by Gradle rather than silently
    # accepted. Asserted so a future edit cannot narrow the prefix away.
    for cell in PROTECTED_CELLS:
        for art in ('arm64_v8a_release', 'armeabi_v7a_release',
                    'x86_64_release', 'flutter_embedding_release'):
            for ext in ('jar', 'pom'):
                expect_covered.append(
                    f'/download.flutter.io/io/flutter/{art}/'
                    f'1.0.0-{cell}/{art}-1.0.0-{cell}.{ext}')

    # Deliberately NOT owned per cell: a path the per-cell arms must not claim.
    for cell in PROTECTED_CELLS:
        expect_uncovered.append(
            f'/flutter_infra_release/flutter/{cell}/linux-x64/font-subset.zip')
    # The debug/profile Android objects: reconstructible, not consumed by a
    # release build, and required only because `shorebird release android`
    # runs `flutter precache --android` unconditionally. Protecting these would
    # 404 precache on every cell that does not publish 619 MB it cannot use.
    for cell in PROTECTED_CELLS:
        for abi in ('arm', 'arm64', 'x64'):
            expect_uncovered.append(
                f'/flutter_infra_release/flutter/{cell}/'
                f'android-{abi}-profile/darwin-x64.zip')
            expect_uncovered.append(
                f'/flutter_infra_release/flutter/{cell}/'
                f'android-{abi}-profile/artifacts.zip')
        expect_uncovered.append(
            f'/flutter_infra_release/flutter/{cell}/android-arm64/artifacts.zip')

    failures = []
    for path in expect_covered:
        if not covered(res, path):
            failures.append(f'NOT PROTECTED (should be): {path}')
    for path in expect_uncovered:
        if covered(res, path):
            failures.append(f'PROTECTED (should not be): {path}')

    print(f'  matchers parsed      : {len(res)}')
    print(f'  paths expected cover : {len(expect_covered)}')
    print(f'  paths expected clear : {len(expect_uncovered)}')
    if failures:
        for f in failures:
            print(f'  {f}')
        sys.exit(f'\n  MATCHER COVERAGE FAILED: {len(failures)}')
    print('  MATCHER COVERAGE OK')


if __name__ == '__main__':
    main()
