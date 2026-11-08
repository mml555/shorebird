@Tags(['version-verify'])
library;

import 'dart:io';

import 'package:build_verify/build_verify.dart';
import 'package:test/test.dart';

import 'src/helpers.dart';

void main() {
  useTempWorkingDirectory();
  test(
    'ensure_build',
    // Builds and diffs the real package, which `expectBuildClean` finds from
    // the current directory.
    () => IOOverrides.runZoned(
      () =>
          expectBuildClean(packageRelativeDirectory: 'packages/shorebird_cli'),
      getCurrentDirectory: () => Directory(packagePath('')),
    ),
    // On a fresh runner build_runner first compiles its builders (about 90
    // seconds on ci-build, cold), which the default 30 second timeout doubled
    // by the factor cannot cover. The generated files are not stale: the same
    // build leaves `git diff` empty.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
