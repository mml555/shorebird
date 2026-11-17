// Writes the real `enclosingScopeOf` output for every class or extension member
// of a fixture, for the producer's class-scope tests.
//
//   DART=$SRC/out/host_release_arm64/dart-sdk/bin/dart
//   $DART compile kernel FIXTURE.dart -o /tmp/fixture.dill
//   $DART --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     gen_scope_fixture.dart FIXTURE.dart /tmp/fixture.dill OUT.json
//
// `sourceSha256` records the fixture's hash, so a test fails when the .dart is
// edited and this is not regenerated.
//
// Each entry is `{start, end, static, scope}` keyed by `Class.member` (or
// `Extension|member`), where start/end is the span the analyzer reports for the
// member's source.
// cspell:words
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

import 'analyze_coverage.dart';

void main(List<String> args) {
  final component = Component();
  BinaryBuilder(File(args[1]).readAsBytesSync()).readComponent(component);
  final fixture = File(args[0]).absolute.uri;
  final out = <String, Object?>{
    'sourceSha256': sha256.convert(File(args[0]).readAsBytesSync()).toString(),
  };
  for (final lib in component.libraries) {
    if (lib.fileUri != fixture) continue;
    void add(String key, Procedure p) {
      final scope = enclosingScopeOf(p);
      if (scope == null) return;
      out[key] = {
        'start': p.fileStartOffset,
        'end': p.fileEndOffset + 1,
        'static': p.isStatic,
        'scope': scope,
      };
    }

    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        add('${cls.name}.${p.name.text}', p);
      }
    }
    for (final p in lib.procedures) {
      if (p.isExtensionMember || p.isExtensionTypeMember) {
        add(p.name.text, p);
      }
    }
  }
  File(args[2]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(out)}\n',
  );
}
